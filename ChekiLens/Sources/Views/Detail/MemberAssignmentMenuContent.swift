import SwiftUI
import SwiftData
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
