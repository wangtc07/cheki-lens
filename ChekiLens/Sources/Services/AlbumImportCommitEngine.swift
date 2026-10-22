import Foundation
import SwiftData
import UIKit

struct AlbumImportCommitResult: Equatable, Sendable {
    let createdGroupCount: Int
    let mergedGroupCount: Int
    let createdMemberCount: Int
    let mergedMemberCount: Int
    let importedChekiCount: Int
    let importedPairedCount: Int
    let skippedDuplicateCount: Int

    var totalGroupCount: Int {
        createdGroupCount + mergedGroupCount
    }

    var totalMemberCount: Int {
        createdMemberCount + mergedMemberCount
    }

    var localizedSummaryMessage: String {
        var parts: [String] = []

        if importedChekiCount > 0 {
            if importedPairedCount > 0 {
                parts.append(L10n.tr(
                    "已匯入 \(importedChekiCount) 張拍立得，含 \(importedPairedCount) 組雙面。",
                    "\(importedChekiCount)枚のチェキをインポートしました。うち \(importedPairedCount)組両面。"
                ))
            } else {
                parts.append(L10n.tr(
                    "已匯入 \(importedChekiCount) 張拍立得。",
                    "\(importedChekiCount)枚のチェキをインポートしました。"
                ))
            }
        } else {
            parts.append(L10n.tr(
                "未匯入任何新拍立得。",
                "新しいチェキはインポートされませんでした。"
            ))
        }

        if totalGroupCount > 0 {
            if createdGroupCount > 0 && mergedGroupCount > 0 {
                parts.append(L10n.tr(
                    "新建 \(createdGroupCount) 個團體，合併至 \(mergedGroupCount) 個既有團體。",
                    "新規グループ \(createdGroupCount)件、既存 \(mergedGroupCount)件に統合。"
                ))
            } else if createdGroupCount > 0 {
                parts.append(L10n.tr(
                    "新建 \(createdGroupCount) 個團體。",
                    "新規グループ \(createdGroupCount)件を作成しました。"
                ))
            } else {
                parts.append(L10n.tr(
                    "合併至 \(mergedGroupCount) 個既有團體。",
                    "既存の \(mergedGroupCount)件のグループに統合しました。"
                ))
            }
        }

        if totalMemberCount > 0 {
            if createdMemberCount > 0 && mergedMemberCount > 0 {
                parts.append(L10n.tr(
                    "新建 \(createdMemberCount) 位成員，合併至 \(mergedMemberCount) 位既有成員。",
                    "新規メンバー \(createdMemberCount)名、既存 \(mergedMemberCount)名に統合。"
                ))
            } else if createdMemberCount > 0 {
                parts.append(L10n.tr(
                    "新建 \(createdMemberCount) 位成員。",
                    "新規メンバー \(createdMemberCount)名を作成しました。"
                ))
            } else {
                parts.append(L10n.tr(
                    "合併至 \(mergedMemberCount) 位既有成員。",
                    "既存の \(mergedMemberCount)名のメンバーに統合しました。"
                ))
            }
        }

        if skippedDuplicateCount > 0 {
            parts.append(L10n.tr(
                "略過 \(skippedDuplicateCount) 張重複相片。",
                "\(skippedDuplicateCount)枚の重複した写真をスキップしました。"
            ))
        }

        return parts.joined(separator: " ")
    }
}

extension ChekiPairingSlot {
    var hasManuallyModifiedDate: Bool {
        frontPhoto.hasManuallyModifiedDate || (backPhoto?.hasManuallyModifiedDate ?? false)
    }
}

enum AlbumImportCommitEngine {

