import SwiftUI
import SwiftData
import UIKit

// MARK: - MemberAssignmentMenuContent

/// 拍照／匯入後再修改歸檔成員時使用的多層多選選單內容（團體 ➔ 成員，最後可新增成員），
/// 支援選取多位成員，且點選成員時不會自動關閉選單（點旁邊 Lose Focus 才關閉）。
struct MemberAssignmentMenuContent: View {
    let item: ChekiItem
    let onCreateMember: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    var body: some View {
        let validMembers = idolMembers.filter { !$0.isDeleted && $0.modelContext != nil }
        let ungroupedMembers = validMembers.filter { $0.group == nil }
        let isItemValid = !item.isDeleted && item.modelContext != nil
        let assignedIDs = isItemValid ? Set(item.assignedMemberIDs) : Set<UUID>()
        let isUncategorized = isItemValid ? item.isUncategorized : true

        Section(L10n.tr("成員", "メンバー")) {
            ForEach(idolGroups) { group in
                let groupMembers = validMembers.filter { $0.group?.id == group.id }
                if !groupMembers.isEmpty {
                    Menu {
                        ForEach(groupMembers) { member in
                            memberButton(member, isSelected: assignedIDs.contains(member.id), validMembers: validMembers)
                        }
                    } label: {
                        let selectedInGroup = groupMembers.filter { assignedIDs.contains($0.id) }.count
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
                        memberButton(member, isSelected: assignedIDs.contains(member.id), validMembers: validMembers)
                    }
                } label: {
                    let selectedUngrouped = ungroupedMembers.filter { assignedIDs.contains($0.id) }.count
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

        Divider()

        Button {
            clearMembers()
        } label: {
            Label(L10n.tr("未分類", "未分類"), systemImage: isUncategorized ? "checkmark" : "tray")
        }
        .menuActionDismissBehavior(.disabled)

        Divider()

        Button {
            onCreateMember()
        } label: {
            Label(L10n.tr("成員", "メンバー"), systemImage: "person.badge.plus")
        }
        .menuActionDismissBehavior(.enabled)
    }

    private func memberButton(_ member: IdolMember, isSelected: Bool, validMembers: [IdolMember]) -> some View {
        Button {
            toggle(member, validMembers: validMembers)
        } label: {
            Label(member.stageName, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
        }
        .menuActionDismissBehavior(.disabled)
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

// MARK: - MemberMultiSelectPopoverView (雙層多選浮動選單：左側團體 ➔ 右側成員，點選成員不自動關閉，點旁邊 Lose Focus 才關閉)

/// 雙層多選浮動選單（供拍照後修改成員、資訊面板、單張檢視、批次匯入與相冊篩選共用）
/// - 第一層（左欄）：團體列表（含未分團成員）
/// - 第二層（右欄）：所選團體旗下的成員清單（支援多選打勾，點擊成員絕不自動關閉選單，僅在點擊選單外部 Lose Focus 時關閉）
struct MemberMultiSelectPopoverView: View {
    enum Mode {
        case chekiItem(ChekiItem)
        case binding(Binding<[IdolMember]>, onChanged: (([IdolMember]) -> Void)?)
    }

    let mode: Mode
    let onCreateMember: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    private static let ungroupedCategoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    @State private var selectedGroupID: UUID? = nil

    init(item: ChekiItem, onCreateMember: @escaping () -> Void) {
        self.mode = .chekiItem(item)
        self.onCreateMember = onCreateMember
    }

    init(
        selectedMembers: Binding<[IdolMember]>,
        onChanged: (([IdolMember]) -> Void)? = nil,
        onCreateMember: @escaping () -> Void
    ) {
        self.mode = .binding(selectedMembers, onChanged: onChanged)
        self.onCreateMember = onCreateMember
    }

    private var validMembers: [IdolMember] {
        idolMembers.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var validGroups: [IdolGroup] {
        idolGroups.filter { group in
            !group.isDeleted && group.modelContext != nil &&
            validMembers.contains(where: { $0.group?.id == group.id })
        }
    }

    private var ungroupedMembers: [IdolMember] {
        validMembers.filter { $0.group == nil }
    }

    private var selectedMemberIDs: Set<UUID> {
        switch mode {
        case .chekiItem(let item):
            guard !item.isDeleted, item.modelContext != nil else { return [] }
            return Set(item.assignedMemberIDs)
        case .binding(let binding, _):
            return Set(binding.wrappedValue.map(\.id))
        }
    }

    private var activeGroupID: UUID? {
        if let selectedGroupID {
            if selectedGroupID == Self.ungroupedCategoryID && !ungroupedMembers.isEmpty {
                return selectedGroupID
            }
            if validGroups.contains(where: { $0.id == selectedGroupID }) {
                return selectedGroupID
            }
        }
        if let firstSelectedMemberID = selectedMemberIDs.first,
           let firstMember = validMembers.first(where: { $0.id == firstSelectedMemberID }) {
            return firstMember.group?.id ?? Self.ungroupedCategoryID
        }
        return validGroups.first?.id ?? (ungroupedMembers.isEmpty ? nil : Self.ungroupedCategoryID)
    }

    private var displayedMembersInActiveGroup: [IdolMember] {
        guard let activeID = activeGroupID else { return validMembers }
        if activeID == Self.ungroupedCategoryID {
            return ungroupedMembers
        }
        return validMembers.filter { $0.group?.id == activeID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 頂部狀態與快速設為未分類列
            HStack(spacing: 8) {
                Label(L10n.tr("成員", "メンバー"), systemImage: "person.2.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !selectedMemberIDs.isEmpty {
                    Button {
                        clearAllSelectedMembers()
                    } label: {
                        Text(L10n.tr("未分類", "未分類"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemGroupedBackground))

            Divider()

            // 中央雙層選單：左欄「團體」➔ 右欄「成員」（點擊成員直接勾選/取消勾選，不自動關閉）
            HStack(spacing: 0) {
                // 第一層：團體列表
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(validGroups) { group in
                            let isActive = (activeGroupID == group.id)
                            let countInGroup = validMembers.filter {
                                $0.group?.id == group.id && selectedMemberIDs.contains($0.id)
                            }.count

                            Button {
                                UISelectionFeedbackGenerator().selectionChanged()
                                selectedGroupID = group.id
                            } label: {
                                HStack(spacing: 6) {
                                    Text(group.name)
                                        .font(.subheadline.weight(isActive ? .bold : .medium))
                                        .foregroundStyle(isActive ? .primary : .secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)

                                    Spacer(minLength: 2)

                                    if countInGroup > 0 {
                                        Text("\(countInGroup)")
                                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5.5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.blue, in: Capsule())
                                    }

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(isActive ? .primary : .tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    isActive
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if !ungroupedMembers.isEmpty {
                            let isActive = (activeGroupID == Self.ungroupedCategoryID)
                            let countUngrouped = ungroupedMembers.filter { selectedMemberIDs.contains($0.id) }.count

                            Button {
                                UISelectionFeedbackGenerator().selectionChanged()
                                selectedGroupID = Self.ungroupedCategoryID
                            } label: {
                                HStack(spacing: 6) {
                                    Text(L10n.tr("未分團", "未所属"))
                                        .font(.subheadline.weight(isActive ? .bold : .medium))
                                        .foregroundStyle(isActive ? .primary : .secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)

                                    Spacer(minLength: 2)

                                    if countUngrouped > 0 {
                                        Text("\(countUngrouped)")
                                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5.5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.blue, in: Capsule())
                                    }

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(isActive ? .primary : .tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    isActive
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(width: 148)
                .background(Color(.systemGroupedBackground))

                Divider()

                // 第二層：成員列表（支援多選，點選不會關閉）
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(displayedMembersInActiveGroup) { member in
                            let isSelected = selectedMemberIDs.contains(member.id)
                            Button {
                                toggleMemberSelection(member)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(isSelected ? Color.blue : .secondary)

                                    Text(member.stageName)
                                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    isSelected ? Color.blue.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .frame(width: 172)
                .background(Color(.secondarySystemGroupedBackground))
            }
            .frame(height: 230)

            Divider()

            // 底部：新增成員按鈕
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    onCreateMember()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.tr("成員", "メンバー"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .frame(width: 320)
        .onAppear {
            if selectedGroupID == nil {
                selectedGroupID = activeGroupID
            }
        }
    }

    private func toggleMemberSelection(_ member: IdolMember) {
        UISelectionFeedbackGenerator().selectionChanged()
        switch mode {
        case .chekiItem(let item):
            guard !item.isDeleted, item.modelContext != nil else { return }
            item.toggleAssignedMember(member, allMembers: validMembers)
            try? modelContext.save()
            syncItemToPhotosIfNeeded(item)

        case .binding(let binding, let onChanged):
            var current = binding.wrappedValue
            if let idx = current.firstIndex(where: { $0.id == member.id }) {
                current.remove(at: idx)
            } else {
                current.append(member)
            }
            binding.wrappedValue = current
            onChanged?(current)
        }
    }

    private func clearAllSelectedMembers() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch mode {
        case .chekiItem(let item):
            guard !item.isDeleted, item.modelContext != nil else { return }
            item.setAssignedMembers([])
            try? modelContext.save()
            syncItemToPhotosIfNeeded(item)

        case .binding(let binding, let onChanged):
            binding.wrappedValue = []
            onChanged?([])
        }
    }

    private func syncItemToPhotosIfNeeded(_ item: ChekiItem) {
        let autoSync = UserDefaults.standard.object(forKey: "autoSyncToPhotosLibrary") as? Bool ?? true
        if autoSync {
            Task { @MainActor in
                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                    [item],
                    modelContext: modelContext,
                    onlyAlbumAndDateIfAlreadySynced: false
                )
            }
        }
    }
}

