import Foundation
import CloudKit
import OSLog

// MARK: - CloudKitSyncState

/// iCloud 同步狀態機
public enum CloudKitSyncState: Equatable, Sendable {
    case idle
    case syncing
    case succeeded(Date)
    case failed(String)
    case disabled

    public var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

// MARK: - CloudKitContainerProtocol

/// 封裝 CloudKit Container 操作之協議（支援 Live 與 Mock 注入測試）
public protocol CloudKitContainerProtocol: Sendable {
    func fetchAccountStatus() async throws -> CKAccountStatus
    func checkConnection() async throws
}

// MARK: - LiveCloudKitContainer

/// 正式環境使用之 CloudKit Container 包裝
public final class LiveCloudKitContainer: CloudKitContainerProtocol, @unchecked Sendable {
    private let container: CKContainer

    public init(container: CKContainer = .default()) {
        self.container = container
    }

    public func fetchAccountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    public func checkConnection() async throws {
        let _ = try await container.privateCloudDatabase.allRecordZones()
    }
}

// MARK: - MockCloudKitContainer

/// 單元測試與離線預覽使用之 Mock 容器
public final class MockCloudKitContainer: CloudKitContainerProtocol, @unchecked Sendable {
    public var status: CKAccountStatus
    public var shouldThrow: Bool

    public init(status: CKAccountStatus = .available, shouldThrow: Bool = false) {
        self.status = status
        self.shouldThrow = shouldThrow
    }

    public func fetchAccountStatus() async throws -> CKAccountStatus {
        if shouldThrow {
            throw NSError(domain: "CKErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "模擬網路連線異常"])
        }
        return status
    }

    public func checkConnection() async throws {
        if shouldThrow {
            throw NSError(domain: "CKErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "模擬資料庫連線失敗"])
        }
    }
}

// MARK: - CloudKitSyncManaging

/// 提供給單元測試與 UI 注入之同步管理器協議
@MainActor
public protocol CloudKitSyncManaging: AnyObject {
    var accountStatus: CKAccountStatus { get }
    var syncState: CloudKitSyncState { get }
    var lastSyncDate: Date? { get }
    var isICloudSyncEnabled: Bool { get set }
    var canSync: Bool { get }
    var accountStatusDescription: String { get }
    var syncStateDescription: String { get }

    func refreshAccountStatus() async
    func triggerSync() async
}

// MARK: - CloudKitSyncManager

/// 管理 iCloud 帳號狀態、CloudKit 同步生命週期與最後同步記錄的核心服務
@Observable
@MainActor
public final class CloudKitSyncManager: CloudKitSyncManaging {

    public static let shared = CloudKitSyncManager()

    // MARK: Storage Keys

    public static let syncEnabledStorageKey = "isICloudSyncEnabled"
    public static let lastSyncTimestampStorageKey = "lastICloudSyncTimestamp"

    // MARK: State

    public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    public private(set) var syncState: CloudKitSyncState = .idle
    public private(set) var lastSyncDate: Date?

    /// 使用者偏好開關：是否啟用 iCloud 多裝置同步（需搭配 Pro 買斷版）
    public var isICloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isICloudSyncEnabled, forKey: Self.syncEnabledStorageKey)
            updateSyncState()
        }
    }

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.chekilens.app", category: "CloudKitSyncManager")

    @ObservationIgnored
    private var accountChangeListenerTask: Task<Void, Never>?

    @ObservationIgnored
    private let container: CloudKitContainerProtocol

    // MARK: Init

    public init(container: CloudKitContainerProtocol? = nil, eagerRefresh: Bool = false) {
        self.container = container ?? LiveCloudKitContainer()
        self.isICloudSyncEnabled = UserDefaults.standard.object(forKey: Self.syncEnabledStorageKey) as? Bool ?? true
        if let timestamp = UserDefaults.standard.object(forKey: Self.lastSyncTimestampStorageKey) as? Double {
            self.lastSyncDate = Date(timeIntervalSince1970: timestamp)
        }
        setupAccountChangeListener()
        if eagerRefresh {
            Task {
                await refreshAccountStatus()
            }
        }
    }

    deinit {
        accountChangeListenerTask?.cancel()
    }

    // MARK: Account Monitoring

