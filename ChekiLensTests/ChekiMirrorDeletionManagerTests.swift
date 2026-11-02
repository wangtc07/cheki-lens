import XCTest
import SwiftData
@testable import ChekiLens

@MainActor
final class ChekiMirrorDeletionManagerTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    var mockAdapter: MockMirrorPhotoLibraryAdapter!
    var mirrorManager: ChekiMirrorDeletionManager!

    override func setUpWithError() throws {
        container = try ModelContainerProvider.preview(withSampleData: false)
        context = container.mainContext
        mockAdapter = MockMirrorPhotoLibraryAdapter()
        mirrorManager = ChekiMirrorDeletionManager(adapter: mockAdapter)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        mockAdapter = nil
        mirrorManager = nil
    }

    func test_remoteDeletion_whenAutoDeletePhotosEnabled_deletesAssetFromPhotos() async throws {
        let item = ChekiItem()
        item.frontAssetIdentifier = "asset-001"
        item.backAssetIdentifier = "asset-002"
        item.softDelete()
        item.isSyncedToPhotoLibrary = true

        context.insert(item)
        try context.save()

        mockAdapter.existingAssetIDs = ["asset-001", "asset-002"]

        let result = await mirrorManager.reconcileMirrorDeletions(in: context, autoDeleteFromPhotos: true)

        XCTAssertEqual(result.assetsDeletedCount, 2)
        XCTAssertEqual(Set(mockAdapter.deletedAssetIDs), Set(["asset-001", "asset-002"]))
        XCTAssertFalse(item.isSyncedToPhotoLibrary)
    }

    func test_remoteDeletion_whenAutoDeletePhotosDisabled_preservesAssetInPhotos() async throws {
        let item = ChekiItem()
        item.frontAssetIdentifier = "asset-001"
        item.softDelete()
        item.isSyncedToPhotoLibrary = true

        context.insert(item)
        try context.save()

        mockAdapter.existingAssetIDs = ["asset-001"]

        let result = await mirrorManager.reconcileMirrorDeletions(in: context, autoDeleteFromPhotos: false)

        XCTAssertEqual(result.assetsDeletedCount, 0)
        XCTAssertTrue(mockAdapter.deletedAssetIDs.isEmpty)
        XCTAssertTrue(mockAdapter.existingAssetIDs.contains("asset-001"), "相片應保留於系統相簿")
    }

    func test_remoteDeletion_whenAssetAlreadyNotInPhotos_skipsGracefully() async throws {
        let item = ChekiItem()
        item.frontAssetIdentifier = "asset-gone"
        item.softDelete()

        context.insert(item)
        try context.save()

        mockAdapter.existingAssetIDs = []

        let result = await mirrorManager.reconcileMirrorDeletions(in: context, autoDeleteFromPhotos: true)

        XCTAssertEqual(result.assetsDeletedCount, 0)
        XCTAssertTrue(mockAdapter.deletedAssetIDs.isEmpty)
    }

    func test_remoteRestore_whenAutoSyncEnabled_reExportsOrSyncsToPhotos() async throws {
        let item = ChekiItem()
        item.frontImageData = Data([0xFF, 0xD8, 0xFF])
        item.deletedAt = nil // 遠端復原
        item.isSyncedToPhotoLibrary = false

        context.insert(item)
        try context.save()

        let result = await mirrorManager.reconcileMirrorDeletions(in: context, autoDeleteFromPhotos: true)

        XCTAssertEqual(result.assetsRestoredCount, 1)
        XCTAssertTrue(mockAdapter.syncedItemIDs.contains(item.id))
        XCTAssertTrue(item.isSyncedToPhotoLibrary)
    }

    func test_remoteRestore_whenAlreadySyncedAndAssetExists_skipsRedundantSync() async throws {
        let item = ChekiItem()
        item.frontImageData = Data([0xFF, 0xD8, 0xFF])
        item.frontAssetIdentifier = "asset-existing"
        item.deletedAt = nil
        item.isSyncedToPhotoLibrary = false

        context.insert(item)
        try context.save()

        mockAdapter.existingAssetIDs = ["asset-existing"]

        let result = await mirrorManager.reconcileMirrorDeletions(in: context, autoDeleteFromPhotos: true)

        XCTAssertEqual(result.assetsRestoredCount, 0)
        XCTAssertTrue(mockAdapter.syncedItemIDs.isEmpty)
        XCTAssertTrue(item.isSyncedToPhotoLibrary)
    }
}
