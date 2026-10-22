import XCTest
import SwiftData
import UIKit
@testable import ChekiLens

@MainActor
final class ChekiTrashManagerTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    var trashManager: ChekiTrashManager!

    override func setUpWithError() throws {
        container = try ModelContainerProvider.preview(withSampleData: false)
        context = container.mainContext
        trashManager = ChekiTrashManager.shared
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        trashManager = nil
    }

    // MARK: - Soft Delete & Query Filtering Tests

    func test_softDelete_marksDeletedAt_andExcludesFromActiveItems() throws {
        let activeItem = ChekiItem()
        let trashedItem = ChekiItem()
        context.insert(activeItem)
        context.insert(trashedItem)
        try context.save()

        let deleteDate = Date(timeIntervalSince1970: 1_700_000_000)
        try trashManager.softDelete([trashedItem], in: context, at: deleteDate)

        XCTAssertTrue(trashedItem.isDeleted)
        XCTAssertEqual(trashedItem.deletedAt, deleteDate)
        XCTAssertFalse(activeItem.isDeleted)
        XCTAssertNil(activeItem.deletedAt)

        let activeItems = try trashManager.fetchActiveItems(in: context)
        XCTAssertEqual(activeItems.count, 1)
        XCTAssertEqual(activeItems.first?.id, activeItem.id)

        let trashedItems = try trashManager.fetchTrashedItems(in: context)
        XCTAssertEqual(trashedItems.count, 1)
        XCTAssertEqual(trashedItems.first?.id, trashedItem.id)
    }

    func test_restore_clearsDeletedAt_andReturnsToActiveItems() throws {
        let item = ChekiItem()
        context.insert(item)
        try context.save()

        try trashManager.softDelete([item], in: context)
        XCTAssertTrue(item.isDeleted)

        try trashManager.restore([item], in: context)
        XCTAssertFalse(item.isDeleted)
        XCTAssertNil(item.deletedAt)

        let active = try trashManager.fetchActiveItems(in: context)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, item.id)

        let trashed = try trashManager.fetchTrashedItems(in: context)
        XCTAssertTrue(trashed.isEmpty)
    }

    // MARK: - Expiration & Days Remaining Tests

    func test_daysRemaining_andIsExpired_boundaryConditions() throws {
        let calendar = Calendar.current
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let item = ChekiItem()
        item.softDelete(at: t0)

        // Day 0: 30 days remaining, not expired
        XCTAssertEqual(item.daysRemaining(relativeTo: t0, expirationDays: 30), 30)
        XCTAssertFalse(item.isExpired(relativeTo: t0, expirationDays: 30))

        // Day 10: 20 days remaining, not expired
        let day10 = calendar.date(byAdding: .day, value: 10, to: t0)!
        XCTAssertEqual(item.daysRemaining(relativeTo: day10, expirationDays: 30), 20)
        XCTAssertFalse(item.isExpired(relativeTo: day10, expirationDays: 30))

        // Day 29: 1 day remaining, not expired
        let day29 = calendar.date(byAdding: .day, value: 29, to: t0)!
        XCTAssertEqual(item.daysRemaining(relativeTo: day29, expirationDays: 30), 1)
        XCTAssertFalse(item.isExpired(relativeTo: day29, expirationDays: 30))

        // Day 30: 0 days remaining, expired
        let day30 = calendar.date(byAdding: .day, value: 30, to: t0)!
        XCTAssertEqual(item.daysRemaining(relativeTo: day30, expirationDays: 30), 0)
        XCTAssertTrue(item.isExpired(relativeTo: day30, expirationDays: 30))

        // Day 35: 0 days remaining (clamped to 0), expired
        let day35 = calendar.date(byAdding: .day, value: 35, to: t0)!
        XCTAssertEqual(item.daysRemaining(relativeTo: day35, expirationDays: 30), 0)
        XCTAssertTrue(item.isExpired(relativeTo: day35, expirationDays: 30))
    }

    func test_notDeletedItem_isNeverExpired() throws {
        let activeItem = ChekiItem()
        XCTAssertFalse(activeItem.isExpired())
        XCTAssertEqual(activeItem.daysRemainingUntilPermanentDeletion, 30)
    }

    // MARK: - 30-Day Auto Purge Pipeline Tests

    func test_purgeExpiredItems_removesOnlyItemsOlderThan30Days() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current

        let expiredDate = calendar.date(byAdding: .day, value: -35, to: now)!
        let recentDeletedDate = calendar.date(byAdding: .day, value: -10, to: now)!

        let expiredItem = ChekiItem()
        expiredItem.softDelete(at: expiredDate)

        let recentDeletedItem = ChekiItem()
        recentDeletedItem.softDelete(at: recentDeletedDate)

        let activeItem = ChekiItem()

        context.insert(expiredItem)
        context.insert(recentDeletedItem)
        context.insert(activeItem)
        try context.save()

        let initialAll = try context.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(initialAll.count, 3)

        // Act: Purge expired items relative to `now`
        let purgedCount = try await trashManager.purgeExpiredItems(
            in: context,
            referenceDate: now,
            expirationDays: 30
        )

        // Assert
        XCTAssertEqual(purgedCount, 1)

        let remaining = try context.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(remaining.count, 2)

        let remainingIDs = Set(remaining.map(\.id))
        XCTAssertFalse(remainingIDs.contains(expiredItem.id), "過期項目應被永久刪除")
        XCTAssertTrue(remainingIDs.contains(recentDeletedItem.id), "未過期垃圾桶項目應保留")
        XCTAssertTrue(remainingIDs.contains(activeItem.id), "有效項目應保留")
    }

    func test_emptyTrash_removesAllTrashedItemsRegardlessOfAge() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current

        let oldDate = calendar.date(byAdding: .day, value: -40, to: now)!
        let newDate = calendar.date(byAdding: .day, value: -2, to: now)!

        let item1 = ChekiItem()
        item1.softDelete(at: oldDate)

        let item2 = ChekiItem()
        item2.softDelete(at: newDate)

        let active = ChekiItem()

        context.insert(item1)
        context.insert(item2)
        context.insert(active)
        try context.save()

        let purged = try await trashManager.emptyTrash(in: context)
        XCTAssertEqual(purged, 2)

        let remaining = try context.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, active.id)
    }

    func test_emptyTrash_whenNoTrashedItems_returnsZero() async throws {
        let active = ChekiItem()
        context.insert(active)
        try context.save()

        let purged = try await trashManager.emptyTrash(in: context)
        XCTAssertEqual(purged, 0)

        let remaining = try context.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - Cache Eviction on Permanent Deletion

    func test_permanentDeletion_evictsImageCache() async throws {
        let item = ChekiItem()
        context.insert(item)
        try context.save()

        let cache = ChekiImageCacheManager.shared
        let thumbKey = cache.cacheKey(for: item.id, type: .thumbnail)
        let sampleImage = UIImage(systemName: "photo") ?? UIImage()
        cache.setMemoryImage(sampleImage, forKey: thumbKey)

        XCTAssertNotNil(cache.memoryImage(forKey: thumbKey))

        // Act: Permanently delete
        try await trashManager.permanentlyDelete([item], in: context)

        // Assert: Cache entry evicted
        XCTAssertNil(cache.memoryImage(forKey: thumbKey))
    }

    // MARK: - Predicate Queries

    func test_activeAndDeletedPredicates() throws {
        let active = ChekiItem()
        let trashed = ChekiItem()
        trashed.softDelete()

        context.insert(active)
        context.insert(trashed)
        try context.save()

        let activeFetched = try context.fetch(FetchDescriptor<ChekiItem>(predicate: ChekiItem.activePredicate))
        XCTAssertEqual(activeFetched.count, 1)
        XCTAssertEqual(activeFetched.first?.id, active.id)

        let deletedFetched = try context.fetch(FetchDescriptor<ChekiItem>(predicate: ChekiItem.deletedPredicate))
        XCTAssertEqual(deletedFetched.count, 1)
        XCTAssertEqual(deletedFetched.first?.id, trashed.id)
    }
}
