import SwiftUI
import SwiftData

/// 仿照 Apple 原生相簿「最近刪除」相冊
/// - 顯示被移至垃圾桶的拍立得清單（保留 30 天）
/// - 每張照片下方顯示剩餘倒數天數（如「還有 29 天」）
/// - 支援單張點擊復原／永久刪除
/// - 支援進入「選取」模式，支援點擊與滑動連續多選、批次復原、批次立即永久刪除
struct RecentlyDeletedView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \ChekiItem.deletedAt, order: .reverse) private var allItems: [ChekiItem]

    @State private var isSelectionMode: Bool = false
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var showDeleteConfirmation: Bool = false
    @State private var targetSingleItem: ChekiItem? = nil
    @State private var isProcessing: Bool = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var trashedItems: [ChekiItem] {
        allItems.filter { $0.isDeleted && $0.modelContext != nil }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground)
                .ignoresSafeArea()

            if trashedItems.isEmpty {
                emptyTrashView
            } else {
                VStack(spacing: 0) {
                    headerPromptBanner

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(trashedItems, id: \.id) { item in
                                cellView(for: item)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, isSelectionMode ? 64 : 20)
                        .overlay {
                            if isSelectionMode {
                                ApplePhotosDragSelectOverlay(
                                    itemIDs: trashedItems.map(\.id),
                                    columnCount: 3,
                                    spacing: 2,
                                    cellAspectRatio: 54 / 86,
                                    selectedItemIDs: $selectedItemIDs
                                )
                            }
                        }
                    }
                }
            }

            if isSelectionMode && !trashedItems.isEmpty {
                selectionBottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(L10n.tr("最近刪除", "最近削除した項目"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !trashedItems.isEmpty {
                    Button(isSelectionMode ? L10n.tr("完成", "完了") : L10n.tr("選取", "選択")) {
                        withAnimation(ChekiMotion.toggle) {
                            if isSelectionMode {
                                exitSelection()
                            } else {
                                isSelectionMode = true
                            }
                        }
                    }
                    .font(.body.weight(isSelectionMode ? .semibold : .regular))
                }
            }
        }
        .confirmationDialog(
            targetSingleItem != nil ? L10n.tr("拍立得操作", "チェキの操作") : "",
            isPresented: Binding(
                get: { targetSingleItem != nil },
                set: { if !$0 { targetSingleItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = targetSingleItem {
                Button(L10n.tr("復原拍立得", "チェキを復元")) {
                    restoreItems([item])
                    targetSingleItem = nil
                }

                Button(L10n.tr("立即永久刪除", "完全に削除"), role: .destructive) {
                    permanentlyDeleteItems([item])
                    targetSingleItem = nil
                }

                Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                    targetSingleItem = nil
                }
            }
        }
        .confirmationDialog(
            selectedItemIDs.isEmpty
                ? L10n.tr("確定要永久刪除所有項目嗎？此動作無法復原。", "最近削除したすべての項目を完全に削除しますか？この操作は取り消せません。")
                : L10n.tr("確定要永久刪除選取的項目嗎？此動作無法復原。", "選択した項目を完全に削除しますか？この操作は取り消せません。"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                selectedItemIDs.isEmpty
                    ? L10n.tr("全部永久刪除", "すべて完全に削除")
                    : L10n.tr("永久刪除", "完全に削除"),
                role: .destructive
            ) {
                executePermanentDeletion()
            }

            Button(L10n.tr("取消", "キャンセル"), role: .cancel) {}
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerPromptBanner: some View {
        Text(L10n.tr("項目會在此保留最多 30 天，逾期將永久刪除。", "項目は最大30日間ここに保持され、その後完全に削除されます。"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private var emptyTrashView: some View {
        ContentUnavailableView {
            Label(
                L10n.tr("沒有最近刪除的項目", "最近削除した項目はありません"),
                systemImage: "trash"
            )
        } description: {
            Text(L10n.tr("刪除的拍立得將在此保留最多 30 天，逾期將自動永久刪除。", "削除されたチェキはここで最大30日間保持され、その後完全に削除されます。"))
        }
    }

    @ViewBuilder
    private func cellView(for item: ChekiItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.id)
        let days = item.daysRemainingUntilPermanentDeletion

        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                thumbnailImage(for: item)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .aspectRatio(54 / 86, contentMode: .fit)

            // 剩餘天數標籤
            HStack {
                Text(L10n.tr("還有 \(days) 天", "あと\(days)日"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: Capsule())
            }
            .padding(4)

            // 選取模式勾選指示器
            if isSelectionMode {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(isSelected ? Color.blue : Color.white.opacity(0.85))
                            .background(
                                Circle()
                                    .fill(isSelected ? Color.white : Color.black.opacity(0.2))
                                    .frame(width: 20, height: 20)
                            )
                            .padding(6)
                    }
                    Spacer()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                toggleSelection(for: item.id)
            } else {
                targetSingleItem = item
            }
        }
    }

    @ViewBuilder
    private func thumbnailImage(for item: ChekiItem) -> some View {
        if let uiImage = ChekiImageCacheManager.shared.syncThumbnail(for: item) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if let data = item.thumbnailData ?? item.frontImageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color(.secondarySystemFill))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }

    @ViewBuilder
    private var selectionBottomBar: some View {
        HStack {
            Button {
                restoreSelectionOrAll()
            } label: {
                Text(
                    selectedItemIDs.isEmpty
                        ? L10n.tr("全部復原", "すべて復元")
                        : L10n.tr("復原", "復元")
                )
                .font(.body.weight(.medium))
            }

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Text(
                    selectedItemIDs.isEmpty
                        ? L10n.tr("全部刪除", "すべて削除")
                        : L10n.tr("刪除", "削除")
                )
                .font(.body.weight(.medium))
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 50)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Actions

    private func exitSelection() {
        isSelectionMode = false
        selectedItemIDs.removeAll()
    }

    private func toggleSelection(for id: UUID) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func restoreSelectionOrAll() {
        let itemsToRestore: [ChekiItem]
        if selectedItemIDs.isEmpty {
            itemsToRestore = trashedItems
        } else {
            itemsToRestore = trashedItems.filter { selectedItemIDs.contains($0.id) }
        }
        restoreItems(itemsToRestore)
        withAnimation(ChekiMotion.toggle) {
            exitSelection()
        }
    }

    private func restoreItems(_ items: [ChekiItem]) {
        guard !items.isEmpty else { return }
        try? ChekiTrashManager.shared.restore(items, in: modelContext)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func executePermanentDeletion() {
        let itemsToDelete: [ChekiItem]
        if selectedItemIDs.isEmpty {
            itemsToDelete = trashedItems
        } else {
            itemsToDelete = trashedItems.filter { selectedItemIDs.contains($0.id) }
        }
        permanentlyDeleteItems(itemsToDelete)
        withAnimation(ChekiMotion.toggle) {
            exitSelection()
        }
    }

    private func permanentlyDeleteItems(_ items: [ChekiItem]) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            try? await ChekiTrashManager.shared.permanentlyDelete(items, in: modelContext)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
