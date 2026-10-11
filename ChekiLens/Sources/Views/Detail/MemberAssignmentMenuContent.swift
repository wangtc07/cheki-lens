import SwiftUI
import SwiftData
import PhotosUI
import UIKit

// MARK: - MemberHierarchyMenuContent (全 App 共用：單欄雙層階層式多選成員選單)

/// 全 App 共用的「團體 ➔ 成員」階層式多選選單內容（與導入時 BatchPairingView 介面完全一致，不分左右欄）
/// - 點選成員時透過 `.menuActionDismissBehavior(.disabled)` 保持選單開啟，方便連續勾選多位成員；點擊選單外部才關閉。
struct MemberHierarchyMenuContent: View {
    let selectedMemberIDs: Set<UUID>
    var showsUncategorizedOption: Bool = true
    var uncategorizedTitle: String = L10n.tr("未分類", "未分類")
    var uncategorizedIcon: String = "tray"
    var isUncategorizedDestructive: Bool = false
    let onToggleMember: (IdolMember) -> Void
    let onClearSelection: () -> Void
    var onCreateMember: (() -> Void)? = nil

    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    var body: some View {
        let validMembers = idolMembers.filter { !$0.isDeleted && $0.modelContext != nil }
        let ungroupedMembers = validMembers.filter { $0.group == nil }

        Section(L10n.tr("成員", "メンバー")) {
            ForEach(idolGroups) { group in
                let groupMembers = validMembers.filter { $0.group?.id == group.id }
                if !groupMembers.isEmpty {
                    Menu {
                        ForEach(groupMembers) { member in
                            memberButton(member, isSelected: selectedMemberIDs.contains(member.id))
                        }
                    } label: {
                        let selectedInGroup = groupMembers.filter { selectedMemberIDs.contains($0.id) }.count
                        if selectedInGroup > 0 {
                            Label("\(group.name) · \(selectedInGroup)", systemImage: "checkmark.circle.fill")
                        } else {
                            Text(group.name)
                        }
                    }
                    .menuActionDismissBehavior(.disabled)
                }
            }

            if !ungroupedMembers.isEmpty {
                Menu {
                    ForEach(ungroupedMembers) { member in
                        memberButton(member, isSelected: selectedMemberIDs.contains(member.id))
                    }
                } label: {
                    let selectedUngrouped = ungroupedMembers.filter { selectedMemberIDs.contains($0.id) }.count
                    if selectedUngrouped > 0 {
                        Label(
                            "\(L10n.tr("未分團", "未所属")) · \(selectedUngrouped)",
                            systemImage: "checkmark.circle.fill"
                        )
                    } else {
                        Text(L10n.tr("未分團", "未所属"))
                    }
                }
                .menuActionDismissBehavior(.disabled)
            }
        }

        if showsUncategorizedOption {
            Divider()

            Button(role: isUncategorizedDestructive ? .destructive : nil) {
                onClearSelection()
            } label: {
                Label(
                    uncategorizedTitle,
                    systemImage: (selectedMemberIDs.isEmpty && !isUncategorizedDestructive) ? "checkmark" : uncategorizedIcon
                )
            }
            .menuActionDismissBehavior(.disabled)
        }

        if let onCreateMember {
            Divider()

            Button {
                onCreateMember()
            } label: {
                Label(L10n.tr("成員", "メンバー"), systemImage: "person.badge.plus")
            }
            .menuActionDismissBehavior(.enabled)
        }
    }

    private func memberButton(_ member: IdolMember, isSelected: Bool) -> some View {
        Button {
            onToggleMember(member)
        } label: {
            Label(member.stageName, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
        }
        .menuActionDismissBehavior(.disabled)
    }
}

// MARK: - MemberAssignmentMenuContent

/// 拍照／匯入後再修改單張 `ChekiItem` 歸檔成員時使用的多層多選選單內容（共用 `MemberHierarchyMenuContent`）
struct MemberAssignmentMenuContent: View {
    let item: ChekiItem
    let onCreateMember: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    var body: some View {
        let validMembers = idolMembers.filter { !$0.isDeleted && $0.modelContext != nil }
        let isItemValid = !item.isDeleted && item.modelContext != nil
        let assignedIDs = isItemValid ? Set(item.assignedMemberIDs) : Set<UUID>()

        MemberHierarchyMenuContent(
            selectedMemberIDs: assignedIDs,
            showsUncategorizedOption: true,
            uncategorizedTitle: L10n.tr("未分類", "未分類"),
            uncategorizedIcon: "tray",
            isUncategorizedDestructive: false,
            onToggleMember: { member in
                toggle(member, validMembers: validMembers)
            },
            onClearSelection: {
                clearMembers()
            },
            onCreateMember: onCreateMember
        )
    }

