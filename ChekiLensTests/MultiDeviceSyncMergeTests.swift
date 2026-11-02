import XCTest
import SwiftData
@testable import ChekiLens

@MainActor
final class MultiDeviceSyncMergeTests: XCTestCase {

    var containerA: ModelContainer!
    var contextA: ModelContext!

    var containerB: ModelContainer!
    var contextB: ModelContext!

    override func setUpWithError() throws {
        containerA = try ModelContainerProvider.preview(withSampleData: false)
        contextA = containerA.mainContext

        containerB = try ModelContainerProvider.preview(withSampleData: false)
        contextB = containerB.mainContext
    }

    override func tearDownWithError() throws {
        containerA = nil
        contextA = nil
        containerB = nil
        contextB = nil
    }

    // MARK: - 1. LWW (Last-Write-Wins) Basic Rules

    func test_LWW_newerEditWinsOverOlderState() throws {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000) // 1000 秒後

        let itemA = ChekiItem(
            capturedAt: t1,
            ocrDate: t1,
            lastModifiedAt: t1
        )
        contextA.insert(itemA)
        try contextA.save()

        let incomingB = ChekiItem(
            id: itemA.id,
            capturedAt: t2,
            ocrDate: t2,
            lastModifiedAt: t2
        )

        let didMerge = itemA.mergeLWW(with: incomingB)

        XCTAssertTrue(didMerge, "較新的變更應合併成功")
        XCTAssertEqual(itemA.lastModifiedAt, t2)
        XCTAssertEqual(itemA.ocrDate, t2)
        XCTAssertEqual(itemA.capturedAt, t2)
    }

    func test_LWW_olderEditIsIgnored() throws {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000)

        let itemA = ChekiItem(
            capturedAt: t2,
            ocrDate: t2,
            lastModifiedAt: t2
        )
        contextA.insert(itemA)
        try contextA.save()

        let incomingOlder = ChekiItem(
            id: itemA.id,
            capturedAt: t1,
            ocrDate: t1,
            lastModifiedAt: t1
        )

        let didMerge = itemA.mergeLWW(with: incomingOlder)

        XCTAssertFalse(didMerge, "過舊的變更應被略過")
        XCTAssertEqual(itemA.lastModifiedAt, t2)
        XCTAssertEqual(itemA.ocrDate, t2)
    }

    // MARK: - 2. Soft-Delete & Restore Convergence

    func test_softDeleteSync_newerDeleteWinsOverOlderEdit() throws {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_002_000)

        // 裝置 A：在 t1 編輯
        let itemA = ChekiItem(lastModifiedAt: t1)
        XCTAssertFalse(itemA.isDeleted)

        // 裝置 B：在 t2 (較新) 移入最近刪除
        let incomingB = ChekiItem(id: itemA.id, lastModifiedAt: t2)
        incomingB.softDelete(at: t2)

        let didMerge = itemA.mergeLWW(with: incomingB)

        XCTAssertTrue(didMerge)
        XCTAssertTrue(itemA.isDeleted)
        XCTAssertEqual(itemA.deletedAt, t2)
        XCTAssertEqual(itemA.lastModifiedAt, t2)
    }

    func test_softDeleteSync_newerRestoreWinsOverOlderDelete() throws {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_003_000)

        // 裝置 A：在 t1 遭軟刪除
        let itemA = ChekiItem(deletedAt: t1, lastModifiedAt: t1)
        XCTAssertTrue(itemA.isDeleted)

        // 裝置 B：在 t2 (較新) 復原
        let incomingB = ChekiItem(id: itemA.id, deletedAt: nil, lastModifiedAt: t2)

        let didMerge = itemA.mergeLWW(with: incomingB)

        XCTAssertTrue(didMerge)
        XCTAssertFalse(itemA.isDeleted)
        XCTAssertNil(itemA.deletedAt)
        XCTAssertEqual(itemA.lastModifiedAt, t2)
    }

    // MARK: - 3. Offline Updates & Reconnect

    func test_offlineUpdate_reconnectLWWResolution() throws {
        let tOnline = Date(timeIntervalSince1970: 1_700_000_000)
        let tOfflineNewer = Date(timeIntervalSince1970: 1_700_005_000)

        // 裝置 A 離線更新，最後修改時間為 tOfflineNewer
        let offlineItem = ChekiItem(
            lastModifiedAt: tOfflineNewer,
            borderInsetRatio: 0.02
        )

        // 裝置 B 線上版本，修改時間為 tOnline
        let onlineItem = ChekiItem(
            id: offlineItem.id,
            lastModifiedAt: tOnline,
            borderInsetRatio: -0.01
        )

        // 當裝置 A 重新連線並合併至線上版本時
        let didMerge = onlineItem.mergeLWW(with: offlineItem)

        XCTAssertTrue(didMerge)
        XCTAssertEqual(onlineItem.borderInsetRatio, 0.02, accuracy: 0.0001)
        XCTAssertEqual(onlineItem.lastModifiedAt, tOfflineNewer)
    }

    // MARK: - 4. ChekiMemo LWW Resolution

    func test_memo_LWW_mergesFieldChanges() throws {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000)

        let memoA = ChekiMemo(
            eventName: "舊活動",
            noteText: "舊筆記",
            hashtags: ["#old"],
            lastModifiedAt: t1
        )

        let incomingMemoB = ChekiMemo(
            id: memoA.id,
            eventName: "新見面會",
            noteText: "最新對話筆記",
            hashtags: ["#new", "#event"],
            lastModifiedAt: t2
        )

        let didMerge = memoA.mergeLWW(with: incomingMemoB)

        XCTAssertTrue(didMerge)
        XCTAssertEqual(memoA.eventName, "新見面會")
        XCTAssertEqual(memoA.noteText, "最新對話筆記")
        XCTAssertEqual(memoA.hashtags, ["#new", "#event"])
        XCTAssertEqual(memoA.lastModifiedAt, t2)
    }

    // MARK: - 5. Cross-Store Migration LWW Integration

    func test_modelContainerProvider_crossStoreLWW_mergesExistingItems() throws {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_002_000)

        let sharedID = UUID()

        // Target 容器中已有舊版本
        let targetItem = ChekiItem(
            id: sharedID,
            ocrDate: t1,
            lastModifiedAt: t1
        )
        contextB.insert(targetItem)
        try contextB.save()

        // Source 容器中有新版本（例如本機離線修改後同步至 CloudKit 目標容器）
        let sourceItem = ChekiItem(
            id: sharedID,
            ocrDate: t2,
            lastModifiedAt: t2
        )
        contextA.insert(sourceItem)
        try contextA.save()

        // Act: 執行跨 Store 遷移合併
        let counts = try ModelContainerProvider.migrateData(
            from: containerA,
            to: containerB
        )

        // Assert: 既有物件應成功以 LWW 規則合併
        XCTAssertEqual(counts.chekis, 1)

        let targetFetched = try contextB.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(targetFetched.count, 1)
        let merged = try XCTUnwrap(targetFetched.first)
        XCTAssertEqual(merged.lastModifiedAt, t2)
        XCTAssertEqual(merged.ocrDate, t2)
    }
}
