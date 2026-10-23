import XCTest
import SwiftData
import SwiftUI
@testable import ChekiLens

@MainActor
final class RecentlyDeletedViewTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainerProvider.preview(withSampleData: false)
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func test_recentlyDeletedRoute_isHashable() {
        let route1 = RecentlyDeletedAlbumRoute()
        let route2 = RecentlyDeletedAlbumRoute()
        XCTAssertEqual(route1, route2)
        XCTAssertEqual(route1.hashValue, route2.hashValue)
    }

    func test_trashedItemsQuery_ordersByDeletedAtDescending() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current

        let date1 = calendar.date(byAdding: .day, value: -10, to: now)!
        let date2 = calendar.date(byAdding: .day, value: -2, to: now)!
        let date3 = calendar.date(byAdding: .day, value: -20, to: now)!

        let item1 = ChekiItem()
        item1.softDelete(at: date1)

        let item2 = ChekiItem()
        item2.softDelete(at: date2)

        let item3 = ChekiItem()
        item3.softDelete(at: date3)

        let activeItem = ChekiItem()

        context.insert(item1)
        context.insert(item2)
        context.insert(item3)
        context.insert(activeItem)
        try context.save()

        let trashed = try ChekiTrashManager.shared.fetchTrashedItems(in: context)
        XCTAssertEqual(trashed.count, 3)
        // 應由新到舊排序：date2 (-2) > date1 (-10) > date3 (-20)
        XCTAssertEqual(trashed[0].id, item2.id)
        XCTAssertEqual(trashed[1].id, item1.id)
        XCTAssertEqual(trashed[2].id, item3.id)
    }

    func test_batchRestore_restoresAllSelectedItems() throws {
        let item1 = ChekiItem()
        item1.softDelete()

        let item2 = ChekiItem()
        item2.softDelete()

        let item3 = ChekiItem()
        item3.softDelete()

        context.insert(item1)
        context.insert(item2)
        context.insert(item3)
        try context.save()

        // 僅復原 item1 與 item3
        try ChekiTrashManager.shared.restore([item1, item3], in: context)

        XCTAssertFalse(item1.isDeleted)
        XCTAssertTrue(item2.isDeleted)
        XCTAssertFalse(item3.isDeleted)

        let active = try ChekiTrashManager.shared.fetchActiveItems(in: context)
        XCTAssertEqual(active.count, 2)
        let activeIDs = Set(active.map(\.id))
        XCTAssertTrue(activeIDs.contains(item1.id))
        XCTAssertTrue(activeIDs.contains(item3.id))

        let remainingTrash = try ChekiTrashManager.shared.fetchTrashedItems(in: context)
        XCTAssertEqual(remainingTrash.count, 1)
        XCTAssertEqual(remainingTrash.first?.id, item2.id)
    }

    func test_batchPermanentDelete_deletesAllSelectedItems() async throws {
        let item1 = ChekiItem()
        item1.softDelete()

        let item2 = ChekiItem()
        item2.softDelete()

        context.insert(item1)
        context.insert(item2)
        try context.save()

        try await ChekiTrashManager.shared.permanentlyDelete([item1], in: context)

        let all = try context.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, item2.id)
    }

    func test_recentlyDeletedMenuLabel_formatsCount() {
        let title = L10n.tr("最近刪除", "最近削除した項目")

        let zeroCount = 0
        let zeroLabel = zeroCount > 0 ? "\(title) (\(zeroCount))" : title
        XCTAssertEqual(zeroLabel, title)

        let fiveCount = 5
        let fiveLabel = fiveCount > 0 ? "\(title) (\(fiveCount))" : title
        XCTAssertTrue(fiveLabel.contains("(5)"))
        XCTAssertTrue(fiveLabel.contains(title))
    }

    func test_recentlyDeletedAlbumRoute_canBeAppendedToNavigationPath() {
        var path = NavigationPath()
        XCTAssertEqual(path.count, 0)
        path.append(RecentlyDeletedAlbumRoute())
        XCTAssertEqual(path.count, 1)
    }
}
