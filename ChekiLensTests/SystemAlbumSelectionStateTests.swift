import XCTest
@testable import ChekiLens

final class SystemAlbumSelectionStateTests: XCTestCase {

    private func makeSampleHierarchy() -> SystemPhotoLibraryHierarchy {
        let album1 = SystemPhotoAlbumNode(
            id: "album-nogi-1",
            title: "山下美月",
            parentFolderID: "folder-nogi",
            parentFolderTitle: "乃木坂46",
            assetIdentifiers: ["p1", "p2", "p3"]
        )
        let album2 = SystemPhotoAlbumNode(
            id: "album-nogi-2",
            title: "与田祐希",
            parentFolderID: "folder-nogi",
            parentFolderTitle: "乃木坂46",
            assetIdentifiers: ["p4", "p5"]
        )
        let folderNogi = SystemPhotoFolderNode(
            id: "folder-nogi",
            title: "乃木坂46",
            albums: [album1, album2]
        )

        let album3 = SystemPhotoAlbumNode(
            id: "album-hina-1",
            title: "金村美玖",
            parentFolderID: "folder-hina",
            parentFolderTitle: "日向坂46",
            assetIdentifiers: ["p6", "p7", "p8", "p9"]
        )
        let folderHina = SystemPhotoFolderNode(
            id: "folder-hina",
            title: "日向坂46",
            albums: [album3]
        )

        let soloAlbum = SystemPhotoAlbumNode(
            id: "album-solo",
            title: "個人チェキ",
            parentFolderID: nil,
            parentFolderTitle: nil,
            assetIdentifiers: ["p10"]
        )

        return SystemPhotoLibraryHierarchy(
            folders: [folderNogi, folderHina],
            standaloneAlbums: [soloAlbum]
        )
    }

    func testApplyHierarchyDefaultExpansionAndSelectAll() {
        let hierarchy = makeSampleHierarchy()
        var state = SystemAlbumSelectionState()

        state.applyHierarchy(hierarchy, selectAllByDefault: false)
        // 預設全數收合資料夾，提升清單整潔度與載入體驗
        XCTAssertEqual(state.expandedFolderIDs, [])
        XCTAssertTrue(state.selectedAlbumIDs.isEmpty)
        XCTAssertFalse(state.isAllSelected)
        XCTAssertEqual(state.selectedAlbumCount, 0)
        XCTAssertEqual(state.selectedPhotoCount, 0)
        XCTAssertFalse(state.canProceed)

        state.applyHierarchy(hierarchy, selectAllByDefault: true)
        XCTAssertEqual(state.expandedFolderIDs, [])
        XCTAssertEqual(state.selectedAlbumIDs, ["album-nogi-1", "album-nogi-2", "album-hina-1", "album-solo"])
        XCTAssertTrue(state.isAllSelected)
        XCTAssertEqual(state.selectedAlbumCount, 4)
        XCTAssertEqual(state.selectedPhotoCount, 10)
        XCTAssertTrue(state.canProceed)
    }

    func testFolderSelectionStatusTransitions() {
        let hierarchy = makeSampleHierarchy()
        var state = SystemAlbumSelectionState()
        state.applyHierarchy(hierarchy, selectAllByDefault: false)

        XCTAssertEqual(state.folderSelectionStatus("folder-nogi"), .none)

        state.toggleAlbumSelection("album-nogi-1")
        XCTAssertEqual(state.folderSelectionStatus("folder-nogi"), .partial)

        state.toggleAlbumSelection("album-nogi-2")
        XCTAssertEqual(state.folderSelectionStatus("folder-nogi"), .all)

        state.toggleFolderSelection("folder-nogi")
        XCTAssertEqual(state.folderSelectionStatus("folder-nogi"), .none)
        XCTAssertFalse(state.isAlbumSelected("album-nogi-1"))
        XCTAssertFalse(state.isAlbumSelected("album-nogi-2"))

        state.toggleFolderSelection("folder-nogi")
        XCTAssertEqual(state.folderSelectionStatus("folder-nogi"), .all)
        XCTAssertTrue(state.isAlbumSelected("album-nogi-1"))
        XCTAssertTrue(state.isAlbumSelected("album-nogi-2"))
    }