    private func toggle(_ member: IdolMember, validMembers: [IdolMember]) {
        guard !item.isDeleted, item.modelContext != nil else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        item.toggleAssignedMember(member, allMembers: validMembers)
        try? modelContext.save()
        syncToPhotosIfNeeded()
    }

    private func clearMembers() {
        guard !item.isDeleted, item.modelContext != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        item.setAssignedMembers([])
        try? modelContext.save()
        syncToPhotosIfNeeded()
    }

    private func syncToPhotosIfNeeded() {
        let autoSync = UserDefaults.standard.object(forKey: "autoSyncToPhotosLibrary") as? Bool ?? true
        if autoSync {
            let target = item
            Task { @MainActor in
                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                    [target],
                    modelContext: modelContext,
                    onlyAlbumAndDateIfAlreadySynced: false
                )
            }
        }
    }
}

// MARK: - ChekiBacksideAssignmentMenu (照片長按與選單共用：選擇背面／背面設定子選單)

/// 照片長按選單 (`contextMenu`) 共用的「選擇背面」子選單：
/// - 支援從「App 內照片」挑選既有拍立得作為背面、從「系統相簿」匯入自動裁切作為背面；
/// - 若該拍立得已有正反雙面，同步提供「正反對調」與「移除背面」。
struct ChekiBacksideAssignmentMenu: View {
    let item: ChekiItem
    let onSelectInAppPhoto: () -> Void
    let onSelectSystemPhoto: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Menu {
            Button {
                onSelectInAppPhoto()
            } label: {
                Label(
                    L10n.tr("App 內照片", "アプリ内の写真"),
                    systemImage: "square.grid.2x2"
                )
            }

            Button {
                onSelectSystemPhoto()
            } label: {
                Label(
                    L10n.tr("系統相簿", "写真アプリ"),
                    systemImage: "photo.badge.plus"
                )
            }

            if item.hasBothSides {
                Divider()

                Button {
                    ChekiBacksideActionHelper.swapSides(for: item, modelContext: modelContext)
                } label: {
                    Label(L10n.tr("正反對調", "表裏を入れ替え"), systemImage: "arrow.left.arrow.right")
                }

                Button {
                    PhotoLibraryManager.shared.detachBackside(
                        from: item,
                        modelContext: modelContext
                    )
                } label: {
                    Label(L10n.tr("取消背面", "裏面を解除"), systemImage: "rectangle.on.rectangle.slash")
                }

                Button(role: .destructive) {
                    PhotoLibraryManager.shared.removeBackside(
                        from: item,
                        modelContext: modelContext
                    )
                } label: {
                    Label(L10n.tr("背面", "裏面"), systemImage: "trash")
                }
            }
        } label: {
            Label(
                L10n.tr("選擇背面", "裏面を選択"),
                systemImage: "rectangle.portrait.on.rectangle.portrait"
            )
        }
    }
}

// MARK: - ChekiBacksideActionHelper (共用的背面綁定、自動裁切與正反對調邏輯)

enum ChekiBacksideActionHelper {
    @MainActor
    static func swapSides(for target: ChekiItem, modelContext: ModelContext) {
        guard !target.isDeleted, target.modelContext != nil,
              let backData = target.backImageData else { return }
        let frontData = target.frontImageData
        let origFront = target.originalFrontImageData
        let origBack = target.originalBackImageData
        let frontPts = target.perspectivePointsJSON
        let backPts = target.backPerspectivePointsJSON
        let frontAsset = target.frontAssetIdentifier
        let backAsset = target.backAssetIdentifier

        target.frontImageData = backData
        target.backImageData = frontData
        target.originalFrontImageData = origBack
        target.originalBackImageData = origFront
        target.perspectivePointsJSON = backPts
        target.backPerspectivePointsJSON = frontPts
        target.frontAssetIdentifier = backAsset
        target.backAssetIdentifier = frontAsset

        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    static func attachBacksideFromInAppItem(
        _ sourceItem: ChekiItem,
        to target: ChekiItem,
        mergeAndRemoveSource: Bool,
        modelContext: ModelContext
    ) {
        guard !target.isDeleted, target.modelContext != nil,
              !sourceItem.isDeleted, sourceItem.modelContext != nil,
              sourceItem.id != target.id,
              let sourceImageData = sourceItem.frontImageData else { return }

        target.backImageData = sourceImageData
        target.originalBackImageData = sourceItem.originalFrontImageData ?? sourceImageData
        target.backPerspectivePointsJSON = sourceItem.perspectivePointsJSON
        target.backAssetIdentifier = sourceItem.frontAssetIdentifier

        if mergeAndRemoveSource {
            if let sourceBackData = sourceItem.backImageData {
                sourceItem.frontImageData = sourceBackData
                sourceItem.originalFrontImageData = sourceItem.originalBackImageData ?? sourceBackData
                sourceItem.perspectivePointsJSON = sourceItem.backPerspectivePointsJSON
                sourceItem.frontAssetIdentifier = sourceItem.backAssetIdentifier
                sourceItem.backImageData = nil
                sourceItem.originalBackImageData = nil
                sourceItem.backPerspectivePointsJSON = nil
                sourceItem.backAssetIdentifier = nil
            } else {
                modelContext.delete(sourceItem)
            }
        }

        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if UserDefaults.standard.bool(forKey: "autoSyncToPhotosLibrary") {
            Task { @MainActor in
                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                    [target],
                    modelContext: modelContext,
                    onlyAlbumAndDateIfAlreadySynced: false
                )
            }
        }
    }