    @MainActor
    static func commit(
        cards: [StagingMemberAlbumCard],
        in modelContext: ModelContext,
        borderInsetRatio: Double = 0.0
    ) throws -> AlbumImportCommitResult {
        var existingGroups = try modelContext.fetch(FetchDescriptor<IdolGroup>())
        var existingMembers = try modelContext.fetch(FetchDescriptor<IdolMember>())
        let existingItems = try modelContext.fetch(FetchDescriptor<ChekiItem>())

        var knownAssetIDs = SystemAlbumExplorerService.collectExistingAssetIdentifiers(from: existingItems)

        var createdGroupCount = 0
        var mergedGroupCount = 0
        var createdMemberCount = 0
        var mergedMemberCount = 0
        var importedChekiCount = 0
        var importedPairedCount = 0
        var skippedDuplicateCount = 0

        var createdGroupKeys = Set<String>()
        var mergedGroupKeys = Set<String>()
        var createdMemberIDs = Set<UUID>()
        var mergedMemberIDs = Set<UUID>()

        for card in cards {
            skippedDuplicateCount += card.skippedDuplicateCount

            var targetGroup: IdolGroup? = nil
            let trimmedGroupName = (card.groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGroupName.isEmpty {
                let groupKey = SystemAlbumExplorerService.normalizedNameKey(trimmedGroupName)
                if let found = existingGroups.first(where: {
                    SystemAlbumExplorerService.namesMatch($0.name, trimmedGroupName)
                }) {
                    targetGroup = found
                    if !createdGroupKeys.contains(groupKey) && mergedGroupKeys.insert(groupKey).inserted {
                        mergedGroupCount += 1
                    }
                } else {
                    let nextGroupSortOrder = (existingGroups.map(\.sortOrder).max() ?? -1) + 1
                    let newGroup = IdolGroup(name: trimmedGroupName, sortOrder: nextGroupSortOrder)
                    modelContext.insert(newGroup)
                    existingGroups.append(newGroup)
                    targetGroup = newGroup
                    if createdGroupKeys.insert(groupKey).inserted {
                        createdGroupCount += 1
                    }
                }
            }

            let rawMemberName = card.memberName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedMemberName = rawMemberName.isEmpty ? L10n.tr("未命名成員", "未設定メンバー") : rawMemberName

            let resolvedMember: IdolMember
            if let group = targetGroup {
                if let existingInGroup = existingMembers.first(where: {
                    $0.group?.id == group.id && SystemAlbumExplorerService.namesMatch($0.stageName, trimmedMemberName)
                }) {
                    resolvedMember = existingInGroup
                    if !createdMemberIDs.contains(existingInGroup.id) && mergedMemberIDs.insert(existingInGroup.id).inserted {
                        mergedMemberCount += 1
                    }
                } else if let ungroupedMatch = existingMembers.first(where: {
                    $0.group == nil && SystemAlbumExplorerService.namesMatch($0.stageName, trimmedMemberName)
                }) {
                    ungroupedMatch.group = group
                    resolvedMember = ungroupedMatch
                    if !createdMemberIDs.contains(ungroupedMatch.id) && mergedMemberIDs.insert(ungroupedMatch.id).inserted {
                        mergedMemberCount += 1
                    }
                } else {
                    let nextMemberSortOrder = (existingMembers.filter { $0.group?.id == group.id }.map(\.sortOrder).max() ?? -1) + 1
                    let newMember = IdolMember(stageName: trimmedMemberName, sortOrder: nextMemberSortOrder, group: group)
                    modelContext.insert(newMember)
                    existingMembers.append(newMember)
                    resolvedMember = newMember
                    if createdMemberIDs.insert(newMember.id).inserted {
                        createdMemberCount += 1
                    }
                }
            } else {
                if let ungroupedMatch = existingMembers.first(where: {
                    $0.group == nil && SystemAlbumExplorerService.namesMatch($0.stageName, trimmedMemberName)
                }) {
                    resolvedMember = ungroupedMatch
                    if !createdMemberIDs.contains(ungroupedMatch.id) && mergedMemberIDs.insert(ungroupedMatch.id).inserted {
                        mergedMemberCount += 1
                    }
                } else if let anyMatch = existingMembers.first(where: {
                    SystemAlbumExplorerService.namesMatch($0.stageName, trimmedMemberName)
                }) {
                    resolvedMember = anyMatch
                    if !createdMemberIDs.contains(anyMatch.id) && mergedMemberIDs.insert(anyMatch.id).inserted {
                        mergedMemberCount += 1
                    }
                } else {
                    let nextMemberSortOrder = (existingMembers.filter { $0.group == nil }.map(\.sortOrder).max() ?? -1) + 1
                    let newMember = IdolMember(stageName: trimmedMemberName, sortOrder: nextMemberSortOrder, group: nil)
                    modelContext.insert(newMember)
                    existingMembers.append(newMember)
                    resolvedMember = newMember
                    if createdMemberIDs.insert(newMember.id).inserted {
                        createdMemberCount += 1
                    }
                }
            }

            for slot in card.slots {
                let frontID = slot.frontPhoto.assetIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
                let backID = slot.backPhoto?.assetIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)

                let hasFrontID = frontID != nil && !frontID!.isEmpty
                let hasBackID = backID != nil && !backID!.isEmpty

                let isFrontDuplicate = hasFrontID && knownAssetIDs.contains(frontID!)
                let isBackDuplicate = hasBackID && knownAssetIDs.contains(backID!)

                if isFrontDuplicate || isBackDuplicate {
                    skippedDuplicateCount += 1
                    continue
                }

                if let frontID, !frontID.isEmpty {
                    knownAssetIDs.insert(frontID)
                }
                if let backID, !backID.isEmpty {
                    knownAssetIDs.insert(backID)
                }

                let frontData: Data? = slot.frontPhoto.isRevertedToOriginal
                    ? slot.frontPhoto.imageData
                    : (slot.frontPhoto.croppedImageData ?? slot.frontPhoto.imageData)

                let backData: Data? = slot.backPhoto.map { back in
                    back.isRevertedToOriginal ? back.imageData : (back.croppedImageData ?? back.imageData)
                }

                let frontCornersJSON: String? = slot.frontPhoto.isRevertedToOriginal ? nil : slot.frontPhoto.normalizedCornersJSON
                let backCornersJSON: String? = (slot.backPhoto?.isRevertedToOriginal == true) ? nil : slot.backPhoto?.normalizedCornersJSON

                let detectionMethod: DetectionMethod = (slot.frontPhoto.isRevertedToOriginal || frontCornersJSON == nil)
                    ? .pending
                    : .visionNative

                let concreteFormat = slot.concreteFilmFormat

                let item = ChekiItem(
                    frontImageData: frontData,
                    backImageData: backData,
                    originalFrontImageData: slot.frontPhoto.imageData,
                    originalBackImageData: slot.backPhoto?.imageData,
                    capturedAt: slot.frontPhoto.shutterDate,
                    originalCapturedAt: slot.frontPhoto.shutterDate,
                    filmFormat: concreteFormat,
                    detectedAspectRatio: concreteFormat.aspectRatio,
                    borderInsetRatio: borderInsetRatio,
                    perspectivePointsJSON: frontCornersJSON,
                    backPerspectivePointsJSON: backCornersJSON,
                    detectionMethod: detectionMethod,
                    processingState: .completed,
                    frontAssetIdentifier: slot.frontPhoto.assetIdentifier,
                    backAssetIdentifier: slot.backPhoto?.assetIdentifier,
                    idolMember: resolvedMember,
                    assignedMembers: [resolvedMember]
                )

                if let recognizedDate = slot.effectiveOCRDate {
                    if slot.hasManuallyModifiedDate {
                        let merged = ChekiItem.mergeRecognizedDate(recognizedDate, into: slot.frontPhoto.shutterDate)
                        item.lockJudgedDate(merged)
                    } else {
                        item.applyAutomaticJudgedDate(recognizedDate, preservingTimeFrom: slot.frontPhoto.shutterDate)
                    }
                } else if slot.hasManuallyModifiedDate {
                    item.ocrDate = nil
                    item.isJudgedDateManuallySet = true
                }

                modelContext.insert(item)
                importedChekiCount += 1
                if slot.isPaired {
                    importedPairedCount += 1
                }
            }
        }

        try modelContext.save()

        return AlbumImportCommitResult(
            createdGroupCount: createdGroupCount,
            mergedGroupCount: mergedGroupCount,
            createdMemberCount: createdMemberCount,
            mergedMemberCount: mergedMemberCount,
            importedChekiCount: importedChekiCount,
            importedPairedCount: importedPairedCount,
            skippedDuplicateCount: skippedDuplicateCount
        )
    }
}
