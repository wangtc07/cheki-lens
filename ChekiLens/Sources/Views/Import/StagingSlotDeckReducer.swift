import Foundation
import SwiftUI
import UIKit

struct StagingSlotDeckReducer {

    static func extractOrderedPhotos(from slots: [ChekiPairingSlot]) -> [StagingChekiPhoto] {
        var photos: [StagingChekiPhoto] = []
        for slot in slots {
            photos.append(slot.frontPhoto)
            if let back = slot.backPhoto {
                photos.append(back)
            }
        }
        return photos
    }

    static func pairSlots(
        frontSlotID: UUID,
        backSlotID: UUID,
        in slots: [ChekiPairingSlot]
    ) -> [ChekiPairingSlot] {
        guard frontSlotID != backSlotID else { return slots }
        guard let frontIndex = slots.firstIndex(where: { $0.id == frontSlotID }),
              let backIndex = slots.firstIndex(where: { $0.id == backSlotID }) else {
            return slots
        }
        guard !slots[frontIndex].isPaired && !slots[backIndex].isPaired else {
            return slots
        }

        let frontPhoto = slots[frontIndex].frontPhoto
        let backPhoto = slots[backIndex].frontPhoto
        let assignedMembers = !slots[frontIndex].assignedMembers.isEmpty
            ? slots[frontIndex].assignedMembers
            : slots[backIndex].assignedMembers

        let combinedSlot = ChekiPairingSlot(
            id: UUID(),
            frontPhoto: frontPhoto,
            backPhoto: backPhoto,
            assignedMembers: assignedMembers
        )

        var newSlots = slots
        if frontIndex < backIndex {
            newSlots.remove(at: backIndex)
            newSlots[frontIndex] = combinedSlot
        } else {
            newSlots.remove(at: backIndex)
            newSlots[frontIndex - 1] = combinedSlot
        }
        return newSlots
    }

    static func unpairSlot(
        slotID: UUID,
        in slots: [ChekiPairingSlot],
        photoMemberAssignment: [UUID: [IdolMember]] = [:]
    ) -> [ChekiPairingSlot] {
        guard let index = slots.firstIndex(where: { $0.id == slotID }),
              let backPhoto = slots[index].backPhoto else {
            return slots
        }

        let frontPhoto = slots[index].frontPhoto
        let currentMembers = slots[index].assignedMembers
        let backMembers = photoMemberAssignment[backPhoto.id] ?? currentMembers

        let slotA = ChekiPairingSlot(
            id: UUID(),
            frontPhoto: frontPhoto,
            backPhoto: nil,
            assignedMembers: currentMembers
        )
        let slotB = ChekiPairingSlot(
            id: UUID(),
            frontPhoto: backPhoto,
            backPhoto: nil,
            assignedMembers: backMembers
        )

        var newSlots = slots
        newSlots.replaceSubrange(index...index, with: [slotA, slotB])
        return newSlots
    }

    static func swapSlotSides(
        slotID: UUID,
        in slots: [ChekiPairingSlot]
    ) -> [ChekiPairingSlot] {
        guard let index = slots.firstIndex(where: { $0.id == slotID }),
              let backPhoto = slots[index].backPhoto else {
            return slots
        }

        var newSlots = slots
        let oldFront = newSlots[index].frontPhoto
        newSlots[index].frontPhoto = backPhoto
        newSlots[index].backPhoto = oldFront
        return newSlots
    }

    static func removeSlot(
        slotID: UUID,
        in slots: [ChekiPairingSlot]
    ) -> [ChekiPairingSlot] {
        slots.filter { $0.id != slotID }
    }

    static func updateSlotFormat(
        slotID: UUID,
        format: FilmFormat,
        in slots: [ChekiPairingSlot]
    ) -> [ChekiPairingSlot] {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else {
            return slots
        }
        var newSlots = slots
        let concrete = format.concreteFormat
        newSlots[index].frontPhoto.resolvedFilmFormat = concrete
        newSlots[index].frontPhoto.hasManuallyModifiedFormat = true
        if var back = newSlots[index].backPhoto {
            back.resolvedFilmFormat = concrete
            back.hasManuallyModifiedFormat = true
            newSlots[index].backPhoto = back
        }
        return newSlots
    }

    static func updateSlotDate(
        slotID: UUID,
        date: Date?,
        in slots: [ChekiPairingSlot]
    ) -> [ChekiPairingSlot] {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else {
            return slots
        }
        var newSlots = slots
        newSlots[index].frontPhoto.detectedOCRDate = date
        newSlots[index].frontPhoto.hasManuallyModifiedDate = true
        if var back = newSlots[index].backPhoto {
            back.detectedOCRDate = date
            back.hasManuallyModifiedDate = true
            newSlots[index].backPhoto = back
        }
        return newSlots
    }
}
