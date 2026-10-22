import XCTest
import UIKit
@testable import ChekiLens

final class StagingImportShelfStateTests: XCTestCase {

    private func makeSampleNodes() -> [SystemPhotoAlbumNode] {
        let album1 = SystemPhotoAlbumNode(
            id: "album-nogi-1",
            title: "賀喜遥香",
            parentFolderID: "folder-nogi",
            parentFolderTitle: "乃木坂46",
            assetIdentifiers: ["p1", "p2", "p3"],
            enableEdgeDetection: true
        )
        let album2 = SystemPhotoAlbumNode(
            id: "album-nogi-2",
            title: "遠藤さくら",
            parentFolderID: "folder-nogi",
            parentFolderTitle: "乃木坂46",
            assetIdentifiers: ["p3", "p4"],
            enableEdgeDetection: false
        )
        let albumSolo = SystemPhotoAlbumNode(
            id: "album-solo-1",
            title: "個人チェキ",
            parentFolderID: nil,
            parentFolderTitle: nil,
            assetIdentifiers: ["p5"],
            enableEdgeDetection: true
        )
        let albumEmpty = SystemPhotoAlbumNode(
            id: "album-empty-1",
            title: "空相簿",
            parentFolderID: nil,
            parentFolderTitle: nil,
            assetIdentifiers: [],
            enableEdgeDetection: true
        )
        return [album1, album2, albumSolo, albumEmpty]
    }

    func testInitializationDeduplicationAndGroupMapping() {
        let nodes = makeSampleNodes()
        let existingIDs: Set<String> = ["p1"]

        let state = StagingImportShelfState(
            albums: nodes,
            existingGroupNames: ["乃木坂46"],
            existingAssetIDs: existingIDs
        )

        XCTAssertEqual(state.cards.count, 4)

        let card1 = state.cards[0]
        XCTAssertEqual(card1.id, "album-nogi-1")
        XCTAssertEqual(card1.memberName, "賀喜遥香")
        XCTAssertEqual(card1.groupName, "乃木坂46")
        XCTAssertEqual(card1.sourceAssetIdentifiers, ["p2", "p3"])
        XCTAssertEqual(card1.skippedDuplicateCount, 1)
        XCTAssertEqual(card1.loadPhase, .pending)

        let card2 = state.cards[1]
        XCTAssertEqual(card2.id, "album-nogi-2")
        XCTAssertEqual(card2.memberName, "遠藤さくら")
        XCTAssertEqual(card2.sourceAssetIdentifiers, ["p4"])
        XCTAssertEqual(card2.skippedDuplicateCount, 1)
        XCTAssertFalse(card2.enableEdgeDetection)

        let cardSolo = state.cards[2]
        XCTAssertNil(cardSolo.groupName)
        XCTAssertEqual(cardSolo.sourceAssetIdentifiers, ["p5"])
        XCTAssertEqual(cardSolo.skippedDuplicateCount, 0)

        let cardEmpty = state.cards[3]
        XCTAssertEqual(cardEmpty.sourceAssetIdentifiers, [])
        XCTAssertEqual(cardEmpty.loadPhase, .completed)
        XCTAssertTrue(cardEmpty.isReadyForInspection)
    }

    func testSectionsGroupingAndBatchAssignment() {
        let nodes = makeSampleNodes()
        var state = StagingImportShelfState(albums: nodes)

        let initialSections = state.sections
        XCTAssertEqual(initialSections.count, 2)
        XCTAssertEqual(initialSections[0].groupName, "乃木坂46")
        XCTAssertEqual(initialSections[0].cards.count, 2)
        XCTAssertNil(initialSections[1].groupName)
        XCTAssertEqual(initialSections[1].displayTitle, "未分類")
        XCTAssertEqual(initialSections[1].cards.count, 2)

        state.toggleCardSelection("album-solo-1")
        XCTAssertTrue(state.selectedCardIDs.contains("album-solo-1"))

        state.assignSelectedCards(toGroup: "新所屬團體")
        XCTAssertTrue(state.selectedCardIDs.isEmpty)
        XCTAssertFalse(state.isSelectionMode)

        let cardSolo = state.cards.first { $0.id == "album-solo-1" }
        XCTAssertEqual(cardSolo?.groupName, "新所屬團體")
        XCTAssertTrue(state.availableGroupNames.contains("新所屬團體"))

        state.toggleCardSelection("album-nogi-1")
        state.assignSelectedCards(toGroup: nil)
        let card1 = state.cards.first { $0.id == "album-nogi-1" }
        XCTAssertNil(card1?.groupName)

        let updatedSections = state.sections
        let ungrouped = updatedSections.first { $0.groupName == nil }
        XCTAssertNotNil(ungrouped)
        XCTAssertTrue(ungrouped?.cards.contains { $0.id == "album-nogi-1" } ?? false)
    }

