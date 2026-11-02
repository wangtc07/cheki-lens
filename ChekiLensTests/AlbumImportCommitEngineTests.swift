import XCTest
import SwiftData
import UIKit
@testable import ChekiLens

@MainActor
final class AlbumImportCommitEngineTests: XCTestCase {

    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([
            ChekiItem.self,
            IdolGroup.self,
            IdolMember.self,
            ChekiMemo.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        modelContainer = try ModelContainer(for: schema, configurations: [config])
        modelContext = modelContainer.mainContext
    }

    override func tearDownWithError() throws {
        modelContainer = nil
        modelContext = nil
    }

    private func makeTestImageData(color: UIColor = .white) -> Data {
        let size = CGSize(width: 20, height: 20)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.8) ?? Data()
    }

    private func makeStagingPhoto(
        assetID: String,
        seq: Int = 1,
        format: FilmFormat = .mini,
        ocrDate: Date? = nil,
        shutterDate: Date = Date(),
        isReverted: Bool = false,
        cornersJSON: String? = "[[0.0,0.0],[1.0,0.0],[1.0,1.0],[0.0,1.0]]",
        hasManuallyModifiedDate: Bool = false
    ) -> StagingChekiPhoto {
        let data = makeTestImageData()
        let uiImage = UIImage(data: data) ?? UIImage()
        let croppedData = isReverted ? nil : data
        return StagingChekiPhoto(
            id: UUID(),
            sequenceNumber: seq,
            title: "Photo #\(seq)",
            assetIdentifier: assetID,
            imageData: data,
            uiImage: uiImage,
            detectedSide: .likelyFront,
            detectionNote: "Test",
            croppedImageData: croppedData,
            croppedUIImage: uiImage,
            normalizedCornersJSON: isReverted ? nil : cornersJSON,
            detectedOCRDate: ocrDate,
            hasManuallyModifiedDate: hasManuallyModifiedDate,
            resolvedFilmFormat: format,
            isRevertedToOriginal: isReverted,
            shutterDate: shutterDate
        )
    }

    func testCommitCreatesNewGroupMemberAndChekiEntities() throws {
        let testShutterDate = Date(timeIntervalSince1970: 1700000000)
        let testOCRDate = Date(timeIntervalSince1970: 1650000000)

        let frontPhoto = makeStagingPhoto(
            assetID: "asset-front-1",
            seq: 1,
            format: .square,
            ocrDate: testOCRDate,
            shutterDate: testShutterDate
        )
        let backPhoto = makeStagingPhoto(
            assetID: "asset-back-1",
            seq: 2,
            format: .square,
            shutterDate: testShutterDate
        )

        let pairedSlot = ChekiPairingSlot(id: UUID(), frontPhoto: frontPhoto, backPhoto: backPhoto)
        let singleSlot = ChekiPairingSlot(
            id: UUID(),
            frontPhoto: makeStagingPhoto(assetID: "asset-front-2", seq: 3, format: .wide),
            backPhoto: nil
        )

        let card = StagingMemberAlbumCard(
            id: "card-1",
            memberName: "金村美玖",
            groupName: "日向坂46",
            slots: [pairedSlot, singleSlot]
        )

        let result = try AlbumImportCommitEngine.commit(cards: [card], in: modelContext)

        XCTAssertEqual(result.createdGroupCount, 1)
        XCTAssertEqual(result.mergedGroupCount, 0)
        XCTAssertEqual(result.createdMemberCount, 1)
        XCTAssertEqual(result.mergedMemberCount, 0)
        XCTAssertEqual(result.importedChekiCount, 2)
        XCTAssertEqual(result.importedPairedCount, 1)
        XCTAssertEqual(result.skippedDuplicateCount, 0)
        XCTAssertFalse(result.localizedSummaryMessage.isEmpty)

        let groups = try modelContext.fetch(FetchDescriptor<IdolGroup>())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "日向坂46")

