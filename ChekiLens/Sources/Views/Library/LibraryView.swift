import SwiftUI
import SwiftData
import PhotosUI
import UIKit

// MARK: - Album Hierarchy Mode (相冊頂部分段控制：團體 vs 成員)

enum AlbumHierarchyMode: String, CaseIterable, Identifiable {
    case groups = "團體"
    case members = "成員"

    var id: String { rawValue }
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
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = false

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var processingItems: [PhotosPickerItem] = []
    @State private var isProcessing: Bool = false

    @State private var isSelectionMode: Bool = false
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

    private var displayedItems: [ChekiItem] {
        let filtered = filterDualSideOnly ? chekiItems.filter(\.hasBothSides) : chekiItems
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

    static func matchesSearch(item: ChekiItem, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let normalized = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed

        if let member = item.idolMember {
            if member.stageName.localizedCaseInsensitiveContains(normalized) { return true }
            if let groupName = member.group?.name,
               groupName.localizedCaseInsensitiveContains(normalized) { return true }
            if member.tags.contains(where: { $0.localizedCaseInsensitiveContains(normalized) }) { return true }
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

                if chekiItems.isEmpty {
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
            .toolbar(isSelectionMode ? .hidden : .visible, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionBottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .confirmationDialog(
                "確定要刪除選取的 \(selectedItemIDs.count) 張拍立得嗎？",
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
                            chekiItems,
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
                            chekiItems,
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
                        chekiItems,
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
            .navigationDestination(for: ChekiItem.self) { item in
                ChekiDetailView(item: item)
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
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showingCameraScanner = true
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
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
                            .foregroundStyle(.blue)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
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
                                        systemPhotoSeedAlertMessage = "已成功將 \(count) 張帶封面手寫日期的拍立得相片寫入 iOS 原生相簿 (Photos.app)。\n\n現在請點選右上角「＋」從系統相簿選取相片，即可實測導入與自動日期判斷！"
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
                            .foregroundStyle(.blue)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
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
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(
                                    Circle()
                                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
                                )
                        } else {
                            Text("選取")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.blue)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(.ultraThinMaterial, in: Capsule())
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
            NavigationLink(value: item) {
                AppleLibraryPhotoCell(item: item, cornerRadius: cornerRadius)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Menu {
                    Button {
                        item.idolMember = nil
                        try? modelContext.save()
                        if autoSyncToPhotos {
                            Task {
                                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                                    [item],
                                    modelContext: modelContext
                                )
                            }
                        }
                    } label: {
                        Label("設為未分類", systemImage: "tray")
                    }
                    ForEach(idolMembers) { member in
                        Button {
                            item.idolMember = member
                            try? modelContext.save()
                            if autoSyncToPhotos {
                                Task {
                                    await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                                        [item],
                                        modelContext: modelContext
                                    )
                                }
                            }
                        } label: {
                            Text(member.albumTitle)
                        }
                    }
                } label: {
                    Label("指派推角成員", systemImage: "person.crop.circle.badge.plus")
                }

                Divider()

                Button(role: .destructive) {
                    PhotoLibraryManager.shared.deleteItems([item], modelContext: modelContext)
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
        let itemsToDelete = chekiItems.filter { selectedItemIDs.contains($0.persistentModelID) }
        PhotoLibraryManager.shared.deleteItems(itemsToDelete, modelContext: modelContext)
        withAnimation {
            isSelectionMode = false
            selectedItemIDs.removeAll()
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
               let existingItem = chekiItems.first(where: { $0.frontAssetIdentifier == assetId }) {
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
        ZStack(alignment: .topTrailing) {
            if let data = item.frontImageData,
               let uiImage = UIImage(data: data) {
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

            if item.hasBothSides {
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

    @State private var hierarchyMode: AlbumHierarchyMode = .groups
    @State private var showingQuickCreateSheet: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingBatchPairingSheet: Bool = false

    private let albumColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var uncategorizedItems: [ChekiItem] {
        chekiItems.filter { $0.idolMember == nil }
    }

    /// 取得所有成員（依團體順序與成員順序排列，確保在「成員」模式下完整展開所有團體的成員）
    private var allExpandedMembers: [IdolMember] {
        var result: [IdolMember] = []
        var seenIDs = Set<UUID>()

        for group in idolGroups {
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
        return result
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
            .sheet(isPresented: $showingQuickCreateSheet) {
                QuickCreateIdolSheet()
            }
            .sheet(isPresented: $showingSettingsSheet) {
                SettingsView()
            }
            .sheet(isPresented: $showingBatchPairingSheet) {
                BatchPairingView()
            }
            .navigationDestination(for: IdolGroup.self) { group in
                GroupMembersAlbumView(group: group, allItems: chekiItems)
            }
            .navigationDestination(for: IdolMember.self) { member in
                AlbumHeroDetailView(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    items: chekiItems.filter { $0.idolMember?.id == member.id },
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
            .navigationDestination(for: ChekiItem.self) { item in
                ChekiDetailView(item: item)
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

                HStack(spacing: 8) {
                    Button {
                        showingQuickCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("新增團體或成員相冊")

                    Menu {
                        Button {
                            showingBatchPairingSheet = true
                        } label: {
                            Label("批次配對工作台（含測試資料）", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
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

                        Divider()

                        Button {
                            showingSettingsSheet = true
                        } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("更多選項與設定")
                }
            }

            // 頂部「團體 | 成員」原地切換（點擊「成員」直接在此頁面展開所有成員相冊）
            Picker("相冊檢視階層", selection: $hierarchyMode.animation(.snappy(duration: 0.22))) {
                ForEach(AlbumHierarchyMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // MARK: - 團體相冊網格（基本相簿構造：團體 > 成員）

    @ViewBuilder
    private var groupsAlbumGrid: some View {
        if idolGroups.isEmpty && uncategorizedItems.isEmpty {
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
        } else {
            LazyVGrid(columns: albumColumns, spacing: 12) {
                ForEach(idolGroups) { group in
                    NavigationLink(value: group) {
                        ApplePhotoAlbumTile(
                            primaryTitle: group.name,
                            secondaryTitle: nil,
                            coverImagesData: Self.groupCoverImages(for: group)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !uncategorizedItems.isEmpty {
                    NavigationLink(value: UncategorizedAlbumRoute()) {
                        ApplePhotoAlbumTile(
                            primaryTitle: "未分類",
                            secondaryTitle: nil,
                            coverImagesData: uncategorizedItems.compactMap(\.frontImageData)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 成員相冊網格（無視團體階層，直接在原本頁面展開所有成員相冊）

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
        } else {
            LazyVGrid(columns: albumColumns, spacing: 12) {
                ForEach(allExpandedMembers) { member in
                    NavigationLink(value: member) {
                        ApplePhotoAlbumTile(
                            primaryTitle: member.albumTitle,
                            secondaryTitle: nil,
                            coverImagesData: Self.memberCoverImages(for: member)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !uncategorizedItems.isEmpty {
                    NavigationLink(value: UncategorizedAlbumRoute()) {
                        ApplePhotoAlbumTile(
                            primaryTitle: "未分類",
                            secondaryTitle: nil,
                            coverImagesData: uncategorizedItems.compactMap(\.frontImageData)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    static func groupCoverImages(for group: IdolGroup) -> [Data] {
        var result: [Data] = []
        for member in group.sortedMembers {
            if let latest = member.latestCheki?.frontImageData {
                result.append(latest)
            }
        }
        return result
    }

    static func memberCoverImages(for member: IdolMember) -> [Data] {
        if let latest = member.latestCheki?.frontImageData {
            return [latest]
        }
        return []
    }
}

// MARK: - 3. ApplePhotoAlbumTile (Apple 相簿 1:1 圓角滿版相冊磚，嚴格裁切點擊邊界)

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
                    Text(primaryTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.88)

                    if let secondaryTitle {
                        Text(secondaryTitle)
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

// MARK: - 4. GroupMembersAlbumView (團體 > 成員 第二層：點開某個團體後顯示該團體旗下的成員相冊)

private struct GroupMembersAlbumView: View {
    let group: IdolGroup
    let allItems: [ChekiItem]

    @State private var showingQuickCreateSheet: Bool = false
    @State private var showingSettingsSheet: Bool = false

    private let albumColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            if group.sortedMembers.isEmpty {
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
            } else {
                LazyVGrid(columns: albumColumns, spacing: 12) {
                    ForEach(group.sortedMembers) { member in
                        NavigationLink(value: member) {
                            ApplePhotoAlbumTile(
                                primaryTitle: member.albumTitle,
                                secondaryTitle: nil,
                                coverImagesData: AlbumsRootView.memberCoverImages(for: member)
                            )
                        }
                        .buttonStyle(.plain)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showingQuickCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }

                    Menu {
                        Button {
                            showingQuickCreateSheet = true
                        } label: {
                            Label("新增成員", systemImage: "person.badge.plus")
                        }

                        Divider()

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
        }
        .sheet(isPresented: $showingQuickCreateSheet) {
            QuickCreateIdolSheet(defaultGroupName: group.name)
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
        }
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
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = false

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var processingItems: [PhotosPickerItem] = []
    @State private var isProcessing: Bool = false

    @State private var isSelectionMode: Bool = false
    @State private var selectedItemIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingCameraScanner: Bool = false
    @State private var showingBatchPairingSheet: Bool = false

    @State private var sortAscending: Bool = false
    @State private var filterDualSideOnly: Bool = false

    private static let supportedColumnCounts = [1, 2, 3, 5]
    @State private var columnCount: Int = 5
    @State private var pinchBaselineColumnCount: Int? = nil

    /// 即時從 SwiftData 查詢目前所在相簿的所有拍立得項目，確保從相簿追加或配對歸檔後立即更新目前所在的相簿
    private var liveItems: [ChekiItem] {
        if let defaultMember {
            return allChekiItems.filter { $0.idolMember?.id == defaultMember.id }
        } else {
            return allChekiItems.filter { $0.idolMember == nil }
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

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    private var heroCoverData: Data? {
        displayedItems.first?.frontImageData ?? liveItems.first?.frontImageData ?? items.first?.frontImageData
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                heroHeaderView

                if displayedItems.isEmpty {
                    ContentUnavailableView {
                        Label("尚無拍立得項目", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("點擊右上角「＋」或「⋯」匯入或拍攝拍立得至此相冊。")
                    }
                    .padding(.vertical, 48)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(displayedItems) { item in
                            albumPhotoCell(for: item)
                        }
                    }
                    .overlay {
                        if isSelectionMode {
                            ApplePhotosDragSelectOverlay(
                                itemIDs: displayedItems.map(\.persistentModelID),
                                columnCount: columnCount,
                                spacing: 2,
                                cellAspectRatio: 1.0,
                                selectedItemIDs: $selectedItemIDs
                            )
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: columnCount)
                }
            }
            .padding(.bottom, isSelectionMode ? 96 : 40)
        }
        .simultaneousGesture(pinchZoomGesture)
        .ignoresSafeArea(edges: .top)
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(isSelectionMode ? .hidden : .visible, for: .tabBar)
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
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
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
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .accessibilityLabel("從相簿追加拍立得至此相冊")

                        Menu {
                            Button {
                                showingCameraScanner = true
                            } label: {
                                Label("使用相機拍攝至此相冊", systemImage: "camera")
                            }

                            PhotosPicker(
                                selection: $selectedPhotos,
                                maxSelectionCount: nil,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                Label("從相簿多選匯入（不限張數）", systemImage: "photo.badge.plus")
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
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
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
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial, in: Circle())
                        }
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
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(.ultraThinMaterial, in: Circle())
                            } else {
                                Text("選取")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 14)
                                    .frame(height: 34)
                                    .background(.ultraThinMaterial, in: Capsule())
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
            "確定要刪除選取的 \(selectedItemIDs.count) 張拍立得嗎？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("刪除 \(selectedItemIDs.count) 張拍立得", role: .destructive) {
                let itemsToDelete = displayedItems.filter { selectedItemIDs.contains($0.persistentModelID) }
                PhotoLibraryManager.shared.deleteItems(itemsToDelete, modelContext: modelContext)
                isSelectionMode = false
                selectedItemIDs.removeAll()
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

                if magnification > 1.65 {
                    targetIndex = max(0, baseIndex - 2)
                } else if magnification > 1.22 {
                    targetIndex = max(0, baseIndex - 1)
                } else if magnification < 0.60 {
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

    private var heroHeaderView: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack(alignment: .bottomLeading) {
                if let data = heroCoverData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.22)
                        .frame(width: width, height: height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [Color.indigo.opacity(0.8), Color.purple.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: width, height: height)
                }

                LinearGradient(
                    colors: [
                        .black.opacity(0.25),
                        .clear,
                        .black.opacity(0.75)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: width, height: height)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(effectivePrimaryTitle)
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)

                        if let effectiveSecondaryTitle {
                            Text(effectiveSecondaryTitle)
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
                        NavigationLink(value: firstItem) {
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
            .frame(width: width, height: height)
            .clipped()
            .contentShape(Rectangle())
        }
        .frame(height: 390)
        .clipped()
    }

    @ViewBuilder
    private func albumPhotoCell(for item: ChekiItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.persistentModelID)
        if isSelectionMode {
            AlbumSquareThumbnailCell(item: item)
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
            NavigationLink(value: item) {
                AlbumSquareThumbnailCell(item: item)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Menu("指派推角成員") {
                    Button {
                        item.idolMember = nil
                        try? modelContext.save()
                        if autoSyncToPhotos {
                            Task {
                                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                                    [item],
                                    modelContext: modelContext
                                )
                            }
                        }
                    } label: {
                        Label("未分類", systemImage: item.idolMember == nil ? "checkmark" : "tray")
                    }

                    ForEach(idolMembers) { member in
                        Button {
                            item.idolMember = member
                            try? modelContext.save()
                            if autoSyncToPhotos {
                                Task {
                                    await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                                        [item],
                                        modelContext: modelContext
                                    )
                                }
                            }
                        } label: {
                            Label(member.albumTitle, systemImage: item.idolMember?.id == member.id ? "checkmark" : "person")
                        }
                    }
                }

                Divider()

                Button(role: .destructive) {
                    PhotoLibraryManager.shared.deleteItems([item], modelContext: modelContext)
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
               let existingItem = allChekiItems.first(where: { $0.frontAssetIdentifier == assetId }) {
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

private struct AlbumSquareThumbnailCell: View {
    let item: ChekiItem

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width
            ZStack(alignment: .topTrailing) {
                if let data = item.frontImageData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.22)
                        .frame(width: size, height: size)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .frame(width: size, height: size)
                }

                ChekiWatermarkOverlayView(compact: true)
                    .frame(width: size, height: size)

                if item.hasBothSides {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
            }
            .frame(width: size, height: size)
            .clipped()
            .contentShape(Rectangle())
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
    }
}

// MARK: - 6. LibrarySearchView (底部右側圓形「🔍 搜尋」Tab)

struct LibrarySearchView: View {

    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    @State private var searchText: String = ""
    @State private var showingSettingsSheet: Bool = false

    private let twoColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private let threeColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var filteredItems: [ChekiItem] {
        chekiItems.filter { LibraryView.matchesSearch(item: $0, query: searchText) }
    }

    private var availableHashtags: [String] {
        var counts: [String: Int] = [:]
        for item in chekiItems {
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
                                                coverImagesData: AlbumsRootView.memberCoverImages(for: member)
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
                                NavigationLink(value: item) {
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
            .navigationDestination(for: ChekiItem.self) { item in
                ChekiDetailView(item: item)
            }
            .navigationDestination(for: IdolMember.self) { member in
                AlbumHeroDetailView(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    items: chekiItems.filter { $0.idolMember?.id == member.id },
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
