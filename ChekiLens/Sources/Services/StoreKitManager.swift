import Foundation
import StoreKit
import OSLog

// MARK: - StoreKitManager (Task 5.1: Non-Consumable NT$120 / ¥600 終身買斷內購管理)

/// StoreKit 2 終身買斷內購管理器（零伺服器驗證、JWS 本機簽章驗證、支援離線權益快取與自動交易監聽）
@MainActor
@Observable
final class StoreKitManager {
    static let shared = StoreKitManager()

    /// AppStorage / UserDefaults 共用鍵值（與 `SettingsView`、`PhotoLibraryManager`、`ChekiWatermarkOverlayView` 雙向同步）
    static let proUnlockedStorageKey = "isProLifetimeUnlocked"

    /// Task 5.2：每日免費高畫質無浮水印額度上限（每日 1 張）
    static let dailyFreeLimit: Int = 1
    static let dailyQuotaDateStorageKey = "dailyFreeQuotaDateString"
    static let dailyQuotaUsedCountStorageKey = "dailyFreeQuotaUsedCount"

    /// 正式 Non-Consumable 終身買斷商品 ID
    nonisolated static let proLifetimeProductID = "com.chekilens.pro.lifetime"

    /// 社群貢獻者半價 Non-Consumable 終身買斷商品 ID（開啟模型共享時可選購，購買後鎖定共享開關）
    nonisolated static let proContributorProductID = "com.chekilens.pro.contributor"

    /// 社群貢獻版候選商品 ID 清單
    nonisolated static let contributorProductIDs: Set<String> = [
        "com.chekilens.pro.contributor",
        "wangtc07.ChekiLens.pro.contributor"
    ]

    /// 相容 Bundle ID 前綴之候選商品 ID 清單
    nonisolated static let supportedProductIDs: Set<String> = [
        "com.chekilens.pro.lifetime",
        "wangtc07.ChekiLens.pro.lifetime",
        "com.chekilens.pro.contributor",
        "wangtc07.ChekiLens.pro.contributor"
    ]

    /// 購買結果狀態
    enum PurchaseOutcome: Equatable {
        case purchased
        case restored
        case userCancelled
        case pending
        case simulatedToggle(isUnlocked: Bool)
        case failed(String)
    }

    // MARK: - Observable State

    /// 從 App Store / StoreKit Configuration 載入的標準終身買斷商品
    private(set) var proProduct: Product?

    /// 從 App Store / StoreKit Configuration 載入的社群貢獻半價終身買斷商品
    private(set) var contributorProProduct: Product?

    /// 目前是否已解鎖 ChekiLens Pro 終身買斷版
    private(set) var isProUnlocked: Bool

    /// 社群模型共享與 Pro 授權等級狀態機
    private(set) var contributionState: CommunityContributionState

    /// 今日已使用的免費高畫質無浮水印額度張數（跨日自動歸零）
    private(set) var dailyFreeQuotaUsedCount: Int = 0

    /// 是否正在載入商品資訊
    private(set) var isLoadingProducts: Bool = false

    /// 是否正在執行購買交易
    private(set) var isPurchasing: Bool = false

    /// 是否正在恢復購買
    private(set) var isRestoring: Bool = false

    /// 最近一次錯誤訊息
    var lastErrorMessage: String?

    @ObservationIgnored
    private let contributionStore = CommunityContributionStore()

    /// 背景交易監聽任務 (`Transaction.updates`)
    @ObservationIgnored
    private var updatesListenerTask: Task<Void, Never>?

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.chekilens.app", category: "StoreKitManager")

    // MARK: - Initialization

    private init() {
        let initialContribution = CommunityContributionStore().loadState()
        self.contributionState = initialContribution
        self.isProUnlocked = initialContribution.isProUnlocked
        self.dailyFreeQuotaUsedCount = 0
        self.refreshDailyFreeQuotaIfNeeded()
        self.updatesListenerTask = listenForTransactionUpdates()
    }

    deinit {
        updatesListenerTask?.cancel()
    }

    // MARK: - Computed Helpers

