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
                        .padding(.horizontal, columnCount >= 5 ? 8 : 14)
                        .padding(.top, 82)
                        .padding(.bottom, 32)
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: columnCount)
                    }
                    .simultaneousGesture(pinchZoomGesture)
                }

                // 頂部懸浮標題與控制列（對齊 Apple 相簿 ライブラリ 頂部位置）
                topFloatingHeaderBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionBottomBar
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
                Text("此操作會將拍立得從 ChekiLens 典藏庫移除，且無法復原。")
            }
            .sheet(isPresented: $showingQuickCreateSheet) {
                QuickCreateIdolSheet()
            }
            .sheet(isPresented: $showingSettingsSheet) {
                SettingsView()
            }
            .sheet(isPresented: $showingBatchPairingSheet, onDismiss: {
                processingItems = []
            }) {
                BatchPairingView(initialPickerItems: processingItems)
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
                Text(isSelectionMode ? "已選取 \(selectedItemIDs.count) 項" : "全部")
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
                        if selectedItemIDs.count == displayedItems.count {
                            selectedItemIDs.removeAll()
                        } else {
                            selectedItemIDs = Set(displayedItems.map(\.persistentModelID))
                        }
                    } label: {
                        Text(selectedItemIDs.count == displayedItems.count ? "取消全選" : "全選")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(.ultraThinMaterial, in: Capsule())
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
                        withAnimation(.snappy(duration: 0.2)) {
                            isSelectionMode.toggle()
                            if !isSelectionMode {
                                selectedItemIDs.removeAll()
                            }
                        }
                    } label: {
                        Text(isSelectionMode ? "完成" : "選取")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(.ultraThinMaterial, in: Capsule())
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
                    } label: {
                        Label("設為未分類", systemImage: "tray")
                    }
                    ForEach(idolMembers) { member in
                        Button {
                            item.idolMember = member
                            try? modelContext.save()
                        } label: {
                            if let groupName = member.group?.name {
                                Text("\(member.stageName)（\(groupName)）")
                            } else {
                                Text(member.stageName)
                            }
                        }
                    }
                } label: {
                    Label("指派推角成員", systemImage: "person.crop.circle.badge.plus")
                }

                Divider()

                Button(role: .destructive) {
                    modelContext.delete(item)
                    try? modelContext.save()
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
        HStack {
            Text("已選取 \(selectedItemIDs.count) 張")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("刪除", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
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
        for item in chekiItems where selectedItemIDs.contains(item.persistentModelID) {
            modelContext.delete(item)
        }
        try? modelContext.save()
        withAnimation {
            isSelectionMode = false
            selectedItemIDs.removeAll()
        }
    }

    @MainActor
    private func processImportedPhotos(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        defer { isProcessing = false }

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
            }
        }

        try? modelContext.save()
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
                    primaryTitle: member.group?.name ?? member.stageName,
                    secondaryTitle: member.group != nil ? "(\(member.stageName))" : nil,
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
                            primaryTitle: member.group?.name ?? member.stageName,
                            secondaryTitle: member.group != nil ? "(\(member.stageName))" : nil,
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
                        .lineLimit(1)

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
                                primaryTitle: group.name,
                                secondaryTitle: "(\(member.stageName))",
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

    private var displayedItems: [ChekiItem] {
        let filtered = filterDualSideOnly ? items.filter(\.hasBothSides) : items
        return filtered.sorted {
            sortAscending ? ($0.displayDate < $1.displayDate) : ($0.displayDate > $1.displayDate)
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    private var heroCoverData: Data? {
        items.first?.frontImageData
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                heroHeaderView

                if displayedItems.isEmpty {
                    ContentUnavailableView {
                        Label("尚無拍立得項目", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("點擊右上角「⋯」匯入或拍攝拍立得至此相冊。")
                    }
                    .padding(.vertical, 48)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(displayedItems) { item in
                            albumPhotoCell(for: item)
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: columnCount)
                }
            }
            .padding(.bottom, 40)
        }
        .simultaneousGesture(pinchZoomGesture)
        .ignoresSafeArea(edges: .top)
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
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

                    if !displayedItems.isEmpty {
                        Button {
                            withAnimation {
                                isSelectionMode.toggle()
                                if !isSelectionMode {
                                    selectedItemIDs.removeAll()
                                }
                            }
                        } label: {
                            Text(isSelectionMode ? "完成" : "選取")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(.ultraThinMaterial, in: Capsule())
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
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                HStack {
                    Text("已選取 \(selectedItemIDs.count) 個項目")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedItemIDs.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .confirmationDialog(
            "確定要刪除選取的 \(selectedItemIDs.count) 張拍立得嗎？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                for item in displayedItems where selectedItemIDs.contains(item.persistentModelID) {
                    modelContext.delete(item)
                }
                try? modelContext.save()
                isSelectionMode = false
                selectedItemIDs.removeAll()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
        }
        .sheet(isPresented: $showingBatchPairingSheet, onDismiss: {
            processingItems = []
        }) {
            BatchPairingView(initialPickerItems: processingItems, defaultMember: defaultMember)
        }
        .fullScreenCover(isPresented: $showingCameraScanner) {
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
                        Text(primaryTitle)
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)

                        if let secondaryTitle {
                            Text(secondaryTitle)
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
        }
    }

    @MainActor
    private func processImportedPhotos(_ pickerItems: [PhotosPickerItem]) async {
        isProcessing = true
        defer { isProcessing = false }

        for pickerItem in pickerItems {
            guard let data = try? await pickerItem.loadTransferable(type: Data.self),
                  let originalUIImage = UIImage(data: data) else { continue }

            let uiImage = originalUIImage.normalizedImage
            let normalizedData = uiImage.jpegData(compressionQuality: 0.92) ?? data

            if let assetId = pickerItem.itemIdentifier,
               !assetId.isEmpty,
               let existingItem = items.first(where: { $0.frontAssetIdentifier == assetId }) {
                if existingItem.originalFrontImageData == nil {
                    existingItem.originalFrontImageData = normalizedData
                }
                await VisionPhotoProcessor.process(existingItem, image: uiImage)
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
            }
        }

        try? modelContext.save()
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
                                                primaryTitle: member.group?.name ?? member.stageName,
                                                secondaryTitle: member.group != nil ? "(\(member.stageName))" : nil,
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
                    primaryTitle: member.group?.name ?? member.stageName,
                    secondaryTitle: member.group != nil ? "(\(member.stageName))" : nil,
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
                    TextField("成員姓名 / 藝名（如：河田陽菜）", text: $stageName)
                    TextField("所屬團體（如：日向坂46，可留空）", text: $groupName)
                    TextField("標籤（以空白分隔，如：主推 二期生）", text: $tagsText)
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

// MARK: - Previews

#Preview("全部 (Apple Photos ライブラリ)") {
    LibraryView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}

#Preview("相冊 (Apple Photos アルバム)") {
    AlbumsRootView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}
