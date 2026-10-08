import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Album Hierarchy Mode (相冊頂部分段控制：團體 vs 成員)

enum AlbumHierarchyMode: String, CaseIterable, Identifiable {
    case groups = "團體"
    case members = "成員"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groups:
            return L10n.tr("團體", "グループ")
        case .members:
            return L10n.tr("成員", "メンバー")
        }
    }
}

enum AlbumSortMethod: String, CaseIterable, Identifiable {
    case name = "name"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:
            return L10n.tr("名稱", "名前順")
        case .custom:
            return L10n.tr("客製", "カスタム")
        }
    }
}

enum AlbumDisplayMode: String, CaseIterable, Identifiable {
    case grid = "grid"
    case list = "list"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grid:
            return L10n.tr("格狀", "グリッド")
        case .list:
            return L10n.tr("清單", "リスト")
        }
    }

    var iconName: String {
        switch self {
        case .grid:
            return "square.grid.2x2"
        case .list:
            return "list.bullet"
        }
    }
}

// MARK: - Uncategorized Album Route

struct UncategorizedAlbumRoute: Hashable {}

// MARK: - 1. LibraryView (底部左側 Tab 1：「全部」— 仿照 Apple 相簿 ライブラリ 頁面)

/// 「全部」拍立得視圖（對應參考圖 1、圖 2 Apple 相簿 `ライブラリ`）
/// - 頂部標題「全部」與「N 個項目」位於左上方，與右側篩選 / 選取膠囊同一水平列（不因 Large Title 下推）
/// - 僅顯示圓角拍立得相片本身（依真實比例呈現於網格中，不顯示下方文字卡）
/// - 支援雙指縮放手勢（`MagnifyGesture`）在 1 / 2 / 3 / 5 欄密度間平滑切換
struct LibraryView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = true

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var processingItems: [PhotosPickerItem] = []
    @State private var isProcessing: Bool = false

    @State private var isSelectionMode: Bool = false
    @State private var selectionViewID = UUID()
    private var chromeState = NavigationChromeState.shared
    @State private var selectedItemIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm: Bool = false

    @State private var showingQuickCreateSheet: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingCameraScanner: Bool = false
    @State private var showingBatchPairingSheet: Bool = false
    @State private var systemPhotoSeedAlertMessage: String? = nil

    // 排序與篩選
    @State private var sortAscending: Bool = false
    @State private var filterDualSideOnly: Bool = false

    // 雙指縮放欄數狀態（支援 1, 2, 3, 5 欄；預設 3 欄如圖 1，縮小可切換至 5 欄如圖 2）
    private static let supportedColumnCounts = [1, 2, 3, 5]
    @State private var columnCount: Int = 3
    @State private var pinchBaselineColumnCount: Int? = nil

    init() {}

    private var validChekiItems: [ChekiItem] {
        chekiItems.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var displayedItems: [ChekiItem] {
        let filtered = filterDualSideOnly ? validChekiItems.filter(\.hasBothSides) : validChekiItems
        return filtered.sorted {
            sortAscending ? ($0.displayDate < $1.displayDate) : ($0.displayDate > $1.displayDate)
        }
    }

    private var gridSpacing: CGFloat {
        switch columnCount {
        case 1: return 16
        case 2: return 12
        case 3: return 10
        default: return 6
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    static func matchesSearch(item: ChekiItem, query: String, allMembers: [IdolMember] = []) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let normalized = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed

        let resolvedMembers: [IdolMember] = {
            if !allMembers.isEmpty {
                return item.assignedMembers(from: allMembers)
            } else if let primary = item.idolMember {
                return [primary]
            }
            return []
        }()

        if !resolvedMembers.isEmpty {
            for member in resolvedMembers {
                if member.stageName.localizedCaseInsensitiveContains(normalized) { return true }
                if let groupName = member.group?.name,
                   groupName.localizedCaseInsensitiveContains(normalized) { return true }
                if member.tags.contains(where: { $0.localizedCaseInsensitiveContains(normalized) }) { return true }
            }
        } else if "未分類".localizedCaseInsensitiveContains(normalized) {
            return true
        }

        if let memo = item.memo {
            if let eventName = memo.eventName,
               eventName.localizedCaseInsensitiveContains(normalized) { return true }
            if let noteText = memo.noteText,
               noteText.localizedCaseInsensitiveContains(normalized) { return true }
            if memo.hashtags.contains(where: { $0.localizedCaseInsensitiveContains(normalized) }) { return true }
        }

        let dateString = ChekiDateFormatter.shared.string(from: item.displayDate)
        if dateString.localizedCaseInsensitiveContains(normalized) { return true }

        return false
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemBackground)
                    .ignoresSafeArea()

                if validChekiItems.isEmpty {
                    emptyStateView
                        .padding(.top, 72)
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                            ForEach(displayedItems) { item in
                                photoGridCell(for: item)
                            }
                        }
                        .overlay {
                            if isSelectionMode {
                                ApplePhotosDragSelectOverlay(
                                    itemIDs: displayedItems.map(\.persistentModelID),
                                    columnCount: columnCount,
                                    spacing: gridSpacing,
                                    cellAspectRatio: 0.75,
                                    selectedItemIDs: $selectedItemIDs
                                )
                            }
                        }
                        .padding(.horizontal, columnCount >= 5 ? 8 : 14)
                        .padding(.top, 82)
                        .padding(.bottom, isSelectionMode ? 96 : 32)
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: columnCount)
                    }
                    .simultaneousGesture(pinchZoomGesture)
                }

                // 頂部懸浮標題與控制列（對齊 Apple 相簿 ライブラリ 頂部位置）
                topFloatingHeaderBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar((isSelectionMode || chromeState.shouldHideMainTabBar) ? .hidden : .visible, for: .tabBar)
            .onChange(of: isSelectionMode) { _, newValue in
                NavigationChromeState.shared.setSelectionMode(newValue, id: selectionViewID)
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionBottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .confirmationDialog(
                "確定要刪除\(selectedItemIDs.count)張照片嗎？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("刪除 \(selectedItemIDs.count) 張拍立得", role: .destructive) {
                    deleteSelectedItems()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(
                    autoSyncToPhotos
                        ? "此操作會將拍立得從 ChekiLens 典藏庫與 iOS 系統相簿中一併刪除。"
                        : "此操作會將拍立得從 ChekiLens 典藏庫移除，且無法復原。"
                )
            }
            .sheet(isPresented: $showingQuickCreateSheet) {
                QuickCreateIdolSheet()
            }
        .sheet(isPresented: $showingSettingsSheet, onDismiss: {
                if autoSyncToPhotos {
                    Task {
                        await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                            validChekiItems,
                            modelContext: modelContext,
                            onlyAlbumAndDateIfAlreadySynced: false
                        )
                    }
                }
            }) {
                SettingsView()
            }
            .sheet(isPresented: $showingBatchPairingSheet, onDismiss: {
                processingItems = []
                if autoSyncToPhotos {
                    Task {
                        await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                            validChekiItems,
                            modelContext: modelContext,
                            onlyAlbumAndDateIfAlreadySynced: true
                        )
                    }
                }
            }) {
                BatchPairingView(initialPickerItems: processingItems)
            }
            .onChange(of: autoSyncToPhotos) { _, isEnabled in
                guard isEnabled else { return }
                Task {
                    await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                        validChekiItems,
                        modelContext: modelContext,
                        onlyAlbumAndDateIfAlreadySynced: false
                    )
                }
            }
            .fullScreenCover(isPresented: $showingCameraScanner) {
                CameraScannerView()
            }
            .overlay {
                if isProcessing {
                    processingOverlay
                }
            }
            .navigationDestination(for: ChekiDetailRoute.self) { route in
                ChekiDetailView(itemID: route.itemID, scopedItemIDs: route.scopedItemIDs)
                    .toolbar(.hidden, for: .tabBar)
            }
            .alert(
                "iOS 系統相簿測試相片",
                isPresented: Binding(
                    get: { systemPhotoSeedAlertMessage != nil },
                    set: { if !$0 { systemPhotoSeedAlertMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {
                    systemPhotoSeedAlertMessage = nil
                }
            } message: {
                Text(systemPhotoSeedAlertMessage ?? "")
            }
            .task {
                #if DEBUG
                _ = try? await PhotoLibraryManager.shared.seedTestChekiPhotosToSystemLibrary(force: false)
                #endif
            }
        }
    }

    // MARK: - Top Floating Header Bar (仿照圖 1 / 圖 2：左上大標題 + 項目數，右上篩選與選取按鈕同列)

    private var topFloatingHeaderBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("全部")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                if !chekiItems.isEmpty {
                    Text("\(displayedItems.count) 個項目")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if isSelectionMode {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if selectedItemIDs.count == displayedItems.count {
                            selectedItemIDs.removeAll()
                        } else {
                            selectedItemIDs = Set(displayedItems.map(\.persistentModelID))
                        }
                    } label: {
                        Text(selectedItemIDs.count == displayedItems.count ? "取消全選" : "全選")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: false)
                            .darkSystemCapsuleChrome(height: 36)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showingCameraScanner = true
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.subheadline.weight(.semibold))
                            .darkSystemCircleChrome(size: 36)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("開啟相機拍攝拍立得")

                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: nil,
                        matching: .images,
                        preferredItemEncoding: .automatic,
                        photoLibrary: .shared()
                    ) {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .darkSystemCircleChrome(size: 36)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("匯入拍立得照片（進入配對工作台）")
                    .onChange(of: selectedPhotos) { _, newItems in
                        guard !newItems.isEmpty else { return }
                        processingItems = newItems
                        selectedPhotos = []
                        showingBatchPairingSheet = true
                    }

                    Menu {
                        Section("顯示密度（亦可雙指縮放）") {
                            ForEach(Self.supportedColumnCounts, id: \.self) { count in
                                Button {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                        columnCount = count
                                    }
                                } label: {
                                    Label(
                                        "\(count) 欄顯示",
                                        systemImage: columnCount == count ? "checkmark" : "square.grid.3x3"
                                    )
                                }
                            }
                        }

                        Section("排序與篩選") {
                            Button {
                                sortAscending = false
                            } label: {
                                Label("由新到舊", systemImage: !sortAscending ? "checkmark" : "arrow.down")
                            }
                            Button {
                                sortAscending = true
                            } label: {
                                Label("由舊到新", systemImage: sortAscending ? "checkmark" : "arrow.up")
                            }
                            Button {
                                filterDualSideOnly.toggle()
                            } label: {
                                Label(
                                    "僅顯示正反雙面",
                                    systemImage: filterDualSideOnly ? "checkmark" : "rectangle.portrait.on.rectangle.portrait"
                                )
                            }
                        }

                        Section("管理") {
                            Button {
                                processingItems = []
                                showingBatchPairingSheet = true
                            } label: {
                                Label("批次配對工作台（含測試資料）", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                            }

                            Button {
                                Task {
                                    do {
                                        let count = try await PhotoLibraryManager.shared.seedTestChekiPhotosToSystemLibrary(force: true)
                                        systemPhotoSeedAlertMessage = L10n.tr(
                                            "已成功將 \(count) 張帶封面手寫日期的拍立得相片寫入 iOS 原生相簿 (Photos.app)。\n\n現在請點選右上角「＋」從系統相簿選取相片，即可實測導入與自動日期判斷！",
                                            "日付入りのチェキ写真 \(count) 枚を iOS 標準の「写真」アプリに保存しました。\n\n右上の「＋」から写真を選択して、取り込みと日付の自動認識をお試しください！"
                                        )
                                    } catch {
                                        systemPhotoSeedAlertMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Label("寫入 10 張帶日期拍立得至系統相簿 (Photos.app)", systemImage: "photo.badge.plus")
                            }

                            Button {
                                showingQuickCreateSheet = true
                            } label: {
                                Label("新增團體 / 成員", systemImage: "person.badge.plus")
                            }

                            Button {
                                withAnimation {
                                    PreviewData.populate(into: modelContext)
                                }
                            } label: {
                                Label("載入範例測試資料", systemImage: "sparkles.rectangle.stack")
                            }

                            Button {
                                showingSettingsSheet = true
                            } label: {
                                Label("設定（自動邊界微調）", systemImage: "gearshape")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.subheadline.weight(.semibold))
                            .darkSystemCircleChrome(size: 36)
                    }
                    .fixedSize()
                    .accessibilityLabel("篩選與更多設定")
                }

                if !displayedItems.isEmpty {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.snappy(duration: 0.22)) {
                            isSelectionMode.toggle()
                            if !isSelectionMode {
                                selectedItemIDs.removeAll()
                            }
                        }
                    } label: {
                        if isSelectionMode {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .darkSystemCircleChrome(size: 36)
                        } else {
                            Text("選取")
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false)
                                .darkSystemCapsuleChrome(height: 36)
                        }
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityLabel(isSelectionMode ? "完成選取" : "選取拍立得")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [
                    Color(.systemBackground).opacity(0.92),
                    Color(.systemBackground).opacity(0.65),
                    Color(.systemBackground).opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: - Pinch-to-Zoom Gesture (雙指縮放切換 1 / 2 / 3 / 5 欄)

    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBaselineColumnCount == nil {
                    pinchBaselineColumnCount = columnCount
                }
                guard let baseCount = pinchBaselineColumnCount,
                      let baseIndex = Self.supportedColumnCounts.firstIndex(of: baseCount) else { return }

                let magnification = value.magnification
                var targetIndex = baseIndex

                // 雙指張開放大 -> 減少欄數（圖片變大）
                if magnification > 1.65 {
                    targetIndex = max(0, baseIndex - 2)
                } else if magnification > 1.22 {
                    targetIndex = max(0, baseIndex - 1)
                }
                // 雙指捏合縮小 -> 增加欄數（圖片變小，如 3 欄 -> 5 欄）
                else if magnification < 0.60 {
                    targetIndex = min(Self.supportedColumnCounts.count - 1, baseIndex + 2)
                } else if magnification < 0.82 {
                    targetIndex = min(Self.supportedColumnCounts.count - 1, baseIndex + 1)
                }

                let newCount = Self.supportedColumnCounts[targetIndex]
                if newCount != columnCount {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        columnCount = newCount
                    }
                }
            }
            .onEnded { _ in
                pinchBaselineColumnCount = nil
            }
    }

    // MARK: - Photo Cell (仿照圖 1 / 圖 2：保留相片比例與圓角，無下方文字框)

    @ViewBuilder
    private func photoGridCell(for item: ChekiItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.persistentModelID)
        let cornerRadius: CGFloat = columnCount <= 2 ? 12 : (columnCount == 3 ? 9 : 5)

        if isSelectionMode {
            AppleLibraryPhotoCell(item: item, cornerRadius: cornerRadius)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(columnCount >= 5 ? .subheadline : .title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.9), isSelected ? .blue : .black.opacity(0.35))
                        .padding(columnCount >= 5 ? 4 : 8)
                }
                .scaleEffect(isSelected ? 0.95 : 1.0)
                .animation(.snappy(duration: 0.15), value: isSelected)
                .onTapGesture {
                    UISelectionFeedbackGenerator().selectionChanged()
                    if isSelected {
                        selectedItemIDs.remove(item.persistentModelID)
                    } else {
                        selectedItemIDs.insert(item.persistentModelID)
                    }
                }
        } else {
            NavigationLink(value: ChekiDetailRoute(itemID: item.id, scopedItemIDs: displayedItems.map(\.id))) {
                AppleLibraryPhotoCell(item: item, cornerRadius: cornerRadius)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Menu {
                    MemberAssignmentMenuContent(item: item) { showingQuickCreateSheet = true }
                } label: {
                    Label("指派推角成員", systemImage: "person.crop.circle.badge.plus")
                }
                .menuActionDismissBehavior(.disabled)

                Divider()

                Button(role: .destructive) {
                    Task { @MainActor in
                        await PhotoLibraryManager.shared.deleteItemsAsync([item], modelContext: modelContext)
                    }
                } label: {
                    Label("刪除此拍立得", systemImage: "trash")
                }
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("尚無拍立得典藏", systemImage: "photo.stack")
        } description: {
            Text("從系統相簿匯入您的拍立得照片，或載入範例測試資料體驗完整相冊與正反面典藏功能。")
        } actions: {
            VStack(spacing: 12) {
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: nil,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("從相簿選擇照片（不限張數）", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    processingItems = []
                    showingBatchPairingSheet = true
                } label: {
                    Label("開啟批次配對工作台（含測試資料）", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                }
                .buttonStyle(.bordered)

                Button {
                    withAnimation {
                        PreviewData.populate(into: modelContext)
                    }
                } label: {
                    Label("載入範例測試資料", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var selectionBottomBar: some View {
        ApplePhotosSelectionBottomBar(
            selectedCount: selectedItemIDs.count,
            onShare: {
                let selected = displayedItems.filter { selectedItemIDs.contains($0.persistentModelID) }
                ChekiBatchSharePresenter.share(items: selected)
            },
            onDelete: {
                showDeleteConfirm = true
            }
        )
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("AI 邊框偵測與正位中…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func deleteSelectedItems() {
        let itemsToDelete = validChekiItems.filter { selectedItemIDs.contains($0.persistentModelID) }
        withAnimation {
            isSelectionMode = false
            selectedItemIDs.removeAll()
        }
        Task { @MainActor in
            await PhotoLibraryManager.shared.deleteItemsAsync(itemsToDelete, modelContext: modelContext)
        }
    }

    @MainActor
    private func processImportedPhotos(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        defer { isProcessing = false }

        var affectedItems: [ChekiItem] = []

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let originalUIImage = UIImage(data: data) else { continue }

            let uiImage = originalUIImage.normalizedImage
            let normalizedData = uiImage.jpegData(compressionQuality: 0.92) ?? data

            if let assetId = item.itemIdentifier,
               !assetId.isEmpty,
               let existingItem = validChekiItems.first(where: { $0.frontAssetIdentifier == assetId }) {
                if existingItem.originalFrontImageData == nil {
                    existingItem.originalFrontImageData = normalizedData
                }
                await VisionPhotoProcessor.process(existingItem, image: uiImage)
                affectedItems.append(existingItem)
            } else {
                let newItem = ChekiItem(
                    frontImageData: normalizedData,
                    originalFrontImageData: normalizedData,
                    capturedAt: Date(),
                    processingState: .unprocessed,
                    frontAssetIdentifier: item.itemIdentifier
                )
                modelContext.insert(newItem)
                await VisionPhotoProcessor.process(newItem, image: uiImage)
                affectedItems.append(newItem)
            }
        }

        try? modelContext.save()

        if autoSyncToPhotos && !affectedItems.isEmpty {
            await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                affectedItems,
                modelContext: modelContext,
                onlyAlbumAndDateIfAlreadySynced: false
            )
        }
    }
}

// MARK: - AppleLibraryPhotoCell (仿照圖 1 / 圖 2：在網格單元中呈現真實比例圓角相片)

private struct AppleLibraryPhotoCell: View {
    let item: ChekiItem
    let cornerRadius: CGFloat

    var body: some View {
        let isValid = !item.isDeleted && item.modelContext != nil
        ZStack(alignment: .topTrailing) {
            if isValid,
               let uiImage = ChekiThumbnailCache.shared.image(for: item) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        ChekiWatermarkOverlayView(compact: true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .aspectRatio(0.7, contentMode: .fit)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }

            if isValid && item.hasBothSides {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .aspectRatio(0.75, contentMode: .fit)
        .contentShape(Rectangle())
    }
}

// MARK: - 2. AlbumsRootView (底部左側 Tab 2：「相冊」— 仿照 Apple 原生相簿設計)

/// Apple 原生相簿風格的「相冊」視圖
/// - 頂部標題「相冊」與右側 `+` / `⋯` 同列，不浪費上方空間
/// - 點擊頂部 Segmented Control 的「成員」時，**直接在當前頁面原地展開所有成員相冊**（已修正圖片溢出阻擋點擊區域的問題）
/// - 點擊「團體」中的某個團體時，才進入該團體的成員頁面（`團體 > 成員`）
struct AlbumsRootView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    @AppStorage("albumSortMethod") private var sortMethodRaw: String = AlbumSortMethod.custom.rawValue
    @AppStorage("albumDisplayMode") private var displayModeRaw: String = AlbumDisplayMode.grid.rawValue

    @State private var hierarchyMode: AlbumHierarchyMode = .groups
    @State private var showingQuickCreateSheet: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingBatchPairingSheet: Bool = false
    @State private var showingCameraScanner: Bool = false
    @State private var showingAlbumPhotosPicker: Bool = false
    @State private var selectedAlbumPhotos: [PhotosPickerItem] = []
    @State private var pendingBatchPhotos: [PhotosPickerItem] = []
    @State private var actionTargetMember: IdolMember? = nil

    @State private var renamingGroup: IdolGroup? = nil
    @State private var renamingMember: IdolMember? = nil
    @State private var renameText: String = ""
    @State private var draggingGroupID: UUID? = nil
    @State private var draggingMemberID: UUID? = nil
    private var chromeState = NavigationChromeState.shared

    private var sortMethod: AlbumSortMethod {
        AlbumSortMethod(rawValue: sortMethodRaw) ?? .custom
    }

    private var displayMode: AlbumDisplayMode {
        AlbumDisplayMode(rawValue: displayModeRaw) ?? .grid
    }

    private let albumColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var validChekiItems: [ChekiItem] {
        chekiItems.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var uncategorizedItems: [ChekiItem] {
        validChekiItems.filter { $0.isUncategorized }
    }

    private var sortedGroups: [IdolGroup] {
        switch sortMethod {
        case .name:
            return idolGroups.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .custom:
            return idolGroups.sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.createdAt < $1.createdAt
            }
        }
    }

    /// 取得所有成員（依當前排序模式排列，確保在「成員」模式下完整展開所有團體的成員）
    private var allExpandedMembers: [IdolMember] {
        var result: [IdolMember] = []
        var seenIDs = Set<UUID>()

        for group in sortedGroups {
            for member in group.sortedMembers {
                if seenIDs.insert(member.id).inserted {
                    result.append(member)
                }
            }
        }
        for member in idolMembers {
            if seenIDs.insert(member.id).inserted {
                result.append(member)
            }
        }

        switch sortMethod {
        case .name:
            return result.sorted {
                $0.albumTitle.localizedStandardCompare($1.albumTitle) == .orderedAscending
            }
        case .custom:
            return result.sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.albumTitle.localizedStandardCompare($1.albumTitle) == .orderedAscending
            }
        }
    }

    init() {}

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch hierarchyMode {
                        case .groups:
                            groupsAlbumGrid
                        case .members:
                            allMembersAlbumGrid
                        }
                    }
                    .padding(.top, 108)
                    .padding(.bottom, 28)
                }

                // 頂部固定標頭 + 「團體 | 成員」切換控制（設定 zIndex 並與下方卡片嚴格隔離點擊區域）
                albumsTopHeaderBar
                    .zIndex(10)
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(chromeState.shouldHideMainTabBar ? .hidden : .visible, for: .tabBar)
            .photosPicker(
                isPresented: $showingAlbumPhotosPicker,
                selection: $selectedAlbumPhotos,
                maxSelectionCount: nil,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedAlbumPhotos) { _, newItems in
                guard !newItems.isEmpty else { return }
                pendingBatchPhotos = newItems
                selectedAlbumPhotos = []
                showingBatchPairingSheet = true
            }
            .sheet(isPresented: $showingQuickCreateSheet) {
                QuickCreateIdolSheet()
            }
            .sheet(isPresented: $showingSettingsSheet) {
                SettingsView()
            }
            .sheet(isPresented: $showingBatchPairingSheet, onDismiss: {
                pendingBatchPhotos = []
                actionTargetMember = nil
            }) {
                BatchPairingView(initialPickerItems: pendingBatchPhotos, defaultMember: actionTargetMember)
            }
            .fullScreenCover(isPresented: $showingCameraScanner, onDismiss: {
                actionTargetMember = nil
            }) {
                CameraScannerView(defaultMember: actionTargetMember)
            }
            .alert(
                L10n.tr("修改團體名", "グループ名を変更"),
                isPresented: Binding(
                    get: { renamingGroup != nil },
                    set: { if !$0 { renamingGroup = nil } }
                )
            ) {
                TextField(L10n.tr("輸入新的團體名稱", "新しいグループ名を入力"), text: $renameText)
                Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                    renamingGroup = nil
                }
                Button(L10n.tr("儲存", "保存")) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let group = renamingGroup {
                        group.name = trimmed
                        try? modelContext.save()
                    }
                    renamingGroup = nil
                }
            }
            .alert(
                L10n.tr("修改成員名", "メンバー名を変更"),
                isPresented: Binding(
                    get: { renamingMember != nil },
                    set: { if !$0 { renamingMember = nil } }
                )
            ) {
                TextField(L10n.tr("輸入新的成員名稱", "新しいメンバー名を入力"), text: $renameText)
                Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                    renamingMember = nil
                }
                Button(L10n.tr("儲存", "保存")) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let member = renamingMember {
                        member.stageName = trimmed
                        try? modelContext.save()
                    }
                    renamingMember = nil
                }
            }
            .navigationDestination(for: IdolGroup.self) { group in
                GroupMembersAlbumView(group: group, allItems: validChekiItems)
            }
            .navigationDestination(for: IdolMember.self) { member in
                AlbumHeroDetailView(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    items: validChekiItems.filter { $0.isAssigned(to: member) },
                    defaultMember: member
                )
            }
            .navigationDestination(for: UncategorizedAlbumRoute.self) { _ in
                AlbumHeroDetailView(
                    primaryTitle: "未分類",
                    secondaryTitle: nil,
                    items: uncategorizedItems,
                    defaultMember: nil
                )
            }
            .navigationDestination(for: ChekiDetailRoute.self) { route in
                ChekiDetailView(itemID: route.itemID, scopedItemIDs: route.scopedItemIDs)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    // MARK: - Albums Top Header Bar

    private var albumsTopHeaderBar: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                Text("相冊")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: 0) {
                    Button {
                        showingQuickCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新增團體或成員相冊")

                    Rectangle()
                        .fill(.white.opacity(0.22))
                        .frame(width: 0.8, height: 18)

                    Menu {
                        Button {
                            actionTargetMember = nil
                            showingCameraScanner = true
                        } label: {
                            Label(L10n.tr("攝影追加", "撮影して追加"), systemImage: "camera")
                        }

                        Button {
                            actionTargetMember = nil
                            showingAlbumPhotosPicker = true
                        } label: {
                            Label(L10n.tr("從相冊讀入", "アルバムから読み込む"), systemImage: "photo.badge.plus")
                        }

                        if hierarchyMode == .groups && !sortedGroups.isEmpty {
                            Menu {
                                ForEach(sortedGroups) { group in
                                    Button {
                                        renameText = group.name
                                        renamingGroup = group
                                    } label: {
                                        Label(group.name, systemImage: "pencil")
                                    }
                                }
                            } label: {
                                Label(L10n.tr("修改團體名", "グループ名を変更"), systemImage: "pencil")
                            }
                        } else if hierarchyMode == .members && !allExpandedMembers.isEmpty {
                            Menu {
                                ForEach(allExpandedMembers) { member in
                                    Button {
                                        renameText = member.stageName
                                        renamingMember = member
                                    } label: {
                                        Label(member.albumTitle, systemImage: "pencil")
                                    }
                                }
                            } label: {
                                Label(L10n.tr("修改成員名", "メンバー名を変更"), systemImage: "pencil")
                            }
                        }

                        Divider()

                        Menu {
                            ForEach(AlbumSortMethod.allCases) { method in
                                Button {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        sortMethodRaw = method.rawValue
                                    }
                                } label: {
                                    if sortMethod == method {
                                        Label(method.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(method.displayName)
                                    }
                                }
                            }
                        } label: {
                            Label(L10n.tr("排序方法", "並び替え"), systemImage: "arrow.up.arrow.down")
                        }

                        Menu {
                            ForEach(AlbumDisplayMode.allCases) { mode in
                                Button {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        displayModeRaw = mode.rawValue
                                    }
                                } label: {
                                    Label(mode.displayName, systemImage: displayMode == mode ? "checkmark" : mode.iconName)
                                }
                            }
                        } label: {
                            Label(L10n.tr("顯示方式", "表示形式"), systemImage: displayMode.iconName)
                        }

                        Divider()

                        Button {
                            pendingBatchPhotos = []
                            actionTargetMember = nil
                            showingBatchPairingSheet = true
                        } label: {
                            Label("批次配對工作台（含測試資料）", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                        }

                        Button {
                            withAnimation {
                                PreviewData.populate(into: modelContext)
                            }
                        } label: {
                            Label("載入範例測試資料", systemImage: "sparkles.rectangle.stack")
                        }

                        Divider()

                        Button {
                            showingSettingsSheet = true
                        } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多選項與設定")
                }
                .darkSystemUnifiedCapsuleContainer()
            }

            // 頂部「團體 | 成員」原地切換（點擊「成員」直接在此頁面展開所有成員相冊）
            Picker("相冊檢視階層", selection: $hierarchyMode.animation(.snappy(duration: 0.22))) {
                ForEach(AlbumHierarchyMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // MARK: - 團體相冊網格 / 清單（基本相簿構造：團體 > 成員）

    @ViewBuilder
    private var groupsAlbumGrid: some View {
        if sortedGroups.isEmpty && uncategorizedItems.isEmpty {
            ContentUnavailableView {
                Label("尚無團體相冊", systemImage: "rectangle.stack")
            } description: {
                Text("建立團體與推角成員，即可按「團體 ＞ 成員」階層管理拍立得相冊。")
            } actions: {
                Button("新增團體與成員") {
                    showingQuickCreateSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 48)
        } else if displayMode == .grid {
            LazyVGrid(columns: albumColumns, spacing: 12) {
                ForEach(sortedGroups) { group in
                    groupAlbumEntryView(for: group, isList: false)
                }

                if !uncategorizedItems.isEmpty {
                    uncategorizedAlbumEntryView(isList: false)
                }
            }
            .padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(sortedGroups) { group in
                    groupAlbumEntryView(for: group, isList: true)
                }

                if !uncategorizedItems.isEmpty {
                    uncategorizedAlbumEntryView(isList: true)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func groupAlbumEntryView(for group: IdolGroup, isList: Bool) -> some View {
        let covers = Self.groupCoverImages(for: group, allItems: validChekiItems)
        NavigationLink(value: group) {
            if isList {
                ApplePhotoAlbumListRow(
                    primaryTitle: group.name,
                    secondaryTitle: nil,
                    coverImagesData: covers,
                    showsDragHandle: sortMethod == .custom
                )
            } else {
                ApplePhotoAlbumTile(
                    primaryTitle: group.name,
                    secondaryTitle: nil,
                    coverImagesData: covers
                )
            }
        }
        .buttonStyle(.plain)
        .onDrag {
            draggingGroupID = group.id
            return NSItemProvider(object: group.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: GroupAlbumDropDelegate(
                targetGroup: group,
                groups: sortedGroups,
                draggingGroupID: $draggingGroupID,
                onReorder: { reordered in
                    sortMethodRaw = AlbumSortMethod.custom.rawValue
                    for (idx, item) in reordered.enumerated() {
                        item.sortOrder = idx
                    }
                    try? modelContext.save()
                }
            )
        )
        .contextMenu {
            Button {
                actionTargetMember = group.sortedMembers.first
                showingCameraScanner = true
            } label: {
                Label(L10n.tr("攝影追加", "撮影して追加"), systemImage: "camera")
            }

            Button {
                actionTargetMember = group.sortedMembers.first
                showingAlbumPhotosPicker = true
            } label: {
                Label(L10n.tr("從相冊讀入", "アルバムから読み込む"), systemImage: "photo.badge.plus")
            }

            Divider()

            Button {
                renameText = group.name
                renamingGroup = group
            } label: {
                Label(L10n.tr("修改團體名", "グループ名を変更"), systemImage: "pencil")
            }
        }
    }

    // MARK: - 成員相冊網格 / 清單（無視團體階層，直接在原本頁面展開所有成員相冊）

    @ViewBuilder
    private var allMembersAlbumGrid: some View {
        if allExpandedMembers.isEmpty && uncategorizedItems.isEmpty {
            ContentUnavailableView {
                Label("尚無成員相冊", systemImage: "person.2.crop.square.stack")
            } description: {
                Text("新增您的推角成員，直接展開瀏覽所有成員的專屬相冊。")
            } actions: {
                Button("新增推角成員") {
                    showingQuickCreateSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 48)
        } else if displayMode == .grid {
            LazyVGrid(columns: albumColumns, spacing: 12) {
                ForEach(allExpandedMembers) { member in
                    memberAlbumEntryView(for: member, isList: false)
                }

                if !uncategorizedItems.isEmpty {
                    uncategorizedAlbumEntryView(isList: false)
                }
            }
            .padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(allExpandedMembers) { member in
                    memberAlbumEntryView(for: member, isList: true)
                }

                if !uncategorizedItems.isEmpty {
                    uncategorizedAlbumEntryView(isList: true)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func memberAlbumEntryView(for member: IdolMember, isList: Bool) -> some View {
        let covers = Self.memberCoverImages(for: member, allItems: validChekiItems)
        NavigationLink(value: member) {
            if isList {
                ApplePhotoAlbumListRow(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    coverImagesData: covers,
                    showsDragHandle: sortMethod == .custom
                )
            } else {
                ApplePhotoAlbumTile(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    coverImagesData: covers
                )
            }
        }
        .buttonStyle(.plain)
        .onDrag {
            draggingMemberID = member.id
            return NSItemProvider(object: member.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: MemberAlbumDropDelegate(
                targetMember: member,
                members: allExpandedMembers,
                draggingMemberID: $draggingMemberID,
                onReorder: { reordered in
                    sortMethodRaw = AlbumSortMethod.custom.rawValue
                    for (idx, item) in reordered.enumerated() {
                        item.sortOrder = idx
                    }
                    try? modelContext.save()
                }
            )
        )
        .contextMenu {
            Button {
                actionTargetMember = member
                showingCameraScanner = true
            } label: {
                Label(L10n.tr("攝影追加", "撮影して追加"), systemImage: "camera")
            }

            Button {
                actionTargetMember = member
                showingAlbumPhotosPicker = true
            } label: {
                Label(L10n.tr("從相冊讀入", "アルバムから読み込む"), systemImage: "photo.badge.plus")
            }

            Divider()

            Button {
                renameText = member.stageName
                renamingMember = member
            } label: {
                Label(L10n.tr("修改成員名", "メンバー名を変更"), systemImage: "pencil")
            }
        }
    }

    @ViewBuilder
    private func uncategorizedAlbumEntryView(isList: Bool) -> some View {
        let covers = uncategorizedItems.compactMap(\.frontImageData)
        NavigationLink(value: UncategorizedAlbumRoute()) {
            if isList {
                ApplePhotoAlbumListRow(
                    primaryTitle: "未分類",
                    secondaryTitle: nil,
                    coverImagesData: covers,
                    showsDragHandle: false
                )
            } else {
                ApplePhotoAlbumTile(
                    primaryTitle: "未分類",
                    secondaryTitle: nil,
                    coverImagesData: covers
                )
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                actionTargetMember = nil
                showingCameraScanner = true
            } label: {
                Label(L10n.tr("攝影追加", "撮影して追加"), systemImage: "camera")
            }

            Button {
                actionTargetMember = nil
                showingAlbumPhotosPicker = true
            } label: {
                Label(L10n.tr("從相冊讀入", "アルバムから読み込む"), systemImage: "photo.badge.plus")
            }
        }
    }

    static func groupCoverImages(for group: IdolGroup, allItems: [ChekiItem] = []) -> [Data] {
        var result: [Data] = []
        for member in group.sortedMembers {
            if let cover = memberCoverImages(for: member, allItems: allItems).first {
                result.append(cover)
            }
        }
        return result
    }

    static func memberCoverImages(for member: IdolMember, allItems: [ChekiItem] = []) -> [Data] {
        if !allItems.isEmpty {
            let memberItems = allItems
                .filter { !$0.isDeleted && $0.modelContext != nil && $0.isAssigned(to: member) }
                .sorted { $0.displayDate > $1.displayDate }
            if let latest = memberItems.first?.frontImageData {
                return [latest]
            }
        }
        if let latest = member.latestCheki?.frontImageData {
            return [latest]
        }
        return []
    }
}

// MARK: - 3. ApplePhotoAlbumTile & ApplePhotoAlbumListRow & Drag Reorder DropDelegates

struct ApplePhotoAlbumTile: View {
    let primaryTitle: String
    let secondaryTitle: String?
    let coverImagesData: [Data]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width
            ZStack(alignment: .bottomLeading) {
                if let firstData = coverImagesData.first,
                   let uiImage = UIImage(data: firstData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.22)
                        .frame(width: size, height: size)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(.secondarySystemFill))
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: "photo.on.rectangle")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }

                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.18),
                        .black.opacity(0.68)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(width: size, height: size)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(primaryTitle))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.88)

                    if let secondaryTitle {
                        Text(LocalizedStringKey(secondaryTitle))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                .padding(14)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 清單顯示方式（圖片放左邊，右邊顯示名稱）
struct ApplePhotoAlbumListRow: View {
    let primaryTitle: String
    let secondaryTitle: String?
    let coverImagesData: [Data]
    var showsDragHandle: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            Color(.secondarySystemFill)
                .frame(width: 68, height: 68)
                .overlay {
                    if let firstData = coverImagesData.first,
                       let uiImage = UIImage(data: firstData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(1.18)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(primaryTitle))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let secondaryTitle {
                    Text(LocalizedStringKey(secondaryTitle))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct GroupAlbumDropDelegate: DropDelegate {
    let targetGroup: IdolGroup
    let groups: [IdolGroup]
    @Binding var draggingGroupID: UUID?
    let onReorder: ([IdolGroup]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingGroupID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingGroupID,
              draggingID != targetGroup.id,
              let fromIndex = groups.firstIndex(where: { $0.id == draggingID }),
              let toIndex = groups.firstIndex(where: { $0.id == targetGroup.id }) else {
            return
        }
        var updated = groups
        let moved = updated.remove(at: fromIndex)
        updated.insert(moved, at: toIndex)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.22)) {
            onReorder(updated)
        }
    }
}

private struct MemberAlbumDropDelegate: DropDelegate {
    let targetMember: IdolMember
    let members: [IdolMember]
    @Binding var draggingMemberID: UUID?
    let onReorder: ([IdolMember]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingMemberID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingMemberID,
              draggingID != targetMember.id,
              let fromIndex = members.firstIndex(where: { $0.id == draggingID }),
              let toIndex = members.firstIndex(where: { $0.id == targetMember.id }) else {
            return
        }
        var updated = members
        let moved = updated.remove(at: fromIndex)
        updated.insert(moved, at: toIndex)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.22)) {
            onReorder(updated)
        }
    }
}

// MARK: - 4. GroupMembersAlbumView (團體 > 成員 第二層：點開某個團體後顯示該團體旗下的成員相冊)

private struct GroupMembersAlbumView: View {
    let group: IdolGroup
    let allItems: [ChekiItem]

    @Environment(\.modelContext) private var modelContext
    @AppStorage("albumSortMethod") private var sortMethodRaw: String = AlbumSortMethod.custom.rawValue
    @AppStorage("albumDisplayMode") private var displayModeRaw: String = AlbumDisplayMode.grid.rawValue

    @State private var showingQuickCreateSheet: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingCameraScanner: Bool = false
    @State private var showingAlbumPhotosPicker: Bool = false
    @State private var selectedAlbumPhotos: [PhotosPickerItem] = []
    @State private var pendingBatchPhotos: [PhotosPickerItem] = []
    @State private var showingBatchPairingSheet: Bool = false
    @State private var actionTargetMember: IdolMember? = nil

    @State private var showingRenameGroupAlert: Bool = false
    @State private var renamingMember: IdolMember? = nil
    @State private var renameText: String = ""
    @State private var draggingMemberID: UUID? = nil

    private var sortMethod: AlbumSortMethod {
        AlbumSortMethod(rawValue: sortMethodRaw) ?? .custom
    }

    private var displayMode: AlbumDisplayMode {
        AlbumDisplayMode(rawValue: displayModeRaw) ?? .grid
    }

    private var displayedMembers: [IdolMember] {
        switch sortMethod {
        case .name:
            return group.members.sorted {
                $0.stageName.localizedStandardCompare($1.stageName) == .orderedAscending
            }
        case .custom:
            return group.sortedMembers
        }
    }

    private let albumColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            if displayedMembers.isEmpty {
                ContentUnavailableView {
                    Label("此團體尚無成員", systemImage: "person.badge.plus")
                } description: {
                    Text("點擊右上角「+」為 \(group.name) 新增成員相冊。")
                } actions: {
                    Button("新增成員") {
                        showingQuickCreateSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
            } else if displayMode == .grid {
                LazyVGrid(columns: albumColumns, spacing: 12) {
                    ForEach(displayedMembers) { member in
                        groupMemberAlbumEntry(for: member, isList: false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(displayedMembers) { member in
                        groupMemberAlbumEntry(for: member, isList: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(
            isPresented: $showingAlbumPhotosPicker,
            selection: $selectedAlbumPhotos,
            maxSelectionCount: nil,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: selectedAlbumPhotos) { _, newItems in
            guard !newItems.isEmpty else { return }
            pendingBatchPhotos = newItems
            selectedAlbumPhotos = []
            showingBatchPairingSheet = true
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
                    Button {
                        showingQuickCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(.white.opacity(0.22))
                        .frame(width: 0.8, height: 18)

                    Menu {
                        Button {
                            actionTargetMember = displayedMembers.first
                            showingCameraScanner = true
                        } label: {
                            Label(L10n.tr("攝影追加", "撮影して追加"), systemImage: "camera")
                        }

                        Button {
                            actionTargetMember = displayedMembers.first
                            showingAlbumPhotosPicker = true
                        } label: {
                            Label(L10n.tr("從相冊讀入", "アルバムから読み込む"), systemImage: "photo.badge.plus")
                        }

                        Button {
                            renameText = group.name
                            showingRenameGroupAlert = true
                        } label: {
                            Label(L10n.tr("修改團體名", "グループ名を変更"), systemImage: "pencil")
                        }

                        if !displayedMembers.isEmpty {
                            Menu {
                                ForEach(displayedMembers) { member in
                                    Button {
                                        renameText = member.stageName
                                        renamingMember = member
                                    } label: {
                                        Label(member.stageName, systemImage: "pencil")
                                    }
                                }
                            } label: {
                                Label(L10n.tr("修改成員名", "メンバー名を変更"), systemImage: "person.text.rectangle")
                            }
                        }

                        Divider()

                        Menu {
                            ForEach(AlbumSortMethod.allCases) { method in
                                Button {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        sortMethodRaw = method.rawValue
                                    }
                                } label: {
                                    if sortMethod == method {
                                        Label(method.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(method.displayName)
                                    }
                                }
                            }
                        } label: {
                            Label(L10n.tr("排序方法", "並び替え"), systemImage: "arrow.up.arrow.down")
                        }

                        Menu {
                            ForEach(AlbumDisplayMode.allCases) { mode in
                                Button {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        displayModeRaw = mode.rawValue
                                    }
                                } label: {
                                    Label(mode.displayName, systemImage: displayMode == mode ? "checkmark" : mode.iconName)
                                }
                            }
                        } label: {
                            Label(L10n.tr("顯示方式", "表示形式"), systemImage: displayMode.iconName)
                        }

                        Divider()

                        Button {
                            showingSettingsSheet = true
                        } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 34)
                            .contentShape(Rectangle())
                    }
                }
                .darkSystemUnifiedCapsuleContainer()
            }
        }
        .sheet(isPresented: $showingQuickCreateSheet) {
            QuickCreateIdolSheet(defaultGroupName: group.name)
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
        }
        .sheet(isPresented: $showingBatchPairingSheet, onDismiss: {
            pendingBatchPhotos = []
            actionTargetMember = nil
        }) {
            BatchPairingView(initialPickerItems: pendingBatchPhotos, defaultMember: actionTargetMember)
        }
        .fullScreenCover(isPresented: $showingCameraScanner, onDismiss: {
            actionTargetMember = nil
        }) {
            CameraScannerView(defaultMember: actionTargetMember)
        }
        .alert(
            L10n.tr("修改團體名", "グループ名を変更"),
            isPresented: $showingRenameGroupAlert
        ) {
            TextField(L10n.tr("輸入新的團體名稱", "新しいグループ名を入力"), text: $renameText)
            Button(L10n.tr("取消", "キャンセル"), role: .cancel) {}
            Button(L10n.tr("儲存", "保存")) {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    group.name = trimmed
                    try? modelContext.save()
                }
            }
        }
        .alert(
            L10n.tr("修改成員名", "メンバー名を変更"),
            isPresented: Binding(
                get: { renamingMember != nil },
                set: { if !$0 { renamingMember = nil } }
            )
        ) {
            TextField(L10n.tr("輸入新的成員名稱", "新しいメンバー名を入力"), text: $renameText)
            Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                renamingMember = nil
            }
            Button(L10n.tr("儲存", "保存")) {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let member = renamingMember {
                    member.stageName = trimmed
                    try? modelContext.save()
                }
                renamingMember = nil
            }
        }
    }

    @ViewBuilder
    private func groupMemberAlbumEntry(for member: IdolMember, isList: Bool) -> some View {
        let covers = AlbumsRootView.memberCoverImages(for: member, allItems: allItems)
        NavigationLink(value: member) {
            if isList {
                ApplePhotoAlbumListRow(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    coverImagesData: covers,
                    showsDragHandle: sortMethod == .custom
                )
            } else {
                ApplePhotoAlbumTile(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    coverImagesData: covers
                )
            }
        }
        .buttonStyle(.plain)
        .onDrag {
            draggingMemberID = member.id
            return NSItemProvider(object: member.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: MemberAlbumDropDelegate(
                targetMember: member,
                members: displayedMembers,
                draggingMemberID: $draggingMemberID,
                onReorder: { reordered in
                    sortMethodRaw = AlbumSortMethod.custom.rawValue
                    for (idx, item) in reordered.enumerated() {
                        item.sortOrder = idx
                    }
                    try? modelContext.save()
                }
            )
        )
        .contextMenu {
            Button {
                actionTargetMember = member
                showingCameraScanner = true
            } label: {
                Label(L10n.tr("攝影追加", "撮影して追加"), systemImage: "camera")
            }

            Button {
                actionTargetMember = member
                showingAlbumPhotosPicker = true
            } label: {
                Label(L10n.tr("從相冊讀入", "アルバムから読み込む"), systemImage: "photo.badge.plus")
            }

            Divider()

            Button {
                renameText = member.stageName
                renamingMember = member
            } label: {
                Label(L10n.tr("修改成員名", "メンバー名を変更"), systemImage: "pencil")
            }
        }
    }
}

private extension View {
    func darkSystemCircleChrome(size: CGFloat = 36) -> some View {
        self
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.68), in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
            )
            .environment(\.colorScheme, .dark)
    }

    func darkSystemCapsuleChrome(height: CGFloat = 36, horizontalPadding: CGFloat = 14) -> some View {
        self
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(Color.black.opacity(0.68), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
            )
            .environment(\.colorScheme, .dark)
    }

    func darkSystemUnifiedCapsuleContainer() -> some View {
        self
            .background(Color.black.opacity(0.68), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
            )
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - 5. AlbumHeroDetailView (點開相冊後：仿照圖 3 Apple 相簿全幅 Hero 封面 + 支援雙指縮放的相片網格)

struct AlbumHeroDetailView: View {
    let primaryTitle: String
    let secondaryTitle: String?
    let items: [ChekiItem]
    let defaultMember: IdolMember?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var allChekiItems: [ChekiItem]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = true

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var processingItems: [PhotosPickerItem] = []
    @State private var isProcessing: Bool = false

    @State private var isSelectionMode: Bool = false
    @State private var selectionViewID = UUID()
    private var chromeState = NavigationChromeState.shared
    @State private var selectedItemIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingCameraScanner: Bool = false
    @State private var showingBatchPairingSheet: Bool = false
    @State private var showingRenameMemberAlert: Bool = false
    @State private var renameMemberText: String = ""

    @State private var sortAscending: Bool = false
    @State private var filterDualSideOnly: Bool = false

    private static let supportedColumnCounts = [1, 2, 3, 5]
    @State private var columnCount: Int = 5
    @State private var pinchBaselineColumnCount: Int? = nil
    @State private var livePinchScale: CGFloat = 1.0
    @State private var showingQuickCreateMember: Bool = false
    @State private var showingInAppPhotoPickerSheet: Bool = false

    private var validAllChekiItems: [ChekiItem] {
        allChekiItems.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    /// 即時從 SwiftData 查詢目前所在相簿的所有拍立得項目，確保從相簿追加或配對歸檔後立即更新目前所在的相簿
    private var liveItems: [ChekiItem] {
        if let defaultMember {
            return validAllChekiItems.filter { $0.isAssigned(to: defaultMember) }
        } else {
            return validAllChekiItems.filter { $0.isUncategorized }
        }
    }

    private var effectivePrimaryTitle: String {
        if let defaultMember {
            return defaultMember.albumTitle
        }
        return primaryTitle
    }

    private var effectiveSecondaryTitle: String? {
        if defaultMember != nil {
            return nil
        }
        return secondaryTitle
    }

    private var displayedItems: [ChekiItem] {
        let source = liveItems
        let filtered = filterDualSideOnly ? source.filter(\.hasBothSides) : source
        return filtered.sorted {
            sortAscending ? ($0.displayDate < $1.displayDate) : ($0.displayDate > $1.displayDate)
        }
    }

    private var gridSpacing: CGFloat {
        switch columnCount {
        case 1: return 10
        case 2: return 8
        case 3: return 6
        default: return 4
        }
    }

    private var cellCornerRadius: CGFloat {
        switch columnCount {
        case 1: return 12
        case 2: return 10
        case 3: return 7
        default: return 5
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    private var heroCoverItem: ChekiItem? {
        displayedItems.first ?? liveItems.first
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 6) {
                    heroHeaderView
                        .transaction { transaction in
                            transaction.animation = nil
                        }

                    if displayedItems.isEmpty && defaultMember == nil {
                        ContentUnavailableView {
                            Label("尚無拍立得項目", systemImage: "photo.on.rectangle")
                        } description: {
                            Text("點擊右上角「＋」或「⋯」匯入或拍攝拍立得至此相冊。")
                        }
                        .padding(.vertical, 48)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                            ForEach(displayedItems) { item in
                                albumPhotoCell(for: item)
                            }

                            if defaultMember != nil && !isSelectionMode {
                                addFromInAppLibraryCell
                            }
                        }
                        .overlay {
                            if isSelectionMode {
                                ApplePhotosDragSelectOverlay(
                                    itemIDs: displayedItems.map(\.persistentModelID),
                                    columnCount: columnCount,
                                    spacing: gridSpacing,
                                    cellAspectRatio: 1.0,
                                    selectedItemIDs: $selectedItemIDs
                                )
                            }
                        }
                        .padding(.horizontal, columnCount >= 5 ? 6 : 10)
                        .padding(.top, 2)
                        .scaleEffect(livePinchScale, anchor: .top)
                        .animation(.spring(response: 0.50, dampingFraction: 0.86, blendDuration: 0.15), value: columnCount)

                        if displayedItems.isEmpty {
                            ContentUnavailableView {
                                Label(L10n.tr("尚無拍立得項目", "チェキがまだありません"), systemImage: "photo.on.rectangle")
                            } description: {
                                Text(L10n.tr("點擊上方「＋」從 App 內挑選照片加入，或由右上角匯入／拍攝。", "上の「＋」からアプリ内の写真を追加するか、右上から読み込んでください。"))
                            }
                            .padding(.vertical, 28)
                        }
                    }
                }
                .padding(.bottom, isSelectionMode ? 96 : 40)
            }
            .simultaneousGesture(pinchZoomGesture)
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingQuickCreateMember) {
            QuickCreateIdolSheet()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar((isSelectionMode || chromeState.shouldHideMainTabBar) ? .hidden : .visible, for: .tabBar)
        .onChange(of: isSelectionMode) { _, newValue in
            NavigationChromeState.shared.setSelectionMode(newValue, id: selectionViewID)
        }
        .onDisappear {
            NavigationChromeState.shared.setSelectionMode(false, id: selectionViewID)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    if isSelectionMode {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if selectedItemIDs.count == displayedItems.count {
                                selectedItemIDs.removeAll()
                            } else {
                                selectedItemIDs = Set(displayedItems.map(\.persistentModelID))
                            }
                        } label: {
                            Text(selectedItemIDs.count == displayedItems.count ? "取消全選" : "全選")
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false)
                                .darkSystemCapsuleChrome(height: 34)
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 0) {
                            PhotosPicker(
                                selection: $selectedPhotos,
                                maxSelectionCount: nil,
                                matching: .images,
                                preferredItemEncoding: .automatic,
                                photoLibrary: .shared()
                            ) {
                                Image(systemName: "plus")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("從相簿追加拍立得至此相冊")

                            Rectangle()
                                .fill(.white.opacity(0.22))
                                .frame(width: 0.8, height: 18)

                            Menu {
                                Button {
                                    showingCameraScanner = true
                                } label: {
                                    Label(L10n.tr("攝影追加", "撮影して追加"), systemImage: "camera")
                                }

                                PhotosPicker(
                                    selection: $selectedPhotos,
                                    maxSelectionCount: nil,
                                    matching: .images,
                                    photoLibrary: .shared()
                                ) {
                                    Label(L10n.tr("從相冊讀入", "アルバムから読み込む"), systemImage: "photo.badge.plus")
                                }

                                if let defaultMember {
                                    Button {
                                        renameMemberText = defaultMember.stageName
                                        showingRenameMemberAlert = true
                                    } label: {
                                        Label(L10n.tr("修改成員名", "メンバー名を変更"), systemImage: "pencil")
                                    }
                                }

                                Button {
                                    processingItems = []
                                    showingBatchPairingSheet = true
                                } label: {
                                    Label("開啟批次配對工作台（含測試資料）", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                                }

                                Menu {
                                    ForEach(Self.supportedColumnCounts, id: \.self) { count in
                                        Button {
                                            withAnimation(.spring(response: 0.50, dampingFraction: 0.86, blendDuration: 0.15)) {
                                                columnCount = count
                                            }
                                        } label: {
                                            Label("\(count) 欄網格", systemImage: columnCount == count ? "checkmark" : "square.grid.3x3")
                                        }
                                    }
                                } label: {
                                    Label("網格密度", systemImage: "square.grid.3x3")
                                }

                                Menu {
                                    Button {
                                        sortAscending = false
                                    } label: {
                                        Label("由新到舊", systemImage: !sortAscending ? "checkmark" : "arrow.down")
                                    }
                                    Button {
                                        sortAscending = true
                                    } label: {
                                        Label("由舊到新", systemImage: sortAscending ? "checkmark" : "arrow.up")
                                    }
                                    Divider()
                                    Button {
                                        filterDualSideOnly.toggle()
                                    } label: {
                                        Label("僅顯示正反雙面", systemImage: filterDualSideOnly ? "checkmark" : "rectangle.portrait.on.rectangle.portrait")
                                    }
                                } label: {
                                    Label("排序與篩選", systemImage: "line.3.horizontal.decrease")
                                }

                                Divider()

                                Button {
                                    showingSettingsSheet = true
                                } label: {
                                    Label("設定（自動邊界微調）", systemImage: "gearshape")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 34)
                                    .contentShape(Rectangle())
                            }
                        }
                        .darkSystemUnifiedCapsuleContainer()
                        .fixedSize()
                    }

                    if !displayedItems.isEmpty {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.snappy(duration: 0.22)) {
                                isSelectionMode.toggle()
                                if !isSelectionMode {
                                    selectedItemIDs.removeAll()
                                }
                            }
                        } label: {
                            if isSelectionMode {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .darkSystemCircleChrome(size: 34)
                            } else {
                                Text("選取")
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .darkSystemCapsuleChrome(height: 34)
                            }
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .layoutPriority(1)
                    }
                }
            }
        }
        .onChange(of: selectedPhotos) { _, newItems in
            guard !newItems.isEmpty else { return }
            processingItems = newItems
            selectedPhotos = []
            showingBatchPairingSheet = true
        }
        .onChange(of: autoSyncToPhotos) { _, isEnabled in
            guard isEnabled else { return }
            Task {
                await syncCurrentAlbumToPhotosLibrary(forceFullSync: true)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                ApplePhotosSelectionBottomBar(
                    selectedCount: selectedItemIDs.count,
                    onShare: {
                        let selected = displayedItems.filter { selectedItemIDs.contains($0.persistentModelID) }
                        ChekiBatchSharePresenter.share(items: selected)
                    },
                    onDelete: {
                        showDeleteConfirm = true
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            "確定要刪除\(selectedItemIDs.count)張照片嗎？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("刪除 \(selectedItemIDs.count) 張拍立得", role: .destructive) {
                let itemsToDelete = displayedItems.filter { selectedItemIDs.contains($0.persistentModelID) }
                isSelectionMode = false
                selectedItemIDs.removeAll()
                Task { @MainActor in
                    await PhotoLibraryManager.shared.deleteItemsAsync(itemsToDelete, modelContext: modelContext)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                autoSyncToPhotos
                    ? "此操作會將拍立得從 ChekiLens 典藏庫與 iOS 系統相簿中一併刪除。"
                    : "此操作會將拍立得從 ChekiLens 典藏庫移除，且無法復原。"
            )
        }
        .sheet(isPresented: $showingSettingsSheet, onDismiss: {
            if autoSyncToPhotos {
                Task {
                    await syncCurrentAlbumToPhotosLibrary(forceFullSync: true)
                }
            }
        }) {
            SettingsView()
        }
        .sheet(isPresented: $showingBatchPairingSheet, onDismiss: {
            processingItems = []
            if autoSyncToPhotos {
                Task {
                    await syncCurrentAlbumToPhotosLibrary(forceFullSync: false)
                }
            }
        }) {
            BatchPairingView(initialPickerItems: processingItems, defaultMember: defaultMember)
        }
        .fullScreenCover(isPresented: $showingCameraScanner, onDismiss: {
            if autoSyncToPhotos {
                Task {
                    await syncCurrentAlbumToPhotosLibrary(forceFullSync: false)
                }
            }
        }) {
            CameraScannerView(defaultMember: defaultMember)
        }
        .sheet(isPresented: $showingInAppPhotoPickerSheet) {
            if let defaultMember {
                InAppAlbumPhotoPickerSheet(targetMember: defaultMember) { addedItems in
                    if autoSyncToPhotos && !addedItems.isEmpty {
                        Task {
                            await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                                addedItems,
                                modelContext: modelContext,
                                onlyAlbumAndDateIfAlreadySynced: true
                            )
                        }
                    }
                }
            }
        }
        .alert(
            L10n.tr("修改成員名", "メンバー名を変更"),
            isPresented: $showingRenameMemberAlert
        ) {
            TextField(L10n.tr("輸入新的成員名稱", "新しいメンバー名を入力"), text: $renameMemberText)
            Button(L10n.tr("取消", "キャンセル"), role: .cancel) {}
            Button(L10n.tr("儲存", "保存")) {
                let trimmed = renameMemberText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let defaultMember {
                    defaultMember.stageName = trimmed
                    try? modelContext.save()
                }
            }
        }
        .overlay {
            if isProcessing {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView("AI 處理中…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    /// 確保目前所在相簿的所有項目已歸入 `defaultMember`，並在開啟「相簿同步」時同步至 iOS 系統相簿
    @MainActor
    private func syncCurrentAlbumToPhotosLibrary(forceFullSync: Bool) async {
        let currentItems = liveItems
        guard !currentItems.isEmpty else { return }
        await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
            currentItems,
            modelContext: modelContext,
            onlyAlbumAndDateIfAlreadySynced: !forceFullSync
        )
    }

    /// 雙指縮放手勢：縮放期間主圖下方網格即時跟隨雙指縮放，雙指放開時才確認切換欄數並以更順暢緩慢的彈簧動畫過渡
    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBaselineColumnCount == nil {
                    pinchBaselineColumnCount = columnCount
                }
                let rawMag = value.magnification
                let dampedScale: CGFloat
                if rawMag >= 1.0 {
                    dampedScale = 1.0 + min(rawMag - 1.0, 1.2) * 0.32
                } else {
                    dampedScale = 1.0 - min(1.0 - rawMag, 0.55) * 0.32
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    livePinchScale = dampedScale
                }
            }
            .onEnded { value in
                defer { pinchBaselineColumnCount = nil }
                let baseCount = pinchBaselineColumnCount ?? columnCount
                let baseIndex = Self.supportedColumnCounts.firstIndex(of: baseCount) ?? (Self.supportedColumnCounts.count - 1)
                let magnification = value.magnification
                var targetIndex = baseIndex

                if magnification > 1.58 {
                    targetIndex = max(0, baseIndex - 2)
                } else if magnification > 1.15 {
                    targetIndex = max(0, baseIndex - 1)
                } else if magnification < 0.62 {
                    targetIndex = min(Self.supportedColumnCounts.count - 1, baseIndex + 2)
                } else if magnification < 0.86 {
                    targetIndex = min(Self.supportedColumnCounts.count - 1, baseIndex + 1)
                }

                let newCount = Self.supportedColumnCounts[targetIndex]
                if newCount != columnCount {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                withAnimation(.spring(response: 0.50, dampingFraction: 0.86, blendDuration: 0.15)) {
                    columnCount = newCount
                    livePinchScale = 1.0
                }
            }
    }

    private var heroHeaderView: some View {
        ZStack(alignment: .bottomLeading) {
            Color(.secondarySystemBackground)
                .frame(maxWidth: .infinity)
                .frame(height: 390)
                .overlay {
                    if let heroItem = heroCoverItem,
                       let uiImage = ChekiThumbnailCache.shared.image(for: heroItem) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(1.22)
                    } else {
                        LinearGradient(
                            colors: [Color.indigo.opacity(0.8), Color.purple.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .clipped()

            LinearGradient(
                colors: [
                    .black.opacity(0.25),
                    .clear,
                    .black.opacity(0.75)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity)
            .frame(height: 390)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(effectivePrimaryTitle))
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)

                    if let effectiveSecondaryTitle {
                        Text(LocalizedStringKey(effectiveSecondaryTitle))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.stack")
                            .font(.caption)
                        Text("\(displayedItems.count) 個項目")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.top, 2)
                }
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)

                Spacer()

                if let firstItem = displayedItems.first {
                    NavigationLink(value: ChekiDetailRoute(itemID: firstItem.id, scopedItemIDs: displayedItems.map(\.id))) {
                        Image(systemName: "play.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 390)
        .clipped()
        .contentShape(Rectangle())
    }

    private var addFromInAppLibraryCell: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showingInAppPhotoPickerSheet = true
        } label: {
            Color(.secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: columnCount >= 5 ? 20 : 28, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("從 App 內挑選照片加入此相冊", "アプリ内の写真からこのアルバムに追加"))
    }

    @ViewBuilder
    private func albumPhotoCell(for item: ChekiItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.persistentModelID)
        if isSelectionMode {
            AlbumSquareThumbnailCell(item: item, cornerRadius: cellCornerRadius)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.headline)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.9), isSelected ? .blue : .black.opacity(0.35))
                        .padding(6)
                }
                .onTapGesture {
                    if isSelected {
                        selectedItemIDs.remove(item.persistentModelID)
                    } else {
                        selectedItemIDs.insert(item.persistentModelID)
                    }
                }
        } else {
            NavigationLink(value: ChekiDetailRoute(itemID: item.id, scopedItemIDs: displayedItems.map(\.id))) {
                AlbumSquareThumbnailCell(item: item, cornerRadius: cellCornerRadius)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Menu("指派推角成員") {
                    MemberAssignmentMenuContent(item: item) { showingQuickCreateMember = true }
                }
                .menuActionDismissBehavior(.disabled)

                Divider()

                Button(role: .destructive) {
                    Task { @MainActor in
                        await PhotoLibraryManager.shared.deleteItemsAsync([item], modelContext: modelContext)
                    }
                } label: {
                    Label("刪除拍立得", systemImage: "trash")
                }
            }
        }
    }

    @MainActor
    private func processImportedPhotos(_ pickerItems: [PhotosPickerItem]) async {
        isProcessing = true
        defer { isProcessing = false }

        var affectedItems: [ChekiItem] = []

        for pickerItem in pickerItems {
            guard let data = try? await pickerItem.loadTransferable(type: Data.self),
                  let originalUIImage = UIImage(data: data) else { continue }

            let uiImage = originalUIImage.normalizedImage
            let normalizedData = uiImage.jpegData(compressionQuality: 0.92) ?? data

            if let assetId = pickerItem.itemIdentifier,
               !assetId.isEmpty,
               let existingItem = validAllChekiItems.first(where: { $0.frontAssetIdentifier == assetId }) {
                if existingItem.originalFrontImageData == nil {
                    existingItem.originalFrontImageData = normalizedData
                }
                existingItem.idolMember = defaultMember
                await VisionPhotoProcessor.process(existingItem, image: uiImage)
                affectedItems.append(existingItem)
            } else {
                let newItem = ChekiItem(
                    frontImageData: normalizedData,
                    originalFrontImageData: normalizedData,
                    capturedAt: Date(),
                    processingState: .unprocessed,
                    frontAssetIdentifier: pickerItem.itemIdentifier,
                    idolMember: defaultMember
                )
                modelContext.insert(newItem)
                await VisionPhotoProcessor.process(newItem, image: uiImage)
                affectedItems.append(newItem)
            }
        }

        try? modelContext.save()

        if autoSyncToPhotos && !affectedItems.isEmpty {
            await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                affectedItems,
                modelContext: modelContext,
                onlyAlbumAndDateIfAlreadySynced: false
            )
        }
    }
}

// MARK: - InAppAlbumPhotoPickerSheet (從 App 內挑選既有照片加入成員相冊：仿照系統 PHPicker，將 コレクション 改為 相冊，全部支援過濾未分類與雙層多選成員)

private struct InAppAlbumPhotoPickerSheet: View {
    let targetMember: IdolMember
    var onAdded: ([ChekiItem]) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var allChekiItems: [ChekiItem]
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    private enum PickerTab: String, CaseIterable, Identifiable {
        case all
        case albums

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:
                return L10n.tr("全部", "すべて")
            case .albums:
                return L10n.tr("相冊", "アルバム")
            }
        }
    }

    private enum BrowseAlbumScope: Equatable {
        case uncategorized
        case member(UUID)
        case group(UUID)
    }

    @State private var pickerTab: PickerTab = .all
    @State private var searchText: String = ""
    @State private var filterUncategorizedOnly: Bool = false
    @State private var filterMemberIDs: Set<UUID> = []
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var browseAlbumScope: BrowseAlbumScope? = nil

    private let photoGridColumns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    private let albumGridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var validChekiItems: [ChekiItem] {
        allChekiItems.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var groupedMembers: [(group: IdolGroup, members: [IdolMember])] {
        idolGroups.compactMap { group in
            let members = group.members.sorted { $0.sortOrder < $1.sortOrder }
            return members.isEmpty ? nil : (group, members)
        }
    }

    private var ungroupedMembers: [IdolMember] {
        idolMembers.filter { $0.group == nil }
    }

    private var filteredAllTabItems: [ChekiItem] {
        validChekiItems.filter { item in
            guard LibraryView.matchesSearch(item: item, query: searchText, allMembers: idolMembers) else {
                return false
            }
            if !filterUncategorizedOnly && filterMemberIDs.isEmpty {
                return true
            }
            var matched = false
            if filterUncategorizedOnly && item.isUncategorized {
                matched = true
            }
            if !filterMemberIDs.isEmpty {
                let itemMemberIDs = Set(item.assignedMemberIDs)
                if !itemMemberIDs.isDisjoint(with: filterMemberIDs) {
                    matched = true
                }
            }
            return matched
        }
    }

    private var scopedAlbumItems: [ChekiItem] {
        guard let browseAlbumScope else { return [] }
        let baseItems: [ChekiItem]
        switch browseAlbumScope {
        case .uncategorized:
            baseItems = validChekiItems.filter { $0.isUncategorized }
        case .member(let memberID):
            if let member = idolMembers.first(where: { $0.id == memberID }) {
                baseItems = validChekiItems.filter { $0.isAssigned(to: member) }
            } else {
                baseItems = []
            }
        case .group(let groupID):
            if let group = idolGroups.first(where: { $0.id == groupID }) {
                let groupMemberIDs = Set(group.members.map(\.id))
                baseItems = validChekiItems.filter { !Set($0.assignedMemberIDs).isDisjoint(with: groupMemberIDs) }
            } else {
                baseItems = []
            }
        }
        return baseItems.filter {
            LibraryView.matchesSearch(item: $0, query: searchText, allMembers: idolMembers)
        }
    }

    private var scopedAlbumTitle: String {
        guard let browseAlbumScope else { return "" }
        switch browseAlbumScope {
        case .uncategorized:
            return L10n.tr("未分類", "未分類")
        case .member(let memberID):
            return idolMembers.first(where: { $0.id == memberID })?.albumTitle ?? ""
        case .group(let groupID):
            return idolGroups.first(where: { $0.id == groupID })?.name ?? ""
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if pickerTab == .all {
                    filterHeaderBar
                    Divider()
                    photoSelectionGrid(items: filteredAllTabItems)
                } else {
                    if browseAlbumScope != nil {
                        albumDrilldownHeaderBar
                        Divider()
                        photoSelectionGrid(items: scopedAlbumItems)
                    } else {
                        albumsBrowserGrid
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.tr("搜尋照片、成員、團體或 #標籤", "写真、メンバー、グループ、#タグを検索")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "キャンセル")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $pickerTab) {
                        ForEach(PickerTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        commitPickedItems()
                    } label: {
                        Text(selectedItemIDs.isEmpty ? L10n.tr("加入", "追加") : L10n.tr("加入(\(selectedItemIDs.count))", "追加(\(selectedItemIDs.count))"))
                            .fontWeight(.semibold)
                    }
                    .disabled(selectedItemIDs.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Text(
                        selectedItemIDs.isEmpty
                            ? L10n.tr("選擇要加入「\(targetMember.stageName)」的拍立得", "「\(targetMember.stageName)」に追加するチェキを選択")
                            : L10n.tr("已選擇 \(selectedItemIDs.count) 張拍立得", "\(selectedItemIDs.count)枚のチェキを選択中")
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .applyAppAppearanceAndLocale()
    }

    private var filterHeaderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy(duration: 0.18)) {
                        filterUncategorizedOnly.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: filterUncategorizedOnly ? "checkmark.circle.fill" : "tray")
                            .font(.caption.weight(.semibold))
                        Text(L10n.tr("未分類", "未分類"))
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(filterUncategorizedOnly ? .white : .primary)
                    .background(
                        filterUncategorizedOnly ? Color.accentColor : Color(.secondarySystemFill),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(groupedMembers, id: \.group.id) { entry in
                        Menu(entry.group.name) {
                            ForEach(entry.members) { member in
                                Button {
                                    toggleFilterMember(member.id)
                                } label: {
                                    if filterMemberIDs.contains(member.id) {
                                        Label(member.stageName, systemImage: "checkmark")
                                    } else {
                                        Text(member.stageName)
                                    }
                                }
                            }
                        }
                        .menuActionDismissBehavior(.disabled)
                    }

                    if !ungroupedMembers.isEmpty {
                        Section(L10n.tr("未分組", "グループなし")) {
                            ForEach(ungroupedMembers) { member in
                                Button {
                                    toggleFilterMember(member.id)
                                } label: {
                                    if filterMemberIDs.contains(member.id) {
                                        Label(member.stageName, systemImage: "checkmark")
                                    } else {
                                        Text(member.stageName)
                                    }
                                }
                            }
                        }
                    }

                    if !filterMemberIDs.isEmpty {
                        Divider()
                        Button(role: .destructive) {
                            filterMemberIDs.removeAll()
                        } label: {
                            Label(L10n.tr("清除成員過濾", "メンバー絞り込みを解除"), systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.2")
                            .font(.caption.weight(.semibold))
                        Text(
                            filterMemberIDs.isEmpty
                                ? L10n.tr("選成員", "メンバーを選択")
                                : L10n.tr("選成員 (\(filterMemberIDs.count))", "メンバー (\(filterMemberIDs.count))")
                        )
                        .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(!filterMemberIDs.isEmpty ? .white : .primary)
                    .background(
                        !filterMemberIDs.isEmpty ? Color.accentColor : Color(.secondarySystemFill),
                        in: Capsule()
                    )
                }
                .menuActionDismissBehavior(.disabled)

                if filterUncategorizedOnly || !filterMemberIDs.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            filterUncategorizedOnly = false
                            filterMemberIDs.removeAll()
                        }
                    } label: {
                        Text(L10n.tr("重設", "リセット"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var albumDrilldownHeaderBar: some View {
        HStack {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    browseAlbumScope = nil
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.tr("返回相冊", "アルバム一覧"))
                        .font(.subheadline.weight(.medium))
                }
            }
            Spacer()
            Text(scopedAlbumTitle)
                .font(.subheadline.weight(.bold))
            Spacer()
            Color.clear.frame(width: 68, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func photoSelectionGrid(items: [ChekiItem]) -> some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("沒有符合條件的拍立得", "条件に一致するチェキがありません"), systemImage: "photo.on.rectangle")
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: photoGridColumns, spacing: 4) {
                    ForEach(items) { item in
                        let isSelected = selectedItemIDs.contains(item.id)
                        let alreadyInAlbum = item.isAssigned(to: targetMember)
                        AlbumSquareThumbnailCell(item: item, cornerRadius: 6)
                            .overlay(alignment: .topLeading) {
                                if alreadyInAlbum {
                                    Text(L10n.tr("已在相冊", "追加済"))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.black.opacity(0.6), in: Capsule())
                                        .padding(5)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(
                                        isSelected ? .white : .white.opacity(0.9),
                                        isSelected ? .blue : .black.opacity(0.35)
                                    )
                                    .padding(6)
                            }
                            .scaleEffect(isSelected ? 0.96 : 1.0)
                            .animation(.snappy(duration: 0.14), value: isSelected)
                            .onTapGesture {
                                UISelectionFeedbackGenerator().selectionChanged()
                                if isSelected {
                                    selectedItemIDs.remove(item.id)
                                } else {
                                    selectedItemIDs.insert(item.id)
                                }
                            }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
    }

    private var albumsBrowserGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let uncategorized = validChekiItems.filter { $0.isUncategorized }
                if !uncategorized.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("未分類", "未分類"))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: albumGridColumns, spacing: 12) {
                            Button {
                                browseAlbumScope = .uncategorized
                            } label: {
                                ApplePhotoAlbumTile(
                                    primaryTitle: L10n.tr("未分類", "未分類"),
                                    secondaryTitle: "\(uncategorized.count)",
                                    coverImagesData: Array(uncategorized.compactMap(\.frontImageData).prefix(1))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if !idolMembers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("成員相冊", "メンバーアルバム"))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: albumGridColumns, spacing: 12) {
                            ForEach(idolMembers) { member in
                                Button {
                                    browseAlbumScope = .member(member.id)
                                } label: {
                                    ApplePhotoAlbumTile(
                                        primaryTitle: member.albumTitle,
                                        secondaryTitle: nil,
                                        coverImagesData: AlbumsRootView.memberCoverImages(for: member, allItems: validChekiItems)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if !idolGroups.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("團體相冊", "グループアルバム"))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: albumGridColumns, spacing: 12) {
                            ForEach(idolGroups) { group in
                                Button {
                                    browseAlbumScope = .group(group.id)
                                } label: {
                                    ApplePhotoAlbumTile(
                                        primaryTitle: group.name,
                                        secondaryTitle: nil,
                                        coverImagesData: AlbumsRootView.groupCoverImages(for: group, allItems: validChekiItems)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 14)
        }
    }

    private func toggleFilterMember(_ id: UUID) {
        UISelectionFeedbackGenerator().selectionChanged()
        if filterMemberIDs.contains(id) {
            filterMemberIDs.remove(id)
        } else {
            filterMemberIDs.insert(id)
        }
    }

    private func commitPickedItems() {
        let itemsToUpdate = validChekiItems.filter { selectedItemIDs.contains($0.id) }
        guard !itemsToUpdate.isEmpty else {
            dismiss()
            return
        }
        for item in itemsToUpdate {
            if !item.isAssigned(to: targetMember) {
                item.toggleAssignedMember(targetMember, allMembers: idolMembers)
            }
        }
        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onAdded(itemsToUpdate)
        dismiss()
    }
}

private final class ChekiThumbnailCache: @unchecked Sendable {
    static let shared = ChekiThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(for item: ChekiItem) -> UIImage? {
        guard !item.isDeleted, item.modelContext != nil, let data = item.frontImageData else {
            return nil
        }
        let key = "\(item.id.uuidString)-\(data.count)-\(data.hashValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = UIImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}

private struct AlbumSquareThumbnailCell: View {
    let item: ChekiItem
    var cornerRadius: CGFloat = 5

    var body: some View {
        let isValid = !item.isDeleted && item.modelContext != nil
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if isValid,
                   let uiImage = ChekiThumbnailCache.shared.image(for: item) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.22)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                ChekiWatermarkOverlayView(compact: true)
            }
            .overlay(alignment: .topTrailing) {
                if isValid && item.hasBothSides {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 6. LibrarySearchView (底部右側圓形「🔍 搜尋」Tab)

struct LibrarySearchView: View {

    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    @State private var searchText: String = ""
    @State private var showingSettingsSheet: Bool = false
    private var chromeState = NavigationChromeState.shared

    private let twoColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private let threeColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var validChekiItems: [ChekiItem] {
        chekiItems.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var filteredItems: [ChekiItem] {
        validChekiItems.filter { LibraryView.matchesSearch(item: $0, query: searchText, allMembers: idolMembers) }
    }

    private var availableHashtags: [String] {
        var counts: [String: Int] = [:]
        for item in validChekiItems {
            for rawTag in item.memo?.hashtags ?? [] {
                let normalized = rawTag.hasPrefix("#") ? String(rawTag.dropFirst()) : rawTag
                counts[normalized, default: 0] += 1
            }
        }
        return counts.keys.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if searchText.isEmpty {
                        if !availableHashtags.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("熱門 #標籤")
                                    .font(.headline)
                                    .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(availableHashtags, id: \.self) { tag in
                                            Button {
                                                searchText = "#\(tag)"
                                            } label: {
                                                Text("#\(tag)")
                                                    .font(.subheadline.weight(.medium))
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 7)
                                                    .background(
                                                        Color(.secondarySystemGroupedBackground),
                                                        in: Capsule()
                                                    )
                                                    .foregroundStyle(.blue)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        if !idolMembers.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("成員相冊")
                                    .font(.headline)
                                    .padding(.horizontal, 16)

                                LazyVGrid(columns: twoColumns, spacing: 12) {
                                    ForEach(idolMembers) { member in
                                        NavigationLink(value: member) {
                                            ApplePhotoAlbumTile(
                                                primaryTitle: member.albumTitle,
                                                secondaryTitle: nil,
                                                coverImagesData: AlbumsRootView.memberCoverImages(for: member, allItems: validChekiItems)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    } else if filteredItems.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 48)
                    } else {
                        Text("\(filteredItems.count) 個項目")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: threeColumns, spacing: 10) {
                            ForEach(filteredItems) { item in
                                NavigationLink(value: ChekiDetailRoute(itemID: item.id, scopedItemIDs: filteredItems.map(\.id))) {
                                    AppleLibraryPhotoCell(item: item, cornerRadius: 9)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Color(.systemBackground))
            .navigationTitle("搜尋")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(chromeState.shouldHideMainTabBar ? .hidden : .visible, for: .tabBar)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜尋成員、團體、活動或 #標籤"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingSettingsSheet = true
                        } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingSettingsSheet) {
                SettingsView()
            }
            .navigationDestination(for: ChekiDetailRoute.self) { route in
                ChekiDetailView(itemID: route.itemID, scopedItemIDs: route.scopedItemIDs)
                    .toolbar(.hidden, for: .tabBar)
            }
            .navigationDestination(for: IdolMember.self) { member in
                AlbumHeroDetailView(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    items: validChekiItems.filter { $0.isAssigned(to: member) },
                    defaultMember: member
                )
            }
        }
    }
}

// MARK: - QuickCreateIdolSheet (快速新增團體 / 成員)

struct QuickCreateIdolSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var groups: [IdolGroup]

    @State private var stageName: String = ""
    @State private var groupName: String
    @State private var tagsText: String = ""

    init(defaultGroupName: String = "") {
        _groupName = State(initialValue: defaultGroupName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("推角成員資訊") {
                    TextField("姓名", text: $stageName)
                    TextField("團體", text: $groupName)
                    TextField("標籤", text: $tagsText)
                }

                if !groups.isEmpty {
                    Section("快速帶入現有團體") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(groups) { group in
                                    Button(group.name) {
                                        groupName = group.name
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("新增成員與團體")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        saveMemberAndGroup()
                        dismiss()
                    }
                    .disabled(stageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .applyAppAppearanceAndLocale()
    }

    private func saveMemberAndGroup() {
        let trimmedGroup = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMember = stageName.trimmingCharacters(in: .whitespacesAndNewlines)

        var targetGroup: IdolGroup?
        if !trimmedGroup.isEmpty {
            if let existing = groups.first(where: { $0.name == trimmedGroup }) {
                targetGroup = existing
            } else {
                let newGroup = IdolGroup(name: trimmedGroup, sortOrder: groups.count)
                modelContext.insert(newGroup)
                targetGroup = newGroup
            }
        }

        if !trimmedMember.isEmpty {
            let parsedTags = tagsText
                .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "、" })
                .map { String($0).replacingOccurrences(of: "#", with: "") }
                .filter { !$0.isEmpty }

            let newMember = IdolMember(
                stageName: trimmedMember,
                tags: parsedTags,
                sortOrder: targetGroup?.members.count ?? 0,
                group: targetGroup
            )
            modelContext.insert(newMember)
        }

        try? modelContext.save()
    }
}

// MARK: - Shared Vision Processor & Date Formatter

private enum VisionPhotoProcessor {
    static func process(_ item: ChekiItem, image: UIImage) async {
        guard let cgImage = image.cgImage else { return }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let insetRatio = UserDefaults.standard.double(forKey: "defaultBorderInsetPercentage") / 100.0

        do {
            let manager = VisionManager()
            let detection = try await manager.detectQuad(in: cgImage, imageSize: imageSize)
            let adjustedCorners = await manager.applyBorderInset(
                corners: detection.corners,
                imageSize: imageSize,
                ratio: insetRatio
            )
            let adjustedDetection = DetectionResult(
                corners: adjustedCorners,
                method: detection.method,
                confidence: detection.confidence,
                imageSize: imageSize
            )
            let cropResult = try await manager.perspectiveCorrect(
                image: cgImage,
                corners: adjustedCorners,
                detection: adjustedDetection,
                format: .auto
            )
            var recognizedDate = await manager.recognizeDate(from: cropResult.cgImage)?.date
            if recognizedDate == nil {
                recognizedDate = await manager.recognizeDate(from: cgImage)?.date
            }
            let resolvedFormat = FilmFormat.resolvedConcreteFormat(
                preferred: .auto,
                specName: cropResult.filmSpecification?.format.rawValue,
                outputSize: cropResult.outputSize
            )
            await MainActor.run {
                if item.originalFrontImageData == nil {
                    item.originalFrontImageData = image.jpegData(compressionQuality: 0.92)
                }
                item.frontImageData = UIImage(cgImage: cropResult.cgImage).jpegData(compressionQuality: 0.92)
                item.perspectivePointsJSON = ChekiItem.encodeNormalizedCorners(adjustedCorners, imageSize: imageSize)
                item.borderInsetRatio = insetRatio
                item.filmFormat = resolvedFormat
                item.detectedAspectRatio = resolvedFormat.aspectRatio
                if let recognizedDate {
                    let merged = ChekiItem.mergeRecognizedDate(recognizedDate, into: item.capturedAt)
                    item.ocrDate = merged
                    item.capturedAt = merged
                }
                item.processingState = .completed
            }
        } catch {
            let manager = VisionManager()
            let recognizedDate = await manager.recognizeDate(from: cgImage)?.date
            await MainActor.run {
                if let recognizedDate {
                    let merged = ChekiItem.mergeRecognizedDate(recognizedDate, into: item.capturedAt)
                    item.ocrDate = merged
                    item.capturedAt = merged
                }
                item.processingState = .completed
            }
        }
    }
}

private final class ChekiDateFormatter: Sendable {
    static let shared = ChekiDateFormatter()

    func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

// MARK: - 7. Apple Photos 原生風格選取底部列（左圓分享、中選取張數、右圓刪除）與滑動多選手勢

private struct ApplePhotosSelectionBottomBar: View {
    let selectedCount: Int
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            // 左下圓形毛玻璃分享按鈕
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)
            .opacity(selectedCount == 0 ? 0.42 : 1.0)
            .accessibilityLabel("分享已選取的拍立得")

            Spacer()

            // 中央已選取張數狀態文字（對齊 Apple 原生相簿「2枚の写真を選択 / 已選取 N 張照片」）
            Text(selectedCount == 0 ? "選擇項目" : "已選取 \(selectedCount) 張照片")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.16), value: selectedCount)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)

            Spacer()

            // 右下圓形毛玻璃刪除按鈕
            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)
            .opacity(selectedCount == 0 ? 0.42 : 1.0)
            .accessibilityLabel("刪除已選取的拍立得")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [
                    Color(.systemBackground).opacity(0.0),
                    Color(.systemBackground).opacity(0.75),
                    Color(.systemBackground).opacity(0.94)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// 仿照 Apple 原生相簿 (Photos.app) 的拖選多選手勢覆蓋層：
/// - 單指點擊：切換單張拍立得的選取狀態
/// - 單指橫向/斜向滑動：自動鎖定當前捲軸並進入連續範圍拖選（可接著跨越多列上下滑動批次勾選或取消勾選）
/// - 單指垂直滑動：不攔截手勢，交由外層 `ScrollView` 原生順暢捲動
private struct ApplePhotosDragSelectOverlay: UIViewRepresentable {
    let itemIDs: [PersistentIdentifier]
    let columnCount: Int
    let spacing: CGFloat
    let cellAspectRatio: CGFloat
    @Binding var selectedItemIDs: Set<PersistentIdentifier>

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        panGesture.maximumNumberOfTouches = 1
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = context.coordinator
        view.addGestureRecognizer(panGesture)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ApplePhotosDragSelectOverlay

        private var dragStartIndex: Int?
        private var lastDraggedIndex: Int?
        private var dragIsSelecting: Bool = true
        private var dragBaselineSelection: Set<PersistentIdentifier> = []
        private let feedbackGenerator = UISelectionFeedbackGenerator()

        init(parent: ApplePhotosDragSelectOverlay) {
            self.parent = parent
        }

        private func itemIndex(at point: CGPoint, in boundsSize: CGSize, clampToBounds: Bool) -> Int? {
            let count = parent.itemIDs.count
            guard count > 0, boundsSize.width > 1 else { return nil }

            let cols = max(1, parent.columnCount)
            let spacing = parent.spacing
            let totalHSpacing = CGFloat(cols - 1) * spacing
            let cellWidth = max(1, (boundsSize.width - totalHSpacing) / CGFloat(cols))
            let cellHeight = max(1, cellWidth / max(0.1, parent.cellAspectRatio))

            let strideX = cellWidth + spacing
            let strideY = cellHeight + spacing

            if !clampToBounds {
                guard point.x >= 0, point.x <= boundsSize.width, point.y >= 0 else { return nil }
                let col = min(max(0, Int(floor(point.x / strideX))), cols - 1)
                let row = Int(floor(point.y / strideY))
                let idx = row * cols + col
                return (idx >= 0 && idx < count) ? idx : nil
            } else {
                let clampedX = min(max(0, point.x), boundsSize.width - 0.01)
                let clampedY = max(0, point.y)
                let col = min(max(0, Int(floor(clampedX / strideX))), cols - 1)
                let row = max(0, Int(floor(clampedY / strideY)))
                let idx = row * cols + col
                return min(max(0, idx), count - 1)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let view = gesture.view,
                  let index = itemIndex(at: gesture.location(in: view), in: view.bounds.size, clampToBounds: false) else {
                return
            }
            let id = parent.itemIDs[index]
            feedbackGenerator.selectionChanged()
            if parent.selectedItemIDs.contains(id) {
                parent.selectedItemIDs.remove(id)
            } else {
                parent.selectedItemIDs.insert(id)
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let boundsSize = view.bounds.size

            switch gesture.state {
            case .began:
                let currentPoint = gesture.location(in: view)
                let translation = gesture.translation(in: view)
                let touchDownPoint = CGPoint(
                    x: currentPoint.x - translation.x,
                    y: currentPoint.y - translation.y
                )
                guard let startIdx = itemIndex(at: touchDownPoint, in: boundsSize, clampToBounds: true) else {
                    return
                }
                dragStartIndex = startIdx
                lastDraggedIndex = nil
                let startID = parent.itemIDs[startIdx]
                dragIsSelecting = !parent.selectedItemIDs.contains(startID)
                dragBaselineSelection = parent.selectedItemIDs
                feedbackGenerator.prepare()
                applyDragSelection(at: currentPoint, in: boundsSize)

            case .changed:
                applyDragSelection(at: gesture.location(in: view), in: boundsSize)

            case .ended, .cancelled, .failed:
                dragStartIndex = nil
                lastDraggedIndex = nil
                dragBaselineSelection = []

            default:
                break
            }
        }

        private func applyDragSelection(at point: CGPoint, in boundsSize: CGSize) {
            guard let startIdx = dragStartIndex,
                  let currentIdx = itemIndex(at: point, in: boundsSize, clampToBounds: true) else {
                return
            }
            guard currentIdx != lastDraggedIndex else { return }
            lastDraggedIndex = currentIdx

            let lower = min(startIdx, currentIdx)
            let upper = max(startIdx, currentIdx)
            var updated = dragBaselineSelection

            for i in lower...upper where parent.itemIDs.indices.contains(i) {
                let id = parent.itemIDs[i]
                if dragIsSelecting {
                    updated.insert(id)
                } else {
                    updated.remove(id)
                }
            }

            if updated != parent.selectedItemIDs {
                parent.selectedItemIDs = updated
                feedbackGenerator.selectionChanged()
                feedbackGenerator.prepare()
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else {
                return true
            }
            let velocity = pan.velocity(in: view)
            // 橫向或斜向滑動時啟動拖選多選；純垂直滑動時讓給 ScrollView 原生捲動
            return abs(velocity.x) >= abs(velocity.y) * 0.55
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // 當拖選多選手勢一旦以橫向滑動啟動，阻止外層 UIScrollView 搶走手勢，讓使用者可接著上下跨列拖選
            if otherGestureRecognizer is UIPanGestureRecognizer,
               otherGestureRecognizer.view is UIScrollView {
                return true
            }
            return false
        }
    }
}

@MainActor
private enum ChekiBatchSharePresenter {
    static func share(items: [ChekiItem]) {
        guard !items.isEmpty else { return }
        StoreKitManager.shared.refreshDailyFreeQuotaIfNeeded()
        let isPro = PhotoLibraryManager.isProLifetimeUnlocked
        let canUseDailyFreeQuota = !isPro && StoreKitManager.shared.hasDailyFreeQuotaAvailable && items.count == 1
        let shouldExportFullResWithoutWatermark = isPro || canUseDailyFreeQuota

        var shareObjects: [Any] = []
        for item in items {
            if let frontData = item.frontImageData,
               let frontUI = UIImage(data: frontData) {
                shareObjects.append(
                    shouldExportFullResWithoutWatermark
                        ? frontUI
                        : ChekiWatermarkRenderer.applyWatermarkIfNeeded(to: frontUI, downscaleForSNS: true)
                )
            }
            if let backData = item.backImageData,
               let backUI = UIImage(data: backData) {
                shareObjects.append(
                    shouldExportFullResWithoutWatermark
                        ? backUI
                        : ChekiWatermarkRenderer.applyWatermarkIfNeeded(to: backUI, downscaleForSNS: true)
                )
            }
        }
        guard !shareObjects.isEmpty else { return }

        let activityVC = UIActivityViewController(activityItems: shareObjects, applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else { return }
            Task { @MainActor in
                if canUseDailyFreeQuota {
                    StoreKitManager.shared.consumeDailyFreeQuotaIfAvailable()
                }
            }
        }

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           var topVC = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController {
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: 44, y: topVC.view.bounds.height - 60, width: 48, height: 48)
            }
            topVC.present(activityVC, animated: true)
        }
    }
}

// MARK: - Previews

#Preview("全部 (Apple Photos ライブラリ)") {
    LibraryView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}

#Preview("相冊 (Apple Photos アルバム)") {
    AlbumsRootView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}