    /// 今日剩餘的免費 4K 高畫質無浮水印額度張數（免費版每日 1 張）
    var remainingDailyFreeQuota: Int {
        max(0, Self.dailyFreeLimit - dailyFreeQuotaUsedCount)
    }

    /// 今日是否仍有免費無浮水印高畫質額度可用
    var hasDailyFreeQuotaAvailable: Bool {
        isProUnlocked || remainingDailyFreeQuota > 0
    }

    /// 顯示用在地化價格字串（若開啟模型共享且為免費版，優先顯示半價社群貢獻商品價格 `NT$60 / ¥300`）
    var displayPrice: String {
        if contributionState.isEligibleForHalfPricePro {
            if let contributorProduct = contributorProProduct {
                return contributorProduct.displayPrice
            }
            return contributionState.fallbackDisplayPrice
        }
        if let product = proProduct {
            return product.displayPrice
        }
        return "NT$120 / ¥600"
    }

    /// 橫幅按鈕顯示文字
    var bannerUnlockButtonTitle: String {
        if contributionState.isEligibleForHalfPricePro {
            let price = contributorProProduct?.displayPrice ?? "¥300 / NT$60"
            return L10n.tr("\(price) 半價永久解鎖", "\(price) 半額で永久ロック解除")
        }
        if let product = proProduct {
            return L10n.tr("\(product.displayPrice) 永久解鎖", "\(product.displayPrice) で永久ロック解除")
        }
        return L10n.tr("¥600 / NT$120 永久解鎖", "¥600 / NT$120 で永久ロック解除")
    }

    /// 更新社群模型共享開關（若已透過半價社群版解鎖 Pro，狀態機將維持鎖定開啟，不允許關閉）
    func setCommunitySharingEnabled(_ enabled: Bool) {
        let next = contributionStore.apply(.setSharingPreference(enabled))
        contributionState = next
        isProUnlocked = next.isProUnlocked
    }

    /// 從儲存層重新同步 `contributionState` 與 `isProUnlocked`
    func reloadContributionStateFromStorage() {
        let loaded = contributionStore.loadState()
        contributionState = loaded
        isProUnlocked = loaded.isProUnlocked
    }

    // MARK: - Store Initialization & Product Loading

    /// App 啟動或進入設定頁時呼叫：檢查跨日免費額度、載入商品並檢查最新有效交易權益
    func initializeStore() async {
        refreshDailyFreeQuotaIfNeeded()
        await refreshPurchasedEntitlements()
        if proProduct == nil {
            await loadProducts()
        }
    }

    // MARK: - Task 5.2: 每日 1 張 4K 高畫質無浮水印免費額度計數器 (UserDefaults 儲存)

