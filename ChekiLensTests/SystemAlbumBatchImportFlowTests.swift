import XCTest
@testable import ChekiLens

@MainActor
final class SystemAlbumBatchImportFlowTests: XCTestCase {

    func testInitialStepIsSelectingAlbums() {
        let state = SystemAlbumBatchImportFlowState()
        XCTAssertEqual(state.step, .selectingAlbums)
    }

    func testAdvanceToStagingShelfIgnoresEmptySelection() {
        var state = SystemAlbumBatchImportFlowState()
        state.advanceToStagingShelf(selectedAlbums: [])
        XCTAssertEqual(state.step, .selectingAlbums)
    }

    func testAdvanceToStagingShelfBuildsShelfWithDeduplicatedAssetsAndGroups() {
        var state = SystemAlbumBatchImportFlowState()
        let albums = [
            SystemPhotoAlbumNode(
                id: "album-1",
                title: "Airi",
                parentFolderID: "folder-1",
                parentFolderTitle: "Group Alpha",
                assetIdentifiers: ["asset-1", "asset-2", "asset-3"],
                coverAssetIdentifier: "asset-1",
                enableEdgeDetection: false
            ),
            SystemPhotoAlbumNode(
                id: "album-2",
                title: "Momo",
                parentFolderID: nil,
                parentFolderTitle: nil,
                assetIdentifiers: ["asset-2", "asset-4"],
                coverAssetIdentifier: "asset-2",
                enableEdgeDetection: true
            )
        ]

        state.advanceToStagingShelf(
            selectedAlbums: albums,
            existingGroupNames: ["Existing Group"],
            existingAssetIDs: ["asset-1"]
        )

        guard case .stagingShelf(let shelfState) = state.step else {
            XCTFail("Expected .stagingShelf step")
            return
        }

        XCTAssertEqual(shelfState.cards.count, 2)
        XCTAssertEqual(shelfState.cards[0].memberName, "Airi")
        XCTAssertEqual(shelfState.cards[0].groupName, "Group Alpha")
        XCTAssertEqual(shelfState.cards[0].sourceAssetIdentifiers, ["asset-2", "asset-3"])
        XCTAssertEqual(shelfState.cards[0].skippedDuplicateCount, 1)
        XCTAssertFalse(shelfState.cards[0].enableEdgeDetection)

        XCTAssertEqual(shelfState.cards[1].memberName, "Momo")
        XCTAssertNil(shelfState.cards[1].groupName)
        XCTAssertEqual(shelfState.cards[1].sourceAssetIdentifiers, ["asset-4"])
        XCTAssertEqual(shelfState.cards[1].skippedDuplicateCount, 1)
        XCTAssertTrue(shelfState.cards[1].enableEdgeDetection)

        XCTAssertEqual(shelfState.availableGroupNames, ["Existing Group", "Group Alpha"])
    }

    func testReturnToAlbumSelectionPreservesSelectionStateAndResetsStep() {
        var state = SystemAlbumBatchImportFlowState()
        let album = SystemPhotoAlbumNode(
            id: "album-1",
            title: "Airi",
            parentFolderID: nil,
            parentFolderTitle: nil,
            assetIdentifiers: ["asset-1"],
            coverAssetIdentifier: "asset-1",
            enableEdgeDetection: true
        )
        let hierarchy = SystemPhotoLibraryHierarchy(folders: [], standaloneAlbums: [album])
        state.selectionState.applyHierarchy(hierarchy, selectAllByDefault: true)
        state.selectionState.setEdgeDetection(false, forAlbum: "album-1")

        state.advanceToStagingShelf(selectedAlbums: state.selectionState.buildResolvedSelection())
        if case .stagingShelf(var shelfState) = state.step {
            shelfState.assignCard("album-1", toGroup: "New Group")
            state.step = .stagingShelf(shelfState)
        } else {
            XCTFail("Expected .stagingShelf step")
        }

        state.returnToAlbumSelection()
        XCTAssertEqual(state.step, .selectingAlbums)
        XCTAssertTrue(state.selectionState.isAlbumSelected("album-1"))
        XCTAssertFalse(state.selectionState.isEdgeDetectionEnabled(for: "album-1"))
    }
}
