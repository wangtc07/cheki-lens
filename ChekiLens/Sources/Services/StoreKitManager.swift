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

    /// 正式 Non-Consumable 終身買斷商品 ID
    static let proLifetimeProductID = "com.chekilens.pro.lifetime"

    /// 相容 Bundle ID 前綴之候選商品 ID 清單
    static let supportedProductIDs: Set<String> = [
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
        self.updatesListenerTask = listenForTransactionUpdates()
    }

    deinit {
        updatesListenerTask?.cancel()
    }

    // MARK: - Computed Helpers

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
            return "\(product.displayPrice) 永久解鎖"
        }
        return "¥600 / NT$120 永久解鎖"
    }

    // MARK: - Store Initialization & Product Loading

    /// App 啟動或進入設定頁時呼叫：載入商品並檢查最新有效交易權益
    func initializeStore() async {
        await refreshPurchasedEntitlements()
        if proProduct == nil {
            await loadProducts()
        }
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
