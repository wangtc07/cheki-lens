import SwiftUI
import SwiftData

// MARK: - MemberAssignmentMenuContent

/// 拍照／匯入後再修改歸檔成員時使用的多層選單內容（團體 ➔ 成員，最後可新增成員），
/// 與批次匯入工作台 (`BatchPairingView`) 的成員選單一致。
/// 需放置於 `Menu { ... }` 內；新增成員的 Sheet 由呼叫端透過 `onCreateMember` 自行呈現。
struct MemberAssignmentMenuContent: View {
    let item: ChekiItem
    let onCreateMember: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    var body: some View {
        let ungroupedMembers = idolMembers.filter { $0.group == nil }
        let currentID: UUID? = (!item.isDeleted && item.modelContext != nil) ? item.idolMember?.id : nil

        Section("選擇成員") {
            ForEach(idolGroups) { group in
                let groupMembers = idolMembers.filter { $0.group?.id == group.id }
                if !groupMembers.isEmpty {
                    Menu(group.name) {
                        ForEach(groupMembers) { member in
                            memberButton(member, isCurrent: currentID == member.id)
                        }
                    }
                }
            }

            if !ungroupedMembers.isEmpty {
                Menu("未分團成員") {
                    ForEach(ungroupedMembers) { member in
                        memberButton(member, isCurrent: currentID == member.id)
                    }
                }
            }
        }

        Divider()

        Button {
            assign(nil)
        } label: {
            Label("設為「未分類」", systemImage: currentID == nil ? "checkmark" : "tray")
        }

        Divider()

        Button {
            onCreateMember()
        } label: {
            Label("新增成員…", systemImage: "person.badge.plus")
        }
    }

    private func memberButton(_ member: IdolMember, isCurrent: Bool) -> some View {
        Button {
            assign(member)
        } label: {
            Label(member.stageName, systemImage: isCurrent ? "checkmark.circle.fill" : "person")
        }
    }

    private func assign(_ member: IdolMember?) {
        guard !item.isDeleted, item.modelContext != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        item.idolMember = member
        try? modelContext.save()
        let autoSync = UserDefaults.standard.object(forKey: "autoSyncToPhotosLibrary") as? Bool ?? true
        if autoSync {
            let target = item
            Task { @MainActor in
                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                    [target],
                    modelContext: modelContext
                )
            }
        }
    }
}