    func testToggleSelectAllIdempotenceAndCounts() {
        let hierarchy = makeSampleHierarchy()
        var state = SystemAlbumSelectionState()
        state.applyHierarchy(hierarchy, selectAllByDefault: false)

        XCTAssertEqual(state.selectedAlbumCount, 0)
        XCTAssertEqual(state.selectedPhotoCount, 0)
        XCTAssertFalse(state.canProceed)

        state.toggleSelectAll()
        XCTAssertTrue(state.isAllSelected)
        XCTAssertEqual(state.selectedAlbumCount, 4)
        XCTAssertEqual(state.selectedPhotoCount, 10)
        XCTAssertTrue(state.canProceed)

        state.toggleSelectAll()
        XCTAssertFalse(state.isAllSelected)
        XCTAssertEqual(state.selectedAlbumCount, 0)
        XCTAssertEqual(state.selectedPhotoCount, 0)
        XCTAssertFalse(state.canProceed)

        state.toggleAlbumSelection("album-solo")
        XCTAssertFalse(state.isAllSelected)
        XCTAssertEqual(state.selectedAlbumCount, 1)
        XCTAssertEqual(state.selectedPhotoCount, 1)
        XCTAssertTrue(state.canProceed)

        state.toggleSelectAll()
        XCTAssertTrue(state.isAllSelected)
        XCTAssertEqual(state.selectedAlbumCount, 4)
        XCTAssertEqual(state.selectedPhotoCount, 10)
    }

    func testEdgeDetectionOverridesAndResolution() {
        let hierarchy = makeSampleHierarchy()
        var state = SystemAlbumSelectionState()
        state.applyHierarchy(hierarchy, selectAllByDefault: true)

        XCTAssertTrue(state.isAllEdgeDetectionEnabled)

        state.setAllEdgeDetection(false)
        XCTAssertFalse(state.isAllEdgeDetectionEnabled)
        for album in state.buildResolvedSelection() {
            XCTAssertFalse(album.enableEdgeDetection)
        }

        state.setFolderEdgeDetection(true, forFolder: "folder-nogi")
        XCTAssertFalse(state.isAllEdgeDetectionEnabled)
        let resolvedAfterFolder = Dictionary(uniqueKeysWithValues: state.buildResolvedSelection().map { ($0.id, $0.enableEdgeDetection) })
        XCTAssertEqual(resolvedAfterFolder["album-nogi-1"], true)
        XCTAssertEqual(resolvedAfterFolder["album-nogi-2"], true)
        XCTAssertEqual(resolvedAfterFolder["album-hina-1"], false)
        XCTAssertEqual(resolvedAfterFolder["album-solo"], false)

        state.setEdgeDetection(false, forAlbum: "album-nogi-1")
        let resolvedAfterAlbum = Dictionary(uniqueKeysWithValues: state.buildResolvedSelection().map { ($0.id, $0.enableEdgeDetection) })
        XCTAssertEqual(resolvedAfterAlbum["album-nogi-1"], false)
        XCTAssertEqual(resolvedAfterAlbum["album-nogi-2"], true)

        state.setAllEdgeDetection(true)
        XCTAssertTrue(state.isAllEdgeDetectionEnabled)
        for album in state.buildResolvedSelection() {
            XCTAssertTrue(album.enableEdgeDetection)
        }
    }

    func testSearchQueryFiltering() {
        let hierarchy = makeSampleHierarchy()
        var state = SystemAlbumSelectionState()
        state.applyHierarchy(hierarchy, selectAllByDefault: false)

        state.searchQuery = ""
        XCTAssertEqual(state.filteredFolders.count, 2)
        XCTAssertEqual(state.filteredStandaloneAlbums.count, 1)

        state.searchQuery = "日向坂"
        XCTAssertEqual(state.filteredFolders.map(\.title), ["日向坂46"])
        XCTAssertTrue(state.filteredStandaloneAlbums.isEmpty)

        state.searchQuery = "山下"
        XCTAssertEqual(state.filteredFolders.count, 1)
        XCTAssertEqual(state.filteredFolders.first?.id, "folder-nogi")
        XCTAssertEqual(state.filteredFolders.first?.albums.map(\.id), ["album-nogi-1"])
        XCTAssertTrue(state.filteredStandaloneAlbums.isEmpty)

        state.searchQuery = "チェキ"
        XCTAssertTrue(state.filteredFolders.isEmpty)
        XCTAssertEqual(state.filteredStandaloneAlbums.map(\.id), ["album-solo"])

        state.searchQuery = "不存在的偶像"
        XCTAssertTrue(state.filteredFolders.isEmpty)
        XCTAssertTrue(state.filteredStandaloneAlbums.isEmpty)
    }

    func testFolderExpansionToggle() {
        let hierarchy = makeSampleHierarchy()
        var state = SystemAlbumSelectionState()
        state.applyHierarchy(hierarchy, selectAllByDefault: false)

        // 預設收合
        XCTAssertFalse(state.isFolderExpanded("folder-nogi"))
        // 點擊展開
        state.toggleFolderExpansion("folder-nogi")
        XCTAssertTrue(state.isFolderExpanded("folder-nogi"))
        // 再次點擊收合
        state.toggleFolderExpansion("folder-nogi")
        XCTAssertFalse(state.isFolderExpanded("folder-nogi"))
    }
}