    @MainActor
    static func attachBacksidePhoto(
        from pickerItem: PhotosPickerItem,
        to target: ChekiItem,
        modelContext: ModelContext
    ) async {
        guard !target.isDeleted, target.modelContext != nil,
              let data = try? await pickerItem.loadTransferable(type: Data.self),
              let rawImage = UIImage(data: data) else { return }

        let normalized = rawImage.normalizedImage
        let rawJPEG = normalized.jpegData(compressionQuality: 0.92) ?? data
        var finalData = rawJPEG
        var encodedCorners: String? = nil

        if let cgImage = normalized.cgImage {
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let visionManager = VisionManager()
            let defaultInsetRatio = UserDefaults.standard.double(forKey: "defaultBorderInsetPercentage") / 100.0
            if let detection = try? await visionManager.detectQuad(in: cgImage, imageSize: size) {
                let adjustedCorners = await visionManager.applyBorderInset(
                    corners: detection.corners,
                    imageSize: size,
                    ratio: defaultInsetRatio
                )
                if let cropResult = try? await visionManager.perspectiveCorrect(
                    image: cgImage,
                    corners: adjustedCorners,
                    detection: detection,
                    format: .auto
                ),
                let croppedJPEG = UIImage(cgImage: cropResult.cgImage).jpegData(compressionQuality: 0.92) {
                    finalData = croppedJPEG
                    encodedCorners = ChekiItem.encodeNormalizedCorners(adjustedCorners, imageSize: size)
                }
            }
        }

        guard !target.isDeleted, target.modelContext != nil else { return }
        target.originalBackImageData = rawJPEG
        target.backPerspectivePointsJSON = encodedCorners
        target.backImageData = finalData
        target.backAssetIdentifier = pickerItem.itemIdentifier
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if UserDefaults.standard.bool(forKey: "autoSyncToPhotosLibrary") {
            Task { @MainActor in
                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                    [target],
                    modelContext: modelContext,
                    onlyAlbumAndDateIfAlreadySynced: false
                )
            }
        }
    }
}

// MARK: - ChekiBacksidePickerModalsModifier (掛載「App 內選擇背面 Sheet」與「系統相簿選擇背面 PhotosPicker」)

private struct ChekiBacksidePickerModalsModifier: ViewModifier {
    @Binding var inAppTargetItem: ChekiItem?
    @Binding var photosTargetItem: ChekiItem?
    @Binding var isShowingPhotosPicker: Bool

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var allChekiItems: [ChekiItem]
    @State private var selectedBacksidePickerItem: PhotosPickerItem? = nil

    func body(content: Content) -> some View {
        let validItems = allChekiItems
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted { $0.displayDate > $1.displayDate }

        content
            .sheet(item: $inAppTargetItem) { target in
                InAppBacksidePickerSheet(
                    targetItem: target,
                    candidates: validItems.filter { $0.id != target.id }
                ) { sourceItem, mergeAndRemoveSource in
                    ChekiBacksideActionHelper.attachBacksideFromInAppItem(
                        sourceItem,
                        to: target,
                        mergeAndRemoveSource: mergeAndRemoveSource,
                        modelContext: modelContext
                    )
                }
            }
            .photosPicker(
                isPresented: $isShowingPhotosPicker,
                selection: $selectedBacksidePickerItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedBacksidePickerItem) { _, newPickerItem in
                guard let newPickerItem else { return }
                let target = photosTargetItem
                selectedBacksidePickerItem = nil
                photosTargetItem = nil
                guard let target else { return }
                Task { @MainActor in
                    await ChekiBacksideActionHelper.attachBacksidePhoto(
                        from: newPickerItem,
                        to: target,
                        modelContext: modelContext
                    )
                }
            }
    }
}

extension View {
    func chekiBacksidePickerModals(
        inAppTargetItem: Binding<ChekiItem?>,
        photosTargetItem: Binding<ChekiItem?>,
        isShowingPhotosPicker: Binding<Bool>
    ) -> some View {
        modifier(
            ChekiBacksidePickerModalsModifier(
                inAppTargetItem: inAppTargetItem,
                photosTargetItem: photosTargetItem,
                isShowingPhotosPicker: isShowingPhotosPicker
            )
        )
    }
}