    func testRenameGroupAndRenameMemberCard() {
        let nodes = makeSampleNodes()
        var state = StagingImportShelfState(albums: nodes, existingGroupNames: ["乃木坂46"])

        state.renameGroup(from: "乃木坂46", to: "乃木坂46合同會社")
        XCTAssertTrue(state.availableGroupNames.contains("乃木坂46合同會社"))
        XCTAssertFalse(state.availableGroupNames.contains("乃木坂46"))

        for card in state.cards where card.id == "album-nogi-1" || card.id == "album-nogi-2" {
            XCTAssertEqual(card.groupName, "乃木坂46合同會社")
        }

        state.renameMemberCard("album-nogi-1", to: "かっきー")
        let updatedCard = state.cards.first { $0.id == "album-nogi-1" }
        XCTAssertEqual(updatedCard?.memberName, "かっきー")
    }

    func testLoadProgressTransitionsAndIdempotentSlotAppend() {
        let nodes = [
            SystemPhotoAlbumNode(id: "c1", title: "成員1", assetIdentifiers: ["img1", "img2"]),
            SystemPhotoAlbumNode(id: "c2", title: "成員2", assetIdentifiers: ["img3", "img4"])
        ]
        var state = StagingImportShelfState(albums: nodes)

        XCTAssertFalse(state.allCardsLoaded)
        XCTAssertFalse(state.canCommitImport)
        XCTAssertEqual(state.overallProgressFraction, 0.0)

        state.updateCardLoadProgress("c1", loadedCount: 1, totalCount: 2)
        XCTAssertEqual(state.overallProgressFraction, 0.25)

        let dummyPhoto = StagingChekiPhoto(
            id: UUID(),
            sequenceNumber: 1,
            title: "Photo #1",
            assetIdentifier: "img1",
            imageData: Data(),
            uiImage: UIImage(),
            detectedSide: .likelyFront,
            detectionNote: "test"
        )
        let dummySlot = ChekiPairingSlot(id: UUID(), frontPhoto: dummyPhoto, backPhoto: nil)
        state.appendLoadedSlot(dummySlot, toCard: "c1")
        state.appendLoadedSlot(dummySlot, toCard: "c1")
        XCTAssertEqual(state.totalActiveSlotCount, 1)

        state.markCardCompleted("c1")
        XCTAssertEqual(state.overallProgressFraction, 0.5)

        state.markCardCompleted("c2")
        XCTAssertTrue(state.allCardsLoaded)
        XCTAssertEqual(state.overallProgressFraction, 1.0)
        XCTAssertTrue(state.canCommitImport)
    }

    func testMakePreCroppedStagingPhoto() {
        let dummyImage = UIGraphicsImageRenderer(size: CGSize(width: 810, height: 1290)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 810, height: 1290))
        }
        let dummyData = dummyImage.jpegData(compressionQuality: 0.9)!
        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let ocrDate = Date(timeIntervalSince1970: 1700500000)

        let payload = SystemImportedAssetPayload(
            assetIdentifier: "test-asset-123",
            imageData: dummyData,
            uiImage: dummyImage,
            creationDate: fixedDate,
            pixelSize: CGSize(width: 810, height: 1290)
        )

        let photo = StagingAlbumPhotoProcessor.makePreCroppedStagingPhoto(
            from: payload,
            sequenceNumber: 42,
            recognizedOCRDate: ocrDate
        )

        XCTAssertEqual(photo.sequenceNumber, 42)
        XCTAssertEqual(photo.assetIdentifier, "test-asset-123")
        XCTAssertEqual(photo.shutterDate, fixedDate)
        XCTAssertEqual(photo.detectedOCRDate, ocrDate)
        XCTAssertEqual(photo.resolvedFilmFormat, .mini)
        XCTAssertTrue(photo.hasCompletedBoundaryDetection)
        XCTAssertTrue(photo.isRevertedToOriginal)
        XCTAssertNil(photo.croppedImageData)
        XCTAssertNil(photo.normalizedCornersJSON)
    }
}
