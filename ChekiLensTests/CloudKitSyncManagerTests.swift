import XCTest
import CloudKit
@testable import ChekiLens

@MainActor
final class CloudKitSyncManagerTests: XCTestCase {

    func test_syncState_disabledWhenToggleOff() {
        let mockContainer = MockCloudKitContainer(status: .available)
        let manager = CloudKitSyncManager(container: mockContainer, eagerRefresh: false)
        manager.isICloudSyncEnabled = false
        XCTAssertEqual(manager.syncState, .disabled)
        XCTAssertEqual(manager.syncStateDescription, L10n.tr("同步已關閉", "同期オフ"))
    }

    func test_syncState_accountStatusTransitions() async {
        let mockContainer = MockCloudKitContainer(status: .noAccount)
        let manager = CloudKitSyncManager(container: mockContainer, eagerRefresh: false)
        manager.isICloudSyncEnabled = true

        await manager.refreshAccountStatus()
        XCTAssertEqual(manager.accountStatusDescription, L10n.tr("未登入 iCloud", "iCloud 未サインイン"))
        if case .failed(let msg) = manager.syncState {
            XCTAssertTrue(msg.contains("Apple ID"))
        } else {
            XCTFail("應為 failed 狀態")
        }

        manager.setAccountStatusForTesting(.restricted)
        XCTAssertEqual(manager.accountStatusDescription, L10n.tr("帳號受限制", "アカウント制限中"))

        manager.setAccountStatusForTesting(.available)
        XCTAssertEqual(manager.accountStatusDescription, L10n.tr("已連接 iCloud", "iCloud 接続済み"))
    }

    func test_relativeTimeString() {
        let now = Date()
        XCTAssertEqual(CloudKitSyncManager.relativeTimeString(from: now), L10n.tr("已同步 (剛剛)", "同期完了 (たった今)"))

        let fiveMinsAgo = now.addingTimeInterval(-300)
        XCTAssertEqual(CloudKitSyncManager.relativeTimeString(from: fiveMinsAgo), L10n.tr("已同步 (5 分鐘前)", "同期完了 (5分前)"))

        let twoHoursAgo = now.addingTimeInterval(-7200)
        XCTAssertEqual(CloudKitSyncManager.relativeTimeString(from: twoHoursAgo), L10n.tr("已同步 (2 小時前)", "同期完了 (2時間前)"))
    }
}
