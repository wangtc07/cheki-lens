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

    /// 相容 Bundle ID 前綴之候選商品 ID 清單
    nonisolated static let supportedProductIDs: Set<String> = [
        "com.chekilens.pro.lifetime",
        "wangtc07.ChekiLens.pro.lifetime"
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

    /// 從 App Store / StoreKit Configuration 載入的終身買斷商品
    private(set) var proProduct: Product?

    /// 目前是否已解鎖 ChekiLens Pro 終身買斷版
    private(set) var isProUnlocked: Bool

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

    /// 背景交易監聽任務 (`Transaction.updates`)
    @ObservationIgnored
    private var updatesListenerTask: Task<Void, Never>?

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.chekilens.app", category: "StoreKitManager")

    // MARK: - Initialization

    private init() {
        self.isProUnlocked = UserDefaults.standard.bool(forKey: Self.proUnlockedStorageKey)
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

    /// 顯示用在地化價格字串（優先使用 StoreKit 2 `Product.displayPrice`，未連線時回退至 `¥600 / NT$120`）
    var displayPrice: String {
        if let product = proProduct {
            return product.displayPrice
        }
        return "NT$120 / ¥600"
    }

    /// 橫幅按鈕顯示文字
    var bannerUnlockButtonTitle: String {
        if let product = proProduct {
            return L10n.tr("\(product.displayPrice) 永久解鎖", "\(product.displayPrice) で永久ロック解除")
        }
        return L10n.tr("¥600 / NT$120 永久解鎖", "¥600 / NT$120 で永久ロック解除")
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

    /// 透過 StoreKit 2 查詢 Non-Consumable 終身買斷商品
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let products = try await Product.products(for: Self.supportedProductIDs)
            if let match = products.first(where: { $0.id == Self.proLifetimeProductID }) ?? products.first {
                self.proProduct = match
                logger.info("已成功載入 StoreKit 商品: \(match.id, privacy: .public) (\(match.displayPrice, privacy: .public))")
            }
        } catch {
            logger.warning("無法從 StoreKit 載入商品清單: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Purchase Flow (Product.purchase)

    /// 執行 `ChekiLens Pro` 終身買斷購買流程
    func purchaseProLifetime() async -> PurchaseOutcome {
        guard !isPurchasing else { return .userCancelled }
        isPurchasing = true
        lastErrorMessage = nil
        defer { isPurchasing = false }

        if proProduct == nil {
            await loadProducts()
        }

        // 1. 若 StoreKit 商品已就緒（實機 App Store / Xcode StoreKit Testing），執行原生 StoreKit 2 購買驗證
        if let product = proProduct {
            do {
                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    let transaction = try checkVerified(verification)
                    setProUnlocked(true)
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
        setProUnlocked(nextState)
        logger.info("DEBUG 模擬器模式切換 ChekiLens Pro 狀態: \(nextState)")
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
        var hasValidProEntitlement = false

        for await verificationResult in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verificationResult else {
                continue
            }
            // 確認未遭退款撤銷 (revocationDate == nil) 且屬於 Pro 終身買斷商品
            if transaction.revocationDate == nil,
               (Self.supportedProductIDs.contains(transaction.productID) || transaction.productID.lowercased().contains("pro")) {
                hasValidProEntitlement = true
                break
            }
        }

        if hasValidProEntitlement {
            setProUnlocked(true)
        } else {
            // 同步 UserDefaults 目前狀態（保留開發環境手動切換或離線快取狀態）
            let cached = UserDefaults.standard.bool(forKey: Self.proUnlockedStorageKey)
            if isProUnlocked != cached {
                isProUnlocked = cached
            }
        }
    }

    /// 更新 Pro 解鎖狀態並寫入 `UserDefaults`（觸發 `@AppStorage("isProLifetimeUnlocked")` 即時更新 UI）
    func setProUnlocked(_ unlocked: Bool) {
        isProUnlocked = unlocked
        UserDefaults.standard.set(unlocked, forKey: Self.proUnlockedStorageKey)
    }

    // MARK: - Background Transaction Listener

    /// 持續監聽背景交易更新（例如家庭共享、跨裝置購買、Ask to Buy 核准或退款撤銷）
    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await verificationResult in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = verificationResult {
                    let isRevoked = (transaction.revocationDate != nil)
                    let isProProduct = StoreKitManager.supportedProductIDs.contains(transaction.productID)
                        || transaction.productID.lowercased().contains("pro")

                    if isProProduct {
                        await MainActor.run {
                            self.setProUnlocked(!isRevoked)
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