    /// 取得當地時區今日日期字串 (`yyyy-MM-dd`)
    private static func currentLocalDateKey(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 檢查是否跨日：若已進入新的一天則自動將 `UserDefaults` 中的每日免費額度使用次數重置為 0
    func refreshDailyFreeQuotaIfNeeded(now: Date = Date()) {
        let todayKey = Self.currentLocalDateKey(for: now)
        let defaults = UserDefaults.standard
        let storedDateKey = defaults.string(forKey: Self.dailyQuotaDateStorageKey)

        if storedDateKey != todayKey {
            defaults.set(todayKey, forKey: Self.dailyQuotaDateStorageKey)
            defaults.set(0, forKey: Self.dailyQuotaUsedCountStorageKey)
            dailyFreeQuotaUsedCount = 0
        } else {
            let used = max(0, defaults.integer(forKey: Self.dailyQuotaUsedCountStorageKey))
            dailyFreeQuotaUsedCount = min(Self.dailyFreeLimit, used)
        }
    }

    /// 嘗試消耗 1 張今日免費 4K 高畫質無浮水印額度：
    /// - 若為 Pro 版：不扣額度，直接回傳 `true`。
    /// - 若為免費版且今日尚有剩餘額度 (`remainingDailyFreeQuota > 0`)：扣除 1 張並寫入 `UserDefaults`，回傳 `true`。
    /// - 若今日免費額度已用罄：回傳 `false`。
    @discardableResult
    func consumeDailyFreeQuotaIfAvailable(now: Date = Date()) -> Bool {
        refreshDailyFreeQuotaIfNeeded(now: now)
        if isProUnlocked {
            return true
        }
        guard remainingDailyFreeQuota > 0 else {
            return false
        }
        let nextUsed = dailyFreeQuotaUsedCount + 1
        dailyFreeQuotaUsedCount = nextUsed
        let defaults = UserDefaults.standard
        defaults.set(Self.currentLocalDateKey(for: now), forKey: Self.dailyQuotaDateStorageKey)
        defaults.set(nextUsed, forKey: Self.dailyQuotaUsedCountStorageKey)
        logger.info("已消耗 1 張今日免費高畫質無浮水印額度（今日已用 \(nextUsed)/\(Self.dailyFreeLimit)）")
        return true
    }

    /// 重置今日免費額度（供開發測試驗證）
    func resetDailyFreeQuota() {
        let todayKey = Self.currentLocalDateKey()
        let defaults = UserDefaults.standard
        defaults.set(todayKey, forKey: Self.dailyQuotaDateStorageKey)
        defaults.set(0, forKey: Self.dailyQuotaUsedCountStorageKey)
        dailyFreeQuotaUsedCount = 0
    }

    /// 透過 StoreKit 2 查詢 Non-Consumable 終身買斷商品（包含標準版與社群貢獻半價版）
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let products = try await Product.products(for: Self.supportedProductIDs)
            if let standardMatch = products.first(where: { $0.id == Self.proLifetimeProductID || !Self.contributorProductIDs.contains($0.id) }) {
                self.proProduct = standardMatch
                logger.info("已成功載入標準版 StoreKit 商品: \(standardMatch.id, privacy: .public) (\(standardMatch.displayPrice, privacy: .public))")
            }
            if let contributorMatch = products.first(where: { Self.contributorProductIDs.contains($0.id) }) {
                self.contributorProProduct = contributorMatch
                logger.info("已成功載入社群半價版 StoreKit 商品: \(contributorMatch.id, privacy: .public) (\(contributorMatch.displayPrice, privacy: .public))")
            }
        } catch {
            logger.warning("無法從 StoreKit 載入商品清單: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Purchase Flow (Product.purchase)

    /// 執行 `ChekiLens Pro` 終身買斷購買流程（若免費版使用者已開啟社群模型共享，則執行半價社群貢獻版購買並鎖定共享狀態）
    func purchaseProLifetime() async -> PurchaseOutcome {
        guard !isPurchasing else { return .userCancelled }
        isPurchasing = true
        lastErrorMessage = nil
        defer { isPurchasing = false }

        if proProduct == nil && contributorProProduct == nil {
            await loadProducts()
        }

        let useHalfPriceTier = contributionState.isEligibleForHalfPricePro
        let targetProduct = useHalfPriceTier ? (contributorProProduct ?? proProduct) : proProduct

        // 1. 若 StoreKit 商品已就緒（實機 App Store / Xcode StoreKit Testing），執行原生 StoreKit 2 購買驗證
        if let product = targetProduct {
            do {
                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    let transaction = try checkVerified(verification)
                    let isContributorTx = Self.contributorProductIDs.contains(transaction.productID) || useHalfPriceTier
                    applyPurchaseEntitlement(isContributorTier: isContributorTx)
                    await transaction.finish()
                    logger.info("成功完成 ChekiLens Pro 終身買斷交易: \(transaction.id)")
                    return .purchased

                case .userCancelled:
                    logger.info("使用者取消購買 ChekiLens Pro")
                    return .userCancelled

                case .pending:
                    logger.info("ChekiLens Pro 購買交易等待核准中 (Ask to Buy / Pending)")
                    return .pending

                @unknown default:
                    return .userCancelled
                }
            } catch {
                let msg = error.localizedDescription
                lastErrorMessage = msg
                logger.error("StoreKit 購買失敗: \(msg, privacy: .public)")
                return .failed(msg)
            }
        }

        // 2. 開發與模擬器無沙盒商品環境 Fallback：支援直接切換 Pro 授權狀態供驗證免費版 / Pro 版行為
        #if DEBUG
        try? await Task.sleep(for: .milliseconds(300))
        let nextState = !isProUnlocked
        if nextState {
            applyPurchaseEntitlement(isContributorTier: useHalfPriceTier)
        } else {
            setProUnlocked(false)
        }
        logger.info("DEBUG 模擬器模式切換 ChekiLens Pro 狀態: \(nextState) (contributorTier: \(useHalfPriceTier))")
        return .simulatedToggle(isUnlocked: nextState)
        #else
        let err = "目前無法連線至 App Store 取得商品資訊，請稍後再試。"
        lastErrorMessage = err
        return .failed(err)
        #endif
    }

    // MARK: - Restore Purchases (AppStore.sync & currentEntitlements)

    /// 恢復購買項目：同步 App Store 交易紀錄並重新驗證 Non-Consumable 終身買斷資格
    func restorePurchases() async -> Bool {
        guard !isRestoring else { return isProUnlocked }
        isRestoring = true
        lastErrorMessage = nil
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
        } catch {
            logger.warning("AppStore.sync() 在目前環境略過或失敗: \(error.localizedDescription, privacy: .public)")
        }

        await refreshPurchasedEntitlements()
        return isProUnlocked
    }