        let members = try modelContext.fetch(FetchDescriptor<IdolMember>())
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].stageName, "金村美玖")
        XCTAssertEqual(members[0].group?.id, groups[0].id)

        let items = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(items.count, 2)

        let pairedItem = try XCTUnwrap(items.first(where: { $0.frontAssetIdentifier == "asset-front-1" }))
        XCTAssertEqual(pairedItem.backAssetIdentifier, "asset-back-1")
        XCTAssertEqual(pairedItem.filmFormat, .square)
        XCTAssertEqual(pairedItem.originalCapturedAt, testShutterDate)
        XCTAssertNotNil(pairedItem.ocrDate)
        XCTAssertEqual(pairedItem.idolMember?.id, members[0].id)
        XCTAssertEqual(pairedItem.assignedMemberIDs, [members[0].id])
    }

    func testCommitMergesWithExistingGroupAndPromotesUngroupedMember() throws {
        let existingGroup = IdolGroup(name: "日向坂46", sortOrder: 0)
        modelContext.insert(existingGroup)

        let ungroupedMember = IdolMember(stageName: "小坂菜緒", sortOrder: 0, group: nil)
        modelContext.insert(ungroupedMember)
        try modelContext.save()

        let photo = makeStagingPhoto(assetID: "asset-kosaka-1", seq: 1)
        let slot = ChekiPairingSlot(id: UUID(), frontPhoto: photo, backPhoto: nil)

        let card = StagingMemberAlbumCard(
            id: "card-kosaka",
            memberName: " 小坂菜緒 ",
            groupName: "日向坂４６",
            slots: [slot]
        )

        let result = try AlbumImportCommitEngine.commit(cards: [card], in: modelContext)

        XCTAssertEqual(result.createdGroupCount, 0)
        XCTAssertEqual(result.mergedGroupCount, 1)
        XCTAssertEqual(result.createdMemberCount, 0)
        XCTAssertEqual(result.mergedMemberCount, 1)
        XCTAssertEqual(result.importedChekiCount, 1)

        let groups = try modelContext.fetch(FetchDescriptor<IdolGroup>())
        XCTAssertEqual(groups.count, 1)

        let members = try modelContext.fetch(FetchDescriptor<IdolMember>())
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].group?.id, existingGroup.id)
    }

    func testCommitSkipsDuplicateAssetIdentifiersAcrossDatabaseAndBatch() throws {
        let existingItem = ChekiItem(
            frontAssetIdentifier: "asset-already-imported",
            backAssetIdentifier: "asset-back-already-imported"
        )
        modelContext.insert(existingItem)
        try modelContext.save()

        let duplicateSlot1 = ChekiPairingSlot(
            id: UUID(),
            frontPhoto: makeStagingPhoto(assetID: "asset-already-imported", seq: 1),
            backPhoto: nil
        )

        let validSlot = ChekiPairingSlot(
            id: UUID(),
            frontPhoto: makeStagingPhoto(assetID: "asset-brand-new", seq: 2),
            backPhoto: nil
        )

        let duplicateSlot2 = ChekiPairingSlot(
            id: UUID(),
            frontPhoto: makeStagingPhoto(assetID: "asset-brand-new", seq: 3),
            backPhoto: nil
        )

        let card = StagingMemberAlbumCard(
            id: "card-dup",
            memberName: "齊藤京子",
            slots: [duplicateSlot1, validSlot, duplicateSlot2],
            skippedDuplicateCount: 2
        )

        let result = try AlbumImportCommitEngine.commit(cards: [card], in: modelContext)

        XCTAssertEqual(result.skippedDuplicateCount, 4)
        XCTAssertEqual(result.importedChekiCount, 1)
    }

    func testCommitIsIdempotent() throws {
        let photo1 = makeStagingPhoto(assetID: "asset-idemp-1", seq: 1)
        let slot1 = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)

        let card = StagingMemberAlbumCard(
            id: "card-idemp",
            memberName: "佐々木美玲",
            groupName: "日向坂46",
            slots: [slot1]
        )

        let firstResult = try AlbumImportCommitEngine.commit(cards: [card], in: modelContext)
        XCTAssertEqual(firstResult.importedChekiCount, 1)
        XCTAssertEqual(firstResult.createdGroupCount, 1)
        XCTAssertEqual(firstResult.createdMemberCount, 1)

        let secondResult = try AlbumImportCommitEngine.commit(cards: [card], in: modelContext)
        XCTAssertEqual(secondResult.importedChekiCount, 0)
        XCTAssertEqual(secondResult.createdGroupCount, 0)
        XCTAssertEqual(secondResult.createdMemberCount, 0)
        XCTAssertEqual(secondResult.mergedGroupCount, 1)
        XCTAssertEqual(secondResult.mergedMemberCount, 1)
        XCTAssertEqual(secondResult.skippedDuplicateCount, 1)

        let groups = try modelContext.fetch(FetchDescriptor<IdolGroup>())
        XCTAssertEqual(groups.count, 1)
        let members = try modelContext.fetch(FetchDescriptor<IdolMember>())
        XCTAssertEqual(members.count, 1)
        let items = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(items.count, 1)
    }

    func testPreCroppedPhotoPreservation() throws {
        let originalData = makeTestImageData(color: .red)
        let originalUI = UIImage(data: originalData) ?? UIImage()

        let photo = StagingChekiPhoto(
            id: UUID(),
            sequenceNumber: 1,
            title: "Original Photo",
            assetIdentifier: "asset-pre-cropped",
            imageData: originalData,
            uiImage: originalUI,
            detectedSide: .likelyFront,
            detectionNote: "Original",
            croppedImageData: nil,
            croppedUIImage: nil,
            normalizedCornersJSON: nil,
            detectedOCRDate: Date(timeIntervalSince1970: 1600000000),
            hasManuallyModifiedDate: false,
            resolvedFilmFormat: .wide,
            isRevertedToOriginal: true
        )

        let slot = ChekiPairingSlot(id: UUID(), frontPhoto: photo, backPhoto: nil)
        let card = StagingMemberAlbumCard(id: "card-pre", memberName: "高本彩花", slots: [slot])

        let result = try AlbumImportCommitEngine.commit(cards: [card], in: modelContext)
        XCTAssertEqual(result.importedChekiCount, 1)

        let items = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        let item = try XCTUnwrap(items.first(where: { $0.frontAssetIdentifier == "asset-pre-cropped" }))

        XCTAssertEqual(item.frontImageData, originalData)
        XCTAssertNil(item.perspectivePointsJSON)
        XCTAssertEqual(item.filmFormat, .wide)
        XCTAssertEqual(item.detectionMethod, .pending)
        XCTAssertNotNil(item.ocrDate)
    }
}
