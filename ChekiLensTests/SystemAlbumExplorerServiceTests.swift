import XCTest
import SwiftData
@testable import ChekiLens

// MARK: - SystemAlbumExplorerServiceTests

@MainActor
final class SystemAlbumExplorerServiceTests: XCTestCase {

    // MARK: - Hierarchy & Selection Tests

    func testHierarchyFlattensFoldersAndStandaloneAlbumsWithoutDuplicates() {
        let albumA1 = SystemPhotoAlbumNode(
            id: "album-a1",
            title: "金村美玖",
            parentFolderID: "folder-a",
            parentFolderTitle: "日向坂46",
            assetIdentifiers: ["asset-1", "asset-2"]
        )
        let albumA2 = SystemPhotoAlbumNode(
            id: "album-a2",
            title: "小坂菜緒",
            parentFolderID: "folder-a",
            parentFolderTitle: "日向坂46",
            assetIdentifiers: ["asset-3"]
        )
        let folderA = SystemPhotoFolderNode(
            id: "folder-a",
            title: "日向坂46",
            albums: [albumA1, albumA2]
        )

        let standaloneAlbum = SystemPhotoAlbumNode(
            id: "album-solo",
            title: "齋藤飛鳥",
            parentFolderID: nil,
            parentFolderTitle: nil,
            assetIdentifiers: ["asset-4", "asset-5", "asset-6"]
        )

        let hierarchy = SystemPhotoLibraryHierarchy(
            folders: [folderA],
            standaloneAlbums: [standaloneAlbum]
        )

        XCTAssertEqual(hierarchy.allAlbums.map(\.id), ["album-a1", "album-a2", "album-solo"])
        XCTAssertEqual(folderA.totalAssetCount, 3)
        XCTAssertEqual(standaloneAlbum.assetCount, 3)
        XCTAssertEqual(standaloneAlbum.coverAssetIdentifier, "asset-4")
    }

    func testFolderSelectionToggleAndPartialState() {
        let album1 = SystemPhotoAlbumNode(
            id: "album-1",
            title: "賀喜遥香",
            parentFolderID: "folder-nogi",
            parentFolderTitle: "乃木坂46",
            assetIdentifiers: ["p1"]
        )
        let album2 = SystemPhotoAlbumNode(
            id: "album-2",
            title: "遠藤さくら",
            parentFolderID: "folder-nogi",
            parentFolderTitle: "乃木坂46",
            assetIdentifiers: ["p2"]
        )
        let folder = SystemPhotoFolderNode(
            id: "folder-nogi",
            title: "乃木坂46",
            albums: [album1, album2]
        )
        let hierarchy = SystemPhotoLibraryHierarchy(folders: [folder])

        var selected: Set<String> = []
        XCTAssertFalse(hierarchy.isFolderFullySelected("folder-nogi", selectedAlbumIDs: selected))
        XCTAssertFalse(hierarchy.isFolderPartiallySelected("folder-nogi", selectedAlbumIDs: selected))

        // 單選其中一本相簿 -> 部分選取
        selected.insert("album-1")
        XCTAssertFalse(hierarchy.isFolderFullySelected("folder-nogi", selectedAlbumIDs: selected))
        XCTAssertTrue(hierarchy.isFolderPartiallySelected("folder-nogi", selectedAlbumIDs: selected))

        // 切換整個資料夾 -> 應變為全選
        selected = hierarchy.togglingFolder("folder-nogi", in: selected)
        XCTAssertTrue(hierarchy.isFolderFullySelected("folder-nogi", selectedAlbumIDs: selected))
        XCTAssertFalse(hierarchy.isFolderPartiallySelected("folder-nogi", selectedAlbumIDs: selected))
        XCTAssertEqual(selected, ["album-1", "album-2"])

        // 再次切換整個資料夾 -> 應全部取消
        selected = hierarchy.togglingFolder("folder-nogi", in: selected)
        XCTAssertTrue(selected.isEmpty)
    }

    func testResolvedSelectedAlbumsAppliesPerAlbumEdgeDetectionOverrides() {
        let album1 = SystemPhotoAlbumNode(
            id: "album-raw",
            title: "未裁切相簿",
            assetIdentifiers: ["a1"]
        )
        let album2 = SystemPhotoAlbumNode(
            id: "album-cropped",
            title: "已裁切相簿",
            assetIdentifiers: ["a2"]
        )
        let hierarchy = SystemPhotoLibraryHierarchy(standaloneAlbums: [album1, album2])

        let resolved = hierarchy.resolvedSelectedAlbums(
            selectedAlbumIDs: ["album-raw", "album-cropped"],
            edgeDetectionOverrides: ["album-cropped": false],
            defaultEdgeDetection: true
        )

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved.first(where: { $0.id == "album-raw" })?.enableEdgeDetection, true)
        XCTAssertEqual(resolved.first(where: { $0.id == "album-cropped" })?.enableEdgeDetection, false)
    }

    // MARK: - Duplicate Asset Filtering & Name Normalization Tests

    func testCollectAndFilterDuplicateAssetIdentifiers() {
        let existingItem1 = ChekiItem(
            frontAssetIdentifier: "asset-existing-front",
            backAssetIdentifier: "asset-existing-back"
        )
        let existingItem2 = ChekiItem(
            frontAssetIdentifier: "  asset-trimmed  "
        )

        let existingSet = SystemAlbumExplorerService.collectExistingAssetIdentifiers(
            from: [existingItem1, existingItem2]
        )
        XCTAssertEqual(existingSet, ["asset-existing-front", "asset-existing-back", "asset-trimmed"])

        let candidates = [
            "asset-new-1",
            "asset-existing-front",
            "asset-new-2",
            "asset-new-1",          // 同批次重複
            "asset-existing-back",
            "asset-trimmed"
        ]

        let result = SystemAlbumExplorerService.filterNewAssetIdentifiers(
            candidates,
            excluding: existingSet
        )

        XCTAssertEqual(result.newIdentifiers, ["asset-new-1", "asset-new-2"])
        XCTAssertEqual(result.skippedDuplicateCount, 4)
    }

    func testNormalizedNameKeyMatchesFullWidthHalfWidthAndWhitespace() {
        let key1 = SystemAlbumExplorerService.normalizedNameKey("  日向坂46 ")
        let key2 = SystemAlbumExplorerService.normalizedNameKey("日向坂４６")
        XCTAssertEqual(key1, key2)
    }

    func testInferFilmFormatFromAspectRatioWhenEdgeDetectionDisabled() {
        // Instax Mini (約 54:86)
        XCTAssertEqual(
            SystemAlbumExplorerService.inferFilmFormat(for: CGSize(width: 810, height: 1290)),
            .mini
        )
        // Instax Square (約 72:86)
        XCTAssertEqual(
            SystemAlbumExplorerService.inferFilmFormat(for: CGSize(width: 1080, height: 1290)),
            .square
        )
        // Instax Wide (橫向 108:86)
        XCTAssertEqual(
            SystemAlbumExplorerService.inferFilmFormat(for: CGSize(width: 1620, height: 1290)),
            .wide
        )
    }
}
