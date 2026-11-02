import XCTest
import CloudKit
import SwiftUI
@testable import ChekiLens

@MainActor
final class SettingsICloudSyncTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "isICloudSyncEnabled")
        UserDefaults.standard.removeObject(forKey: "isProLifetimeUnlocked")
        UserDefaults.standard.removeObject(forKey: "lastICloudSyncTimestamp")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "isICloudSyncEnabled")
        UserDefaults.standard.removeObject(forKey: "isProLifetimeUnlocked")
        UserDefaults.standard.removeObject(forKey: "lastICloudSyncTimestamp")
        try await super.tearDown()
    }

    // MARK: - 1. 帳號狀態指示燈與描述

    func test_accountStatusDescriptionsAndIndicators() {
        let mockContainer = MockCloudKitContainer(status: .available)
        let manager = CloudKitSyncManager(container: mockContainer, eagerRefresh: false)

        manager.setAccountStatusForTesting(.available)
        XCTAssertEqual(manager.accountStatusDescription, L10n.tr("已連接 iCloud", "iCloud 接続済み"))

        manager.setAccountStatusForTesting(.noAccount)
        XCTAssertEqual(manager.accountStatusDescription, L10n.tr("未登入 iCloud", "iCloud 未サインイン"))

        manager.setAccountStatusForTesting(.restricted)
        XCTAssertEqual(manager.accountStatusDescription, L10n.tr("帳號受限制", "アカウント制限中"))

        manager.setAccountStatusForTesting(.temporarilyUnavailable)
        XCTAssertEqual(manager.accountStatusDescription, L10n.tr("服務暫時無法使用", "服務一時利用不可"))

        manager.setAccountStatusForTesting(.couldNotDetermine)
        XCTAssertEqual(manager.accountStatusDescription, L10n.tr("檢查中...", "確認中..."))
    }

    // MARK: - 2. 同步總開關與 Pro 權益

    func test_syncToggleAndProRequirement() {
        let mockContainer = MockCloudKitContainer(status: .available)
        let manager = CloudKitSyncManager(container: mockContainer, eagerRefresh: false)

        // 免費版：即使開關為 true 且帳號可用，canSync 仍為 false
        StoreKitManager.shared.setProUnlocked(false)
        manager.isICloudSyncEnabled = true
        manager.setAccountStatusForTesting(.available)
        XCTAssertFalse(manager.canSync)

        // 解鎖 Pro：canSync 變為 true
        StoreKitManager.shared.setProUnlocked(true)
        XCTAssertTrue(manager.canSync)

        // 關閉同步：canSync 變為 false
        manager.isICloudSyncEnabled = false
        XCTAssertFalse(manager.canSync)
        XCTAssertEqual(manager.syncState, .disabled)
    }

    // MARK: - 3. 快取容量計算與一鍵清除

    func test_cacheUsageAndClearAll() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsCacheTest_\(UUID().uuidString)")
        let cache = ChekiImageCacheManager(diskCacheURL: tempDir)

        let initialUsage = await cache.formattedDiskUsage()
        XCTAssertFalse(initialUsage.isEmpty)

        // 寫入測試圖檔
        let dummyImage = UIImage(systemName: "star.fill") ?? UIImage()
        let dummyData = dummyImage.pngData() ?? Data([0x01, 0x02, 0x03, 0x04])
        try await cache.store(image: dummyImage, data: dummyData, forKey: "test_key")

        let usageAfterStore = await cache.diskUsageBytes()
        XCTAssertGreaterThan(usageAfterStore, 0)

        // 清除所有快取
        try await cache.clearAll()
        let usageAfterClear = await cache.diskUsageBytes()
        XCTAssertEqual(usageAfterClear, 0)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 4. 手動觸發立即同步生命週期

    func test_triggerSyncLifecycle() async {
        let mockContainer = MockCloudKitContainer(status: .available)
        let manager = CloudKitSyncManager(container: mockContainer, eagerRefresh: false)

        StoreKitManager.shared.setProUnlocked(true)
        manager.isICloudSyncEnabled = true
        manager.setAccountStatusForTesting(.available)

        XCTAssertTrue(manager.canSync)

        await manager.triggerSync()

        XCTAssertNotNil(manager.lastSyncDate)
        if case .succeeded(let date) = manager.syncState {
            XCTAssertEqual(date.timeIntervalSince1970, manager.lastSyncDate?.timeIntervalSince1970)
        } else {
            XCTFail("同步後應為 succeeded 狀態")
        }

        XCTAssertTrue(manager.syncStateDescription.contains("已同步") || manager.syncStateDescription.contains("同期完了"))
    }

    // MARK: - 5. canSync 為 false 時手動同步略過

    func test_triggerSyncIgnoredWhenCannotSync() async {
        let mockContainer = MockCloudKitContainer(status: .noAccount)
        let manager = CloudKitSyncManager(container: mockContainer, eagerRefresh: false)

        StoreKitManager.shared.setProUnlocked(false)
        manager.isICloudSyncEnabled = false

        let stateBefore = manager.syncState
        await manager.triggerSync()
        XCTAssertEqual(manager.syncState, stateBefore)
        XCTAssertNil(manager.lastSyncDate)
    }
}