    /// 檢查 `Transaction.currentEntitlements` 中的所有有效 Non-Consumable 購買憑證
    func refreshPurchasedEntitlements() async {
        var hasStandardEntitlement = false
        var hasContributorEntitlement = false

        for await verificationResult in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verificationResult else {
                continue
            }
            guard transaction.revocationDate == nil else { continue }
            if Self.contributorProductIDs.contains(transaction.productID) {
                hasContributorEntitlement = true
            } else if Self.supportedProductIDs.contains(transaction.productID) || transaction.productID.lowercased().contains("pro") {
                hasStandardEntitlement = true
            }
        }

        if hasStandardEntitlement {
            applyPurchaseEntitlement(isContributorTier: false)
        } else if hasContributorEntitlement {
            applyPurchaseEntitlement(isContributorTier: true)
        } else {
            reloadContributionStateFromStorage()
        }
    }

    func applyPurchaseEntitlement(isContributorTier: Bool) {
        let next = contributionStore.apply(isContributorTier ? .unlockContributorPro : .unlockStandardPro)
        contributionState = next
        isProUnlocked = next.isProUnlocked
    }

    /// 更新 Pro 解鎖狀態並寫入 `UserDefaults`（觸發 `@AppStorage("isProLifetimeUnlocked")` 即時更新 UI）
    func setProUnlocked(_ unlocked: Bool) {
        let action: CommunityContributionAction
        if unlocked {
            action = contributionState.isEligibleForHalfPricePro ? .unlockContributorPro : .unlockStandardPro
        } else {
            action = .revokeAllProEntitlements
        }
        let next = contributionStore.apply(action)
        contributionState = next
        isProUnlocked = next.isProUnlocked
    }

    // MARK: - Background Transaction Listener

    /// 持續監聽背景交易更新（例如家庭共享、跨裝置購買、Ask to Buy 核准或退款撤銷）
    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await verificationResult in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = verificationResult {
                    let isRevoked = (transaction.revocationDate != nil)
                    let isContributorProduct = StoreKitManager.contributorProductIDs.contains(transaction.productID)
                    let isProProduct = StoreKitManager.supportedProductIDs.contains(transaction.productID)
                        || transaction.productID.lowercased().contains("pro")

                    if isProProduct {
                        await MainActor.run {
                            if isRevoked {
                                self.setProUnlocked(false)
                            } else {
                                self.applyPurchaseEntitlement(isContributorTier: isContributorProduct)
                            }
                        }
                    }
                    await transaction.finish()
                }
            }
        }
    }

    /// 驗證 StoreKit 2 JWS 數位簽章
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
}
