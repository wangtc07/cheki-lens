import XCTest
import SwiftData
import UIKit
@testable import ChekiLens

@MainActor
final class StagingSlotDeckReducerTests: XCTestCase {

    private func makeTestPhoto(id: UUID = UUID(), seq: Int) -> StagingChekiPhoto {
        let size = CGSize(width: 10, height: 10)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let data = img.jpegData(compressionQuality: 0.8) ?? Data()
        return StagingChekiPhoto(
            id: id,
            sequenceNumber: seq,
            title: "Photo #\(seq)",
            imageData: data,
            uiImage: img,
            detectedSide: .likelyFront,
            detectionNote: "Test"
        )
    }

    func testExtractOrderedPhotos_EmptySlots_ReturnsEmpty() {
        let result = StagingSlotDeckReducer.extractOrderedPhotos(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testExtractOrderedPhotos_SingleAndPairedSlots_ReturnsPreservedOrder() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)
        let photo3 = makeTestPhoto(seq: 3)

        let slot1 = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)
        let slot2 = ChekiPairingSlot(id: UUID(), frontPhoto: photo2, backPhoto: photo3)

        let result = StagingSlotDeckReducer.extractOrderedPhotos(from: [slot1, slot2])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.sequenceNumber), [1, 2, 3])
    }

    func testPairSlots_CombinesTwoSingleSlots_AscendingOrder() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)
        let photo3 = makeTestPhoto(seq: 3)

        let slot1 = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)
        let slot2 = ChekiPairingSlot(id: UUID(), frontPhoto: photo2, backPhoto: nil)
        let slot3 = ChekiPairingSlot(id: UUID(), frontPhoto: photo3, backPhoto: nil)

        let initial = [slot1, slot2, slot3]
        let paired = StagingSlotDeckReducer.pairSlots(frontSlotID: slot1.id, backSlotID: slot2.id, in: initial)

        XCTAssertEqual(paired.count, 2)
        XCTAssertTrue(paired[0].isPaired)
        XCTAssertEqual(paired[0].frontPhoto.id, photo1.id)
        XCTAssertEqual(paired[0].backPhoto?.id, photo2.id)
        XCTAssertEqual(paired[1].id, slot3.id)
    }

    func testPairSlots_CombinesTwoSingleSlots_DescendingOrder() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)
        let photo3 = makeTestPhoto(seq: 3)

        let slot1 = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)
        let slot2 = ChekiPairingSlot(id: UUID(), frontPhoto: photo2, backPhoto: nil)
        let slot3 = ChekiPairingSlot(id: UUID(), frontPhoto: photo3, backPhoto: nil)

        let initial = [slot1, slot2, slot3]
        let paired = StagingSlotDeckReducer.pairSlots(frontSlotID: slot3.id, backSlotID: slot1.id, in: initial)

        XCTAssertEqual(paired.count, 2)
        XCTAssertEqual(paired[0].id, slot2.id)
        XCTAssertTrue(paired[1].isPaired)
        XCTAssertEqual(paired[1].frontPhoto.id, photo3.id)
        XCTAssertEqual(paired[1].backPhoto?.id, photo1.id)
    }

    func testPairSlots_NoOpGuards() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)
        let photo3 = makeTestPhoto(seq: 3)

        let slot1 = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)
        let slot2 = ChekiPairingSlot(id: UUID(), frontPhoto: photo2, backPhoto: photo3)

        let initial = [slot1, slot2]

        let sameID = StagingSlotDeckReducer.pairSlots(frontSlotID: slot1.id, backSlotID: slot1.id, in: initial)
        XCTAssertEqual(sameID, initial)

        let missingFront = StagingSlotDeckReducer.pairSlots(frontSlotID: UUID(), backSlotID: slot1.id, in: initial)
        XCTAssertEqual(missingFront, initial)

        let missingBack = StagingSlotDeckReducer.pairSlots(frontSlotID: slot1.id, backSlotID: UUID(), in: initial)
        XCTAssertEqual(missingBack, initial)

        let alreadyPairedBack = StagingSlotDeckReducer.pairSlots(frontSlotID: slot1.id, backSlotID: slot2.id, in: initial)
        XCTAssertEqual(alreadyPairedBack, initial)

        let alreadyPairedFront = StagingSlotDeckReducer.pairSlots(frontSlotID: slot2.id, backSlotID: slot1.id, in: initial)
        XCTAssertEqual(alreadyPairedFront, initial)
    }

    func testUnpairSlot_SplitsPairedIntoTwoSingleSlots() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)

        let pairedSlot = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: photo2)
        let slots = [pairedSlot]

        let unpaired = StagingSlotDeckReducer.unpairSlot(slotID: pairedSlot.id, in: slots)
        XCTAssertEqual(unpaired.count, 2)
        XCTAssertFalse(unpaired[0].isPaired)
        XCTAssertFalse(unpaired[1].isPaired)
        XCTAssertEqual(unpaired[0].frontPhoto.id, photo1.id)
        XCTAssertEqual(unpaired[1].frontPhoto.id, photo2.id)
    }

    func testUnpairSlot_NoOpWhenSingleSidedOrNotFound() {
        let photo1 = makeTestPhoto(seq: 1)
        let singleSlot = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)
        let slots = [singleSlot]

        let resultSingle = StagingSlotDeckReducer.unpairSlot(slotID: singleSlot.id, in: slots)
        XCTAssertEqual(resultSingle, slots)

        let resultNotFound = StagingSlotDeckReducer.unpairSlot(slotID: UUID(), in: slots)
        XCTAssertEqual(resultNotFound, slots)
    }

    func testSwapSlotSides_SwapsFrontAndBack() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)

        let pairedSlot = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: photo2)
        let slots = [pairedSlot]

        let swapped = StagingSlotDeckReducer.swapSlotSides(slotID: pairedSlot.id, in: slots)
        XCTAssertEqual(swapped.count, 1)
        XCTAssertEqual(swapped[0].frontPhoto.id, photo2.id)
        XCTAssertEqual(swapped[0].backPhoto?.id, photo1.id)
    }

    func testSwapSlotSides_NoOpWhenSingleSided() {
        let photo1 = makeTestPhoto(seq: 1)
        let singleSlot = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)
        let slots = [singleSlot]

        let swapped = StagingSlotDeckReducer.swapSlotSides(slotID: singleSlot.id, in: slots)
        XCTAssertEqual(swapped, slots)
    }

    func testRemoveSlot_RemovesTargetSlot() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)

        let slot1 = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)
        let slot2 = ChekiPairingSlot(id: UUID(), frontPhoto: photo2, backPhoto: nil)
        let slots = [slot1, slot2]

        let remaining = StagingSlotDeckReducer.removeSlot(slotID: slot1.id, in: slots)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, slot2.id)

        let nonExistent = StagingSlotDeckReducer.removeSlot(slotID: UUID(), in: slots)
        XCTAssertEqual(nonExistent, slots)
    }

    func testUpdateSlotFormat_UpdatesFrontAndBack() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)

        let pairedSlot = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: photo2)
        let slots = [pairedSlot]

        let updated = StagingSlotDeckReducer.updateSlotFormat(slotID: pairedSlot.id, format: .square, in: slots)
        XCTAssertEqual(updated[0].frontPhoto.resolvedFilmFormat, .square)
        XCTAssertTrue(updated[0].frontPhoto.hasManuallyModifiedFormat)
        XCTAssertEqual(updated[0].backPhoto?.resolvedFilmFormat, .square)
        XCTAssertTrue(updated[0].backPhoto?.hasManuallyModifiedFormat ?? false)
    }

    func testUpdateSlotDate_UpdatesFrontAndBackPhotoDate() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)
        let slot = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: photo2)
        let slots = [slot]

        let testDate = Date(timeIntervalSince1970: 1700000000)
        let updated = StagingSlotDeckReducer.updateSlotDate(slotID: slot.id, date: testDate, in: slots)
        XCTAssertEqual(updated[0].frontPhoto.detectedOCRDate, testDate)
        XCTAssertTrue(updated[0].frontPhoto.hasManuallyModifiedDate)
        XCTAssertEqual(updated[0].backPhoto?.detectedOCRDate, testDate)
        XCTAssertTrue(updated[0].backPhoto?.hasManuallyModifiedDate ?? false)
    }

    func testIntegration_StagingImportShelfState_UpdateCardSlots() {
        let photo1 = makeTestPhoto(seq: 1)
        let photo2 = makeTestPhoto(seq: 2)

        let slot1 = ChekiPairingSlot(id: UUID(), frontPhoto: photo1, backPhoto: nil)
        let slot2 = ChekiPairingSlot(id: UUID(), frontPhoto: photo2, backPhoto: nil)

        let album = SystemPhotoAlbumNode(
            id: "album-1",
            title: "金村美玖",
            assetIdentifiers: ["asset-1", "asset-2"]
        )

        var state = StagingImportShelfState(albums: [album])
        state.appendLoadedSlot(slot1, toCard: "album-1")
        state.appendLoadedSlot(slot2, toCard: "album-1")
        state.markCardCompleted("album-1")

        XCTAssertEqual(state.cards.first?.activeSlotCount, 2)
        XCTAssertEqual(state.cards.first?.pairedSlotCount, 0)

        let cardSlots = state.cards.first?.slots ?? []
        let pairedSlots = StagingSlotDeckReducer.pairSlots(frontSlotID: slot1.id, backSlotID: slot2.id, in: cardSlots)
        state.updateCardSlots("album-1", slots: pairedSlots)

        XCTAssertEqual(state.cards.first?.activeSlotCount, 1)
        XCTAssertEqual(state.cards.first?.pairedSlotCount, 1)
    }
}