    private func setupAccountChangeListener() {
        accountChangeListenerTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard let self else { return }
                self.logger.info("檢測到 Apple ID / iCloud 帳號變更通知，重新檢查帳號狀態")
                await self.refreshAccountStatus()
            }
        }
    }

    /// 重新查詢系統 Apple ID 的 iCloud 狀態
    public func refreshAccountStatus() async {
        do {
            let status = try await container.fetchAccountStatus()
            self.accountStatus = status
            self.logger.info("iCloud 帳號狀態更新為: \(String(describing: status.rawValue))")
            updateSyncState()
        } catch {
            self.logger.error("查詢 iCloud 帳號狀態失敗: \(error.localizedDescription)")
            self.accountStatus = .couldNotDetermine
            self.syncState = .failed(error.localizedDescription)
        }
    }

    /// 手動設定帳號狀態（供測試與模擬使用）
    public func setAccountStatusForTesting(_ status: CKAccountStatus) {
        self.accountStatus = status
        updateSyncState()
    }

    /// 手動設定同步狀態（供測試使用）
    public func setSyncStateForTesting(_ state: CloudKitSyncState) {
        self.syncState = state
    }

    // MARK: Synchronization Actions

    /// 手動觸發立即同步
    public func triggerSync() async {
        guard canSync else {
            logger.warning("目前不具備同步條件 (canSync == false)，略過同步請求")
            return
        }

        syncState = .syncing
        logger.info("手動觸發 iCloud 雲端同步...")

        do {
            try await container.checkConnection()
            let now = Date()
            self.lastSyncDate = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastSyncTimestampStorageKey)
            self.syncState = .succeeded(now)
            self.logger.info("iCloud 雲端同步成功完成於: \(now)")
        } catch {
            self.logger.error("iCloud 雲端同步失敗: \(error.localizedDescription)")
            self.syncState = .failed(error.localizedDescription)
        }
    }

    /// 更新內部同步狀態機
    private func updateSyncState() {
        if !isICloudSyncEnabled {
            syncState = .disabled
            return
        }

        switch accountStatus {
        case .available:
            if let date = lastSyncDate {
                syncState = .succeeded(date)
            } else {
                syncState = .idle
            }
        case .noAccount:
            syncState = .failed(L10n.tr("請在 iOS「設定」中登入 Apple ID", "iOS「設定」でApple IDにサインインしてください"))
        case .restricted:
            syncState = .failed(L10n.tr("iCloud 存取受到系統限制", "iCloudアクセスが制限されています"))
        case .temporarilyUnavailable:
            syncState = .failed(L10n.tr("iCloud 服務暫時無法使用", "iCloudサービスは一時的に利用できません"))
        case .couldNotDetermine:
            syncState = .idle
        @unknown default:
            syncState = .idle
        }
    }

    // MARK: Computed Helpers

    /// 是否具備啟用同步的完整條件（登入 iCloud ＋ 開啟同步開關 ＋ 解鎖 Pro）
    public var canSync: Bool {
        accountStatus == .available && isICloudSyncEnabled && StoreKitManager.shared.isProUnlocked
    }

    /// 帳號狀態在地化描述
    public var accountStatusDescription: String {
        switch accountStatus {
        case .available:
            return L10n.tr("已連接 iCloud", "iCloud 接続済み")
        case .noAccount:
            return L10n.tr("未登入 iCloud", "iCloud 未サインイン")
        case .restricted:
            return L10n.tr("帳號受限制", "アカウント制限中")
        case .temporarilyUnavailable:
            return L10n.tr("服務暫時無法使用", "服務一時利用不可")
        case .couldNotDetermine:
            return L10n.tr("檢查中...", "確認中...")
        @unknown default:
            return L10n.tr("未知狀態", "不明なステータス")
        }
    }

    /// 同步狀態在地化描述
    public var syncStateDescription: String {
        switch syncState {
        case .idle:
            if !StoreKitManager.shared.isProUnlocked {
                return L10n.tr("升級 Pro 解鎖多裝置同步", "Proにアップグレードして同期")
            }
            return L10n.tr("待命", "待機中")
        case .syncing:
            return L10n.tr("正在與 iCloud 同步...", "iCloud と同期中...")
        case .succeeded(let date):
            return Self.relativeTimeString(from: date)
        case .failed(let message):
            return message
        case .disabled:
            return L10n.tr("同步已關閉", "同期オフ")
        }
    }

    /// 相對時間字串（例如：「已同步 (剛剛)」、「已同步 (5 分鐘前)」）
    public static func relativeTimeString(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 {
            return L10n.tr("已同步 (剛剛)", "同期完了 (たった今)")
        } else if seconds < 3600 {
            let minutes = max(1, Int(seconds / 60))
            return L10n.tr("已同步 (\(minutes) 分鐘前)", "同期完了 (\(minutes)分前)")
        } else if seconds < 86400 {
            let hours = max(1, Int(seconds / 3600))
            return L10n.tr("已同步 (\(hours) 小時前)", "同期完了 (\(hours)時間前)")
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return L10n.tr("已同步 (\(formatter.string(from: date)))", "同期完了 (\(formatter.string(from: date)))")
        }
    }
}
