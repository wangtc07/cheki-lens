import SwiftUI
import SwiftData
import PhotosUI
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
    @AppStorage("chekiDateSortBasis") private var sortBasisRaw: String = ChekiDateSortBasis.judgedDate.rawValue

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
    @State private var showingSystemAlbumBatchImport: Bool = false
    @State private var showingCameraScanner: Bool = false
    @State private var pendingCaptureReview: CaptureReviewRequest?
    @State private var captureReviewRequest: CaptureReviewRequest?
    @State private var showingBatchPairingSheet: Bool = false
    @State private var inAppBacksideTargetItem: ChekiItem? = nil
    @State private var photosBacksideTargetItem: ChekiItem? = nil
    @State private var isShowingPhotosBacksidePicker: Bool = false

    // 排序與篩選
    @State private var sortAscending: Bool = false
    @State private var filterDualSideOnly: Bool = false

    // 雙指縮放欄數狀態（支援 1, 2, 3, 5 欄；預設 3 欄，縮小可切換至 5 欄）
    @State private var columnCount: Int = 3
    @State private var pinchBaselineColumnCount: Int? = nil
    @State private var livePinchScale: CGFloat = 1

    init() {}

    private var validChekiItems: [ChekiItem] {
        chekiItems.filter { !$0.isDeleted && $0.modelContext != nil }
    }

    private var sortBasis: ChekiDateSortBasis {
        ChekiDateSortBasis(rawValue: sortBasisRaw) ?? .judgedDate
    }

    private var displayedItems: [ChekiItem] {
        let filtered = filterDualSideOnly ? validChekiItems.filter(\.hasBothSides) : validChekiItems
        return ChekiLibrarySort.sorted(filtered, basis: sortBasis, ascending: sortAscending)
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
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                                ForEach(displayedItems) { item in
                                    photoGridCell(for: item)
                                        .id(item.id)
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
                            .scaleEffect(livePinchScale, anchor: .top)
                            .animation(ChekiMotion.layoutCommit, value: columnCount)
                        }
                        .simultaneousGesture(pinchZoomGesture)
                        .accessibilityIdentifier(ChromeID.libraryGrid)
                        .accessibilityValue("\(columnCount)")
                        .onChange(of: chromeState.activeZoomItemID) { _, newID in
                            guard let newID,
                                  chromeState.activeDetailRoute?.sourceScopeID == "library-all",
                                  displayedItems.contains(where: { $0.id == newID }) else { return }
                            let screenHeight = UIScreen.main.bounds.height
                            if let anchor = chromeState.gridCellAnchor(for: newID, scopeID: "library-all") {
                                if anchor.globalFrame.minY < 88 || anchor.globalFrame.maxY > screenHeight - 70 {
                                    scrollProxy.scrollTo(newID, anchor: .center)
                                }
                            } else {
                                scrollProxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
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
                Button(L10n.tr("刪除 \(selectedItemIDs.count) 張", "\(selectedItemIDs.count)枚を削除"), role: .destructive) {
                    deleteSelectedItems()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(
                    autoSyncToPhotos
                        ? L10n.tr("將同時從 App 與系統相簿刪除", "アプリと「写真」の両方から削除します")
                        : L10n.tr("將從典藏庫永久刪除", "ライブラリから完全に削除します")
                )
            }
            .sheet(isPresented: $showingQuickCreateSheet) {
                QuickCreateIdolSheet()
            }
            .fullScreenCover(isPresented: $showingSystemAlbumBatchImport) {
                SystemAlbumBatchImportFlowSheet()
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
            .fullScreenCover(isPresented: $showingCameraScanner, onDismiss: {
                let pending = pendingCaptureReview
                pendingCaptureReview = nil
                CaptureReviewPresentation.presentAfterCameraDismiss(hasItems: pending != nil) {
                    captureReviewRequest = pending
                }
            }) {
                CameraScannerView { photos in
                    guard !photos.isEmpty else { return }
                    pendingCaptureReview = CaptureReviewRequest(photos: photos, member: nil)
                }
            }
            .sheet(item: $captureReviewRequest) { request in
                BatchPairingView(
                    initialSessionPhotos: request.photos,
                    defaultMember: request.member
                )
            }
            .overlay {
                if isProcessing {
                    processingOverlay
                }
            }
            .chekiBacksidePickerModals(
                inAppTargetItem: $inAppBacksideTargetItem,
                photosTargetItem: $photosBacksideTargetItem,
                isShowingPhotosPicker: $isShowingPhotosBacksidePicker
            )
            .navigationDestination(for: ChekiDetailRoute.self) { route in
                ChekiDetailView(itemID: route.itemID, scopedItemIDs: route.scopedItemIDs)
                    .toolbar(.hidden, for: .tabBar)
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

            topHeaderActionButtons
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [
                    Color(.systemBackground).opacity(0.65),
                    Color(.systemBackground).opacity(0.28),
                    Color(.systemBackground).opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    @ViewBuilder
    private var topHeaderActionButtons: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                topHeaderActionButtonsContent
            }
        } else {
            topHeaderActionButtonsContent
        }
    }

    private var topHeaderActionButtonsContent: some View {
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
                    AppIcons.cameraAddImage
                        .font(.subheadline.weight(.semibold))
                        .darkSystemCircleChrome(size: 36)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("開啟相機拍攝拍立得")
                .accessibilityIdentifier(ChromeID.libraryCamera)

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
                .accessibilityLabel("匯入拍立得照片")
                .accessibilityIdentifier(ChromeID.libraryImport)
                .onChange(of: selectedPhotos) { _, newItems in
                    guard !newItems.isEmpty else { return }
                    processingItems = newItems
                    selectedPhotos = []
                    showingBatchPairingSheet = true
                }

                Menu {
                    Section(L10n.tr("顯示密度", "表示列数")) {
                        ForEach(GridPinchZoom.columnCounts, id: \.self) { count in
                            Button {
                                withAnimation(ChekiMotion.layoutCommit) {
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
                            sortBasisRaw = ChekiDateSortBasis.judgedDate.rawValue
                        } label: {
                            Label(
                                ChekiDateSortBasis.judgedDate.menuTitle,
                                systemImage: sortBasis == .judgedDate ? "checkmark" : "calendar"
                            )
                        }
                        Button {
                            sortBasisRaw = ChekiDateSortBasis.originalCaptureDate.rawValue
                        } label: {
                            Label(
                                ChekiDateSortBasis.originalCaptureDate.menuTitle,
                                systemImage: sortBasis == .originalCaptureDate ? "checkmark" : "camera"
                            )
                        }
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
                            showingSystemAlbumBatchImport = true
                        } label: {
                            Label(L10n.tr("匯入系統相冊", "システムアルバム読込"), systemImage: "folder.badge.plus")
                        }

                        Button {
                            showingQuickCreateSheet = true
                        } label: {
                            Label(L10n.tr("團體 / 成員", "グループ / メンバー"), systemImage: "person.badge.plus")
                        }

                        Button {
                            showingSettingsSheet = true
                        } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.subheadline.weight(.semibold))
                        .darkSystemCircleChrome(size: 36)
                }
                .tint(.primary)
                .fixedSize()
                .accessibilityLabel("篩選與更多設定")
                .accessibilityIdentifier(ChromeID.libraryFilter)
            }

            if !displayedItems.isEmpty {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(ChekiMotion.toggle) {
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
                .accessibilityIdentifier(ChromeID.librarySelect)
            }
        }
    }

    // MARK: - Pinch-to-Zoom Gesture (雙指縮放切換 1 / 2 / 3 / 5 欄)

    private var pinchZoomGesture: some Gesture {
        GridPinchZoom.gesture(
            columnCount: $columnCount,
            liveScale: $livePinchScale,
            baseline: $pinchBaselineColumnCount
        )
    }

    // MARK: - Photo Cell (仿照圖 1 / 圖 2：保留相片比例與圓角，無下方文字框)

    @ViewBuilder
    private func photoGridCell(for item: ChekiItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.persistentModelID)
        let cornerRadius: CGFloat = columnCount <= 2 ? 12 : (columnCount == 3 ? 9 : 5)

        if isSelectionMode {
            AppleLibraryPhotoCell(item: item, cornerRadius: cornerRadius, scopeID: "library-all")
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(columnCount >= 5 ? .subheadline : .title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.9), isSelected ? .blue : .black.opacity(0.35))
                        .padding(columnCount >= 5 ? 4 : 8)
                }
                .scaleEffect(isSelected ? 0.95 : 1.0)
                .animation(ChekiMotion.toggle, value: isSelected)
                .onTapGesture {
                    UISelectionFeedbackGenerator().selectionChanged()
                    if isSelected {
                        selectedItemIDs.remove(item.persistentModelID)
                    } else {
                        selectedItemIDs.insert(item.persistentModelID)
                    }
                }
        } else {
            Button {
                NavigationChromeState.shared.presentDetail(
                    ChekiDetailRoute(
                        itemID: item.id,
                        scopedItemIDs: displayedItems.map(\.id),
                        sourceScopeID: "library-all"
                    )
                )
            } label: {
                AppleLibraryPhotoCell(item: item, cornerRadius: cornerRadius, scopeID: "library-all")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(ChromeID.libraryPhoto)
            .contextMenu {
                Menu {
                    MemberAssignmentMenuContent(item: item) { showingQuickCreateSheet = true }
                } label: {
                    Label(L10n.tr("成員", "メンバー"), systemImage: "person.crop.circle")
                }
                .menuActionDismissBehavior(.disabled)

                ChekiBacksideAssignmentMenu(
                    item: item,
                    onSelectInAppPhoto: {
                        inAppBacksideTargetItem = item
                    },
                    onSelectSystemPhoto: {
                        photosBacksideTargetItem = item
                        isShowingPhotosBacksidePicker = true
                    }
                )

                Divider()

                Button(role: .destructive) {
                    Task { @MainActor in
                        await PhotoLibraryManager.shared.deleteItemsAsync([item], modelContext: modelContext)
                    }
                } label: {
                    Label(L10n.tr("刪除", "削除"), systemImage: "trash")
                }
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("尚無拍立得典藏", systemImage: "photo.stack")
        } description: {
            Text(L10n.tr("由右上角拍照或從相簿匯入", "右上から撮影またはアルバム読込"))
        } actions: {
            VStack(spacing: 12) {
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: nil,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(L10n.tr("相簿", "アルバム"), systemImage: "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingSystemAlbumBatchImport = true
                } label: {
                    Label(L10n.tr("匯入系統相冊", "システムアルバム読込"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.empty.batchImportAlbums")
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
    var scopeID: String? = nil
    private var chromeState = NavigationChromeState.shared

    var body: some View {
        let isValid = !item.isDeleted && item.modelContext != nil
        let isHiddenForZoom = chromeState.isGridCellHidden(itemID: item.id, scopeID: scopeID)

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
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { newFrame in
                        guard let scopeID else { return }
                        NavigationChromeState.shared.updateGridCellAnchor(
                            itemID: item.id,
                            scopeID: scopeID,
                            globalFrame: newFrame,
                            cornerRadius: cornerRadius,
                            isSquareCropped: false
                        )
                    }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .aspectRatio(0.7, contentMode: .fit)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { newFrame in
                        guard let scopeID else { return }
                        NavigationChromeState.shared.updateGridCellAnchor(
                            itemID: item.id,
                            scopeID: scopeID,
                            globalFrame: newFrame,
                            cornerRadius: cornerRadius,
                            isSquareCropped: false
                        )
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
        .opacity(isHiddenForZoom ? 0.0 : 1.0)
        .contentShape(Rectangle())
    }
}

// MARK: - 相冊刪除（移走拍立得後再刪相冊，避免 cascade 把照片一起刪掉）

private enum AlbumPendingDeletion {
    case groups(Set<UUID>)
    case members(Set<UUID>)
}

private enum AlbumLibraryDeletion {
    static func deleteMembers(
        _ members: [IdolMember],
        allItems: [ChekiItem],
        allMembers: [IdolMember],
        in context: ModelContext
    ) {
        let doomedIDs = Set(members.map(\.id))
        guard !doomedIDs.isEmpty else { return }
        for item in allItems where !item.isDeleted && item.modelContext != nil {
            let current = item.assignedMembers(from: allMembers)
            let remaining = current.filter { !doomedIDs.contains($0.id) }
            if remaining.count != current.count {
                item.setAssignedMembers(remaining)
            }
        }
        try? context.save()
        for member in members where !member.isDeleted && member.modelContext != nil {
            context.delete(member)
        }
        try? context.save()
    }

    static func deleteGroups(
        _ groups: [IdolGroup],
        allItems: [ChekiItem],
        allMembers: [IdolMember],
        in context: ModelContext
    ) {
        let members = groups.flatMap(\.members)
        deleteMembers(members, allItems: allItems, allMembers: allMembers, in: context)
        for group in groups where !group.isDeleted && group.modelContext != nil {
            context.delete(group)
        }
        try? context.save()
    }
}

private struct AlbumSelectionBadge: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(isSelected ? .white : .white.opacity(0.9), isSelected ? .blue : .black.opacity(0.35))
            .padding(10)
    }
}

/// 相冊封面的滑動多選。命中用卡片 UIView 的即時位置，與觸控同一個座標系。
private struct AlbumDragSelectOverlay: View {
    let itemIDs: [UUID]
    let registry: AlbumCardRegistry
    @Binding var selectedItemIDs: Set<UUID>

    var body: some View {
        if !itemIDs.isEmpty {
            ApplePhotosDragSelectOverlay(
                itemIDs: itemIDs,
                columnCount: 1,
                spacing: 0,
                cellAspectRatio: 1,
                frameProvider: { view in
                    registry.frames(in: view)
                },
                selectedItemIDs: $selectedItemIDs
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    @AppStorage("albumCoverColumnCount") private var columnCount: Int = 2
    @State private var pinchBaselineColumnCount: Int?
    @State private var livePinchScale: CGFloat = 1

    @State private var albumPath = NavigationPath()
    @State private var hierarchyMode: AlbumHierarchyMode = .groups
    @State private var isSelectingAlbums: Bool = false
    @State private var selectedGroupIDs: Set<UUID> = []
    @State private var selectedMemberIDs: Set<UUID> = []
    @State private var pendingDeletion: AlbumPendingDeletion?
    @State private var groupsSegmentHidden: Bool = false
    @State private var membersSegmentHidden: Bool = false
    @State private var groupScrollPosition = ScrollPosition(edge: .top)
    @State private var memberScrollPosition = ScrollPosition(edge: .top)
    @State private var showingQuickCreateSheet: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingSystemAlbumBatchImport: Bool = false
    @State private var showingBatchPairingSheet: Bool = false
    @State private var showingCameraScanner: Bool = false
    @State private var pendingCaptureReview: CaptureReviewRequest?
    @State private var captureReviewRequest: CaptureReviewRequest?
    @State private var showingAlbumPhotosPicker: Bool = false
    @State private var selectedAlbumPhotos: [PhotosPickerItem] = []
    @State private var pendingBatchPhotos: [PhotosPickerItem] = []
    @State private var actionTargetMember: IdolMember? = nil

    @State private var renamingGroup: IdolGroup? = nil
    @State private var renamingMember: IdolMember? = nil
    @State private var renameText: String = ""
    @State private var groupRegistry = AlbumCardRegistry()
    @State private var memberRegistry = AlbumCardRegistry()
    @State private var menuLiftedGroupID: UUID?
    @State private var menuLiftedMemberID: UUID?
    @State private var dragLiftedGroupID: UUID?
    @State private var dragLiftedMemberID: UUID?
    @State private var groupFloat: AlbumDragFloat?
    @State private var memberFloat: AlbumDragFloat?
    @State private var uncategorizedMenuLifted = false
    @State private var blockAlbumOpen = false
    private var chromeState = NavigationChromeState.shared

    private var sortMethod: AlbumSortMethod {
        AlbumSortMethod(rawValue: sortMethodRaw) ?? .custom
    }

    private var displayMode: AlbumDisplayMode {
        AlbumDisplayMode(rawValue: displayModeRaw) ?? .grid
    }

    private var segmentHidden: Bool {
        hierarchyMode == .groups ? groupsSegmentHidden : membersSegmentHidden
    }

    private var currentSelectionIsEmpty: Bool {
        switch hierarchyMode {
        case .groups: selectedGroupIDs.isEmpty
        case .members: selectedMemberIDs.isEmpty
        }
    }

    private var albumColumns: [GridItem] {
        let count = GridPinchZoom.albumColumnCounts.contains(columnCount) ? columnCount : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var pinchZoomGesture: some Gesture {
        GridPinchZoom.gesture(
            columnCount: $columnCount,
            liveScale: $livePinchScale,
            baseline: $pinchBaselineColumnCount,
            counts: GridPinchZoom.albumColumnCounts
        )
    }

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
        NavigationStack(path: $albumPath) {
            ZStack(alignment: .top) {
                Color(.systemBackground)
                    .ignoresSafeArea()

                TabView(selection: $hierarchyMode) {
                    albumModeScroll(.groups)
                        .tag(AlbumHierarchyMode.groups)
                    albumModeScroll(.members)
                        .tag(AlbumHierarchyMode.members)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(ChekiMotion.toggle, value: hierarchyMode)
                .accessibilityIdentifier(ChromeID.albumsGrid)
                .accessibilityValue("\(columnCount)")

                // 頂部固定標頭 + 「團體 | 成員」切換控制（設定 zIndex 並與下方卡片嚴格隔離點擊區域）
                albumsTopHeaderBar
                    .zIndex(10)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if isSelectingAlbums {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("取消", "キャンセル")) {
                            exitAlbumSelection()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("刪除", "削除"), role: .destructive) {
                            queueVisibleSelectionForDelete()
                        }
                        .disabled(currentSelectionIsEmpty)
                    }
                } else {
                    AlbumNavTrailingToolbar(onCreate: { showingQuickCreateSheet = true }) {
                        albumsToolbarMenuContent
                    }
                }
            }
            .toolbar(isSelectingAlbums || chromeState.shouldHideMainTabBar ? .hidden : .visible, for: .tabBar)
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
            .fullScreenCover(isPresented: $showingSystemAlbumBatchImport) {
                SystemAlbumBatchImportFlowSheet()
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
                let pending = pendingCaptureReview
                pendingCaptureReview = nil
                CaptureReviewPresentation.presentAfterCameraDismiss(hasItems: pending != nil) {
                    captureReviewRequest = pending
                }
                actionTargetMember = nil
            }) {
                CameraScannerView(defaultMember: actionTargetMember) { photos in
                    guard !photos.isEmpty else { return }
                    pendingCaptureReview = CaptureReviewRequest(photos: photos, member: actionTargetMember)
                }
            }
            .sheet(item: $captureReviewRequest) { request in
                BatchPairingView(
                    initialSessionPhotos: request.photos,
                    defaultMember: request.member
                )
            }
            .alert(
                L10n.tr("團體名", "グループ名"),
                isPresented: Binding(
                    get: { renamingGroup != nil },
                    set: { if !$0 { renamingGroup = nil } }
                )
            ) {
                TextField(L10n.tr("團體名稱", "グループ名"), text: $renameText)
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
                L10n.tr("成員名", "メンバー名"),
                isPresented: Binding(
                    get: { renamingMember != nil },
                    set: { if !$0 { renamingMember = nil } }
                )
            ) {
                TextField(L10n.tr("成員名稱", "メンバー名"), text: $renameText)
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
            .confirmationDialog(
                L10n.tr("刪除相冊？", "アルバムを削除？"),
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.tr("刪除", "削除"), role: .destructive) {
                    performPendingDeletion()
                }
                Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                Text(L10n.tr("相冊會刪除，裡面的拍立得會移到未分類。", "アルバムは削除され、中のチェキは未分類に移動します。"))
            }
            .navigationDestination(for: IdolGroup.self) { group in
                GroupMembersAlbumView(group: group, allItems: validChekiItems, albumPath: $albumPath)
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

    // MARK: - Albums Toolbar Menu

    @ViewBuilder
    private var albumsToolbarMenuContent: some View {
            Button {
                withAnimation(ChekiMotion.toggle) {
                    isSelectingAlbums = true
                }
            } label: {
                Label(L10n.tr("選擇", "選択"), systemImage: "checkmark.circle")
            }

            AlbumAddMenuItems(
                onCamera: {
                    actionTargetMember = nil
                    showingCameraScanner = true
                },
                onImport: {
                    actionTargetMember = nil
                    showingAlbumPhotosPicker = true
                }
            )

            Button {
                showingSystemAlbumBatchImport = true
            } label: {
                Label(L10n.tr("匯入系統相冊", "システムアルバム読込"), systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("albums.menu.batchImportAlbums")

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
                    Label(L10n.tr("團體名", "グループ名"), systemImage: "pencil")
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
                    Label(L10n.tr("成員名", "メンバー名"), systemImage: "pencil")
                }
            }

            Divider()

            AlbumSortDisplayMenus(
                sortMethodRaw: $sortMethodRaw,
                displayModeRaw: $displayModeRaw,
                columnCount: $columnCount
            )

            Divider()

            SettingsMenuButton { showingSettingsSheet = true }
    }

    // MARK: - Albums Top Header Bar

    private var albumsTopHeaderBar: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                Text("相冊")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground).ignoresSafeArea(edges: .top))

            Picker("相冊檢視階層", selection: $hierarchyMode.animation(ChekiMotion.toggle)) {
                ForEach(AlbumHierarchyMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .opacity(segmentHidden ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: segmentHidden)
            .allowsHitTesting(!segmentHidden)
        }
    }

    private func albumModeScroll(_ mode: AlbumHierarchyMode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch mode {
                case .groups:
                    groupsAlbumGrid
                case .members:
                    allMembersAlbumGrid
                }
            }
            .padding(.top, 96)
            .padding(.bottom, 28)
            .scaleEffect(displayMode == .grid ? livePinchScale : 1, anchor: .top)
            .animation(ChekiMotion.layoutCommit, value: columnCount)
            .background {
                AlbumLongPressReorder(
                    enabled: !isSelectingAlbums,
                    registry: mode == .groups ? groupRegistry : memberRegistry,
                    onArm: { id, frame in
                        blockAlbumOpen = true
                        let preview = mode == .groups ? groupDragFloat(id: id, frame: frame) : memberDragFloat(id: id, frame: frame)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            if mode == .groups {
                                dragLiftedGroupID = id
                                menuLiftedGroupID = nil
                                groupFloat = preview
                            } else {
                                dragLiftedMemberID = id
                                menuLiftedMemberID = nil
                                memberFloat = preview
                            }
                        }
                    },
                    onTrack: { translation in
                        trackAlbumDrag(translation, groups: mode == .groups)
                    },
                    onHover: { target, frame in
                        let dragged = mode == .groups ? dragLiftedGroupID : dragLiftedMemberID
                        guard let dragged else { return }
                        if mode == .groups {
                            groupFloat?.destination = CGPoint(x: frame.minX, y: frame.minY)
                        } else {
                            memberFloat?.destination = CGPoint(x: frame.minX, y: frame.minY)
                        }
                        withAnimation(ChekiMotion.small) {
                            if mode == .groups {
                                reorderGroups(dragged: dragged, target: target)
                            } else {
                                reorderMembers(dragged: dragged, target: target)
                            }
                        }
                    },
                    onEnd: { _ in
                        settleAlbumDrag(groups: mode == .groups)
                    }
                )
            }
        }
        .overlay(alignment: .topLeading) {
            if let floating = mode == .groups ? groupFloat : memberFloat {
                AlbumDragFloatCard(model: floating)
            }
        }
        .scrollPosition(mode == .groups ? $groupScrollPosition : $memberScrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            let hidden = offset > 40
            let shown = offset <= 2
            guard hidden || shown else { return }
            switch mode {
            case .groups where groupsSegmentHidden != hidden:
                groupsSegmentHidden = hidden
            case .members where membersSegmentHidden != hidden:
                membersSegmentHidden = hidden
            default:
                break
            }
        }
        .gridPinchGesture(enabled: displayMode == .grid && !isSelectingAlbums, pinchZoomGesture)
    }

    // MARK: - 團體相冊網格 / 清單（基本相簿構造：團體 > 成員）

    @ViewBuilder
    private var groupsAlbumGrid: some View {
        if sortedGroups.isEmpty && uncategorizedItems.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("尚無團體", "グループなし"), systemImage: "rectangle.stack")
            } description: {
                Text(L10n.tr("按團體與成員分類拍立得", "グループとメンバーでチェキを整理"))
            } actions: {
                VStack(spacing: 12) {
                    Button {
                        showingQuickCreateSheet = true
                    } label: {
                        Label(L10n.tr("團體 / 成員", "グループ / メンバー"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingSystemAlbumBatchImport = true
                    } label: {
                        Label(L10n.tr("匯入系統相冊", "システムアルバム読込"), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("albums.emptyGroups.batchImportAlbums")
                }
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
            .overlay {
                if isSelectingAlbums {
                    AlbumDragSelectOverlay(
                        itemIDs: sortedGroups.map(\.id),
                        registry: groupRegistry,
                        selectedItemIDs: $selectedGroupIDs
                    )
                }
            }
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
            .overlay {
                if isSelectingAlbums {
                    AlbumDragSelectOverlay(
                        itemIDs: sortedGroups.map(\.id),
                        registry: groupRegistry,
                        selectedItemIDs: $selectedGroupIDs
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func groupAlbumEntryView(for group: IdolGroup, isList: Bool) -> some View {
        let covers = Self.groupCoverImages(for: group, allItems: validChekiItems)
        let card = albumCard(
            isList: isList,
            title: group.name,
            covers: covers,
            showsDragHandle: sortMethod == .custom
        )
        Group {
            if isSelectingAlbums {
                selectableAlbumCard(card, isSelected: selectedGroupIDs.contains(group.id), isList: isList)
            } else {
                card.albumCardContextMenu(
                    isEnabled: !blockAlbumOpen,
                    accessibilityLabel: group.name,
                    onOpen: { albumPath.append(group) },
                    onCamera: {
                        actionTargetMember = group.sortedMembers.first
                        showingCameraScanner = true
                    },
                    onImport: {
                        actionTargetMember = group.sortedMembers.first
                        showingAlbumPhotosPicker = true
                    },
                    renameTitle: L10n.tr("團體名", "グループ名"),
                    onRename: {
                        renameText = group.name
                        renamingGroup = group
                    },
                    onDelete: { pendingDeletion = .groups([group.id]) },
                    onMenuVisible: { visible in
                        withAnimation(ChekiMotion.small) {
                            if visible {
                                menuLiftedGroupID = group.id
                            } else if menuLiftedGroupID == group.id {
                                menuLiftedGroupID = nil
                            }
                        }
                    }
                )
            }
        }
        .albumCardLift(
            menu: menuLiftedGroupID == group.id,
            dragging: dragLiftedGroupID == group.id
        )
        .overlay {
            AlbumCardAnchor(
                id: group.id,
                registry: groupRegistry,
                isFront: menuLiftedGroupID == group.id
            )
        }
        .zIndex(menuLiftedGroupID == group.id ? 100 : 0)
    }

    // MARK: - 成員相冊網格 / 清單（無視團體階層，直接在原本頁面展開所有成員相冊）

    @ViewBuilder
    private var allMembersAlbumGrid: some View {
        if allExpandedMembers.isEmpty && uncategorizedItems.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("尚無成員", "メンバーなし"), systemImage: "person.2.crop.square.stack")
            } description: {
                Text(L10n.tr("集中瀏覽所有成員相冊", "全メンバーのアルバムを一括表示"))
            } actions: {
                VStack(spacing: 12) {
                    Button {
                        showingQuickCreateSheet = true
                    } label: {
                        Label(L10n.tr("成員", "メンバー"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingSystemAlbumBatchImport = true
                    } label: {
                        Label(L10n.tr("匯入系統相冊", "システムアルバム読込"), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("albums.emptyMembers.batchImportAlbums")
                }
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
            .overlay {
                if isSelectingAlbums {
                    AlbumDragSelectOverlay(
                        itemIDs: allExpandedMembers.map(\.id),
                        registry: memberRegistry,
                        selectedItemIDs: $selectedMemberIDs
                    )
                }
            }
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
            .overlay {
                if isSelectingAlbums {
                    AlbumDragSelectOverlay(
                        itemIDs: allExpandedMembers.map(\.id),
                        registry: memberRegistry,
                        selectedItemIDs: $selectedMemberIDs
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func memberAlbumEntryView(for member: IdolMember, isList: Bool) -> some View {
        let covers = Self.memberCoverImages(for: member, allItems: validChekiItems)
        let card = albumCard(
            isList: isList,
            title: member.albumTitle,
            covers: covers,
            showsDragHandle: sortMethod == .custom
        )
        Group {
            if isSelectingAlbums {
                selectableAlbumCard(card, isSelected: selectedMemberIDs.contains(member.id), isList: isList)
            } else {
                card.albumCardContextMenu(
                    isEnabled: !blockAlbumOpen,
                    accessibilityLabel: member.albumTitle,
                    onOpen: { albumPath.append(member) },
                    onCamera: {
                        actionTargetMember = member
                        showingCameraScanner = true
                    },
                    onImport: {
                        actionTargetMember = member
                        showingAlbumPhotosPicker = true
                    },
                    renameTitle: L10n.tr("成員名", "メンバー名"),
                    onRename: {
                        renameText = member.stageName
                        renamingMember = member
                    },
                    onDelete: { pendingDeletion = .members([member.id]) },
                    onMenuVisible: { visible in
                        withAnimation(ChekiMotion.small) {
                            if visible {
                                menuLiftedMemberID = member.id
                            } else if menuLiftedMemberID == member.id {
                                menuLiftedMemberID = nil
                            }
                        }
                    }
                )
            }
        }
        .albumCardLift(
            menu: menuLiftedMemberID == member.id,
            dragging: dragLiftedMemberID == member.id
        )
        .overlay {
            AlbumCardAnchor(
                id: member.id,
                registry: memberRegistry,
                isFront: menuLiftedMemberID == member.id
            )
        }
        .zIndex(menuLiftedMemberID == member.id ? 100 : 0)
    }

    @ViewBuilder
    private func uncategorizedAlbumEntryView(isList: Bool) -> some View {
        let covers = uncategorizedItems.compactMap(\.frontImageData)
        let card = Group {
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
        card
            .albumCardContextMenu(
                isEnabled: !isSelectingAlbums && !blockAlbumOpen,
                accessibilityLabel: "未分類",
                onOpen: { albumPath.append(UncategorizedAlbumRoute()) },
                onCamera: {
                    actionTargetMember = nil
                    showingCameraScanner = true
                },
                onImport: {
                    actionTargetMember = nil
                    showingAlbumPhotosPicker = true
                },
                onMenuVisible: { visible in
                    withAnimation(ChekiMotion.small) {
                        uncategorizedMenuLifted = visible
                    }
                }
            )
            .albumCardLift(menu: uncategorizedMenuLifted, dragging: false)
            .opacity(isSelectingAlbums ? 0.4 : 1)
            .zIndex(uncategorizedMenuLifted ? 100 : 0)
    }

    @ViewBuilder
    private func albumCard(isList: Bool, title: String, covers: [Data], showsDragHandle: Bool) -> some View {
        if isList {
            ApplePhotoAlbumListRow(
                primaryTitle: title,
                secondaryTitle: nil,
                coverImagesData: covers,
                showsDragHandle: showsDragHandle
            )
        } else {
            ApplePhotoAlbumTile(
                primaryTitle: title,
                secondaryTitle: nil,
                coverImagesData: covers
            )
        }
    }

    private func selectableAlbumCard<Card: View>(
        _ card: Card,
        isSelected: Bool,
        isList: Bool
    ) -> some View {
        card.overlay(alignment: isList ? .trailing : .bottomTrailing) {
            AlbumSelectionBadge(isSelected: isSelected)
                .padding(.trailing, isList ? 8 : 0)
        }
        .allowsHitTesting(false)
    }

    private func exitAlbumSelection() {
        withAnimation(ChekiMotion.toggle) {
            isSelectingAlbums = false
            selectedGroupIDs.removeAll()
            selectedMemberIDs.removeAll()
        }
    }

    private func queueVisibleSelectionForDelete() {
        switch hierarchyMode {
        case .groups where !selectedGroupIDs.isEmpty:
            pendingDeletion = .groups(selectedGroupIDs)
        case .members where !selectedMemberIDs.isEmpty:
            pendingDeletion = .members(selectedMemberIDs)
        default:
            break
        }
    }

    private func performPendingDeletion() {
        guard let pendingDeletion else { return }
        switch pendingDeletion {
        case .groups(let ids):
            let groups = sortedGroups.filter { ids.contains($0.id) }
            AlbumLibraryDeletion.deleteGroups(
                groups,
                allItems: validChekiItems,
                allMembers: idolMembers,
                in: modelContext
            )
            selectedGroupIDs.subtract(ids)
        case .members(let ids):
            let members = allExpandedMembers.filter { ids.contains($0.id) }
            AlbumLibraryDeletion.deleteMembers(
                members,
                allItems: validChekiItems,
                allMembers: idolMembers,
                in: modelContext
            )
            selectedMemberIDs.subtract(ids)
        }
        self.pendingDeletion = nil
        if currentSelectionIsEmpty {
            isSelectingAlbums = false
        }
    }

    private func reorderGroups(dragged: UUID, target: UUID) {
        guard let from = sortedGroups.firstIndex(where: { $0.id == dragged }),
              let to = sortedGroups.firstIndex(where: { $0.id == target }),
              from != to else { return }
        var updated = sortedGroups
        let moved = updated.remove(at: from)
        updated.insert(moved, at: to)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sortMethodRaw = AlbumSortMethod.custom.rawValue
        for (index, group) in updated.enumerated() {
            group.sortOrder = index
        }
        try? modelContext.save()
    }

    private func trackAlbumDrag(_ translation: CGSize, groups: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if groups {
                groupFloat?.translation = translation
            } else {
                memberFloat?.translation = translation
            }
        }
    }

    private func settleAlbumDrag(groups: Bool) {
        let float = groups ? groupFloat : memberFloat
        guard let float else {
            clearAlbumDrag(groups: groups)
            return
        }
        let translation = CGSize(
            width: float.destination.x - float.origin.x,
            height: float.destination.y - float.origin.y
        )
        withAnimation(ChekiMotion.small, completionCriteria: .logicallyComplete) {
            if groups {
                groupFloat?.translation = translation
                groupFloat?.scale = 1
                groupFloat?.opacity = 1
            } else {
                memberFloat?.translation = translation
                memberFloat?.scale = 1
                memberFloat?.opacity = 1
            }
        } completion: {
            clearAlbumDrag(groups: groups)
        }
    }

    private func clearAlbumDrag(groups: Bool) {
        if groups {
            dragLiftedGroupID = nil
            groupFloat = nil
        } else {
            dragLiftedMemberID = nil
            memberFloat = nil
        }
        DispatchQueue.main.async {
            blockAlbumOpen = false
        }
    }

    private func groupDragFloat(id: UUID, frame: CGRect) -> AlbumDragFloat? {
        guard let group = sortedGroups.first(where: { $0.id == id }) else { return nil }
        let origin = CGPoint(x: frame.minX, y: frame.minY)
        return AlbumDragFloat(
            title: group.name,
            covers: Self.groupCoverImages(for: group, allItems: validChekiItems),
            isList: displayMode != .grid,
            showsDragHandle: sortMethod == .custom && displayMode != .grid,
            origin: origin,
            size: frame.size,
            translation: .zero,
            scale: AlbumCardLift.scale,
            opacity: AlbumCardLift.opacity,
            destination: origin
        )
    }

    private func memberDragFloat(id: UUID, frame: CGRect) -> AlbumDragFloat? {
        guard let member = allExpandedMembers.first(where: { $0.id == id }) else { return nil }
        let origin = CGPoint(x: frame.minX, y: frame.minY)
        return AlbumDragFloat(
            title: member.albumTitle,
            covers: Self.memberCoverImages(for: member, allItems: validChekiItems),
            isList: displayMode != .grid,
            showsDragHandle: sortMethod == .custom && displayMode != .grid,
            origin: origin,
            size: frame.size,
            translation: .zero,
            scale: AlbumCardLift.scale,
            opacity: AlbumCardLift.opacity,
            destination: origin
        )
    }

    private func reorderMembers(dragged: UUID, target: UUID) {
        guard let from = allExpandedMembers.firstIndex(where: { $0.id == dragged }),
              let to = allExpandedMembers.firstIndex(where: { $0.id == target }),
              from != to else { return }
        var updated = allExpandedMembers
        let moved = updated.remove(at: from)
        updated.insert(moved, at: to)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sortMethodRaw = AlbumSortMethod.custom.rawValue
        for (index, member) in updated.enumerated() {
            member.sortOrder = index
        }
        try? modelContext.save()
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

/// 卡片本體的 UIView。命中時把這個 view 的 bounds 轉到觸控所在的 view，避免 SwiftUI global 與 UIKit 座標不一致。
final class AlbumCardRegistry {
    private final class Box {
        weak var view: UIView?
    }

    private var boxes: [UUID: Box] = [:]

    func register(_ id: UUID, view: UIView) {
        let box = boxes[id] ?? Box()
        box.view = view
        boxes[id] = box
    }

    func unregister(_ id: UUID, view: UIView) {
        if boxes[id]?.view === view {
            boxes[id] = nil
        }
    }

    func frames(in coordinateView: UIView) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        for (id, box) in boxes {
            guard let anchor = box.view, let card = Self.resolvedCard(for: anchor) else { continue }
            let frame = coordinateView.convert(card.bounds, from: card)
            guard frame.width > 1, frame.height > 1 else { continue }
            result[id] = frame
        }
        return result
    }

    private static func resolvedCard(for anchor: UIView) -> UIView? {
        guard anchor.window != nil else { return nil }
        if anchor.bounds.width > 1, anchor.bounds.height > 1 { return anchor }
        var current = anchor.superview
        while let view = current {
            if view is UIScrollView { return nil }
            if view.bounds.width > 1, view.bounds.height > 1 { return view }
            current = view.superview
        }
        return nil
    }

    func hit(_ point: CGPoint, in coordinateView: UIView, excluding: UUID? = nil) -> UUID? {
        var best: (UUID, CGFloat)?
        for (id, frame) in frames(in: coordinateView) {
            if id == excluding { continue }
            guard frame.insetBy(dx: -8, dy: -8).contains(point) else { continue }
            let distance = hypot(frame.midX - point.x, frame.midY - point.y)
            if best == nil || distance < best!.1 {
                best = (id, distance)
            }
        }
        return best?.0
    }
}

private struct AlbumCardAnchor: UIViewRepresentable {
    let id: UUID
    let registry: AlbumCardRegistry
    var isFront: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(id: id, registry: registry)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AnchorView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    final class AnchorView: UIView {
        var isFront = false

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let superview, superview.bounds.width > 1 {
                frame = superview.bounds
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard isFront else { return }
            bringHostToFront()
        }

        func bringHostToFront() {
            var node: UIView? = self
            var steps = 0
            while let current = node, steps < 12 {
                if current is UIScrollView { break }
                if let parent = current.superview, parent.subviews.last !== current {
                    parent.bringSubviewToFront(current)
                }
                node = current.superview
                steps += 1
            }
        }
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.id = id
        context.coordinator.registry = registry
        uiView.isFront = isFront
        if isFront {
            uiView.bringHostToFront()
        }
        registry.register(id, view: uiView)
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.registry.unregister(coordinator.id, view: uiView)
    }

    final class Coordinator {
        var id: UUID
        var registry: AlbumCardRegistry

        init(id: UUID, registry: AlbumCardRegistry) {
            self.id = id
            self.registry = registry
        }
    }
}

private struct AlbumLongPressReorder: UIViewRepresentable {
    var enabled: Bool
    var registry: AlbumCardRegistry
    var onArm: (UUID, CGRect) -> Void
    var onTrack: (CGSize) -> Void
    var onHover: (UUID, CGRect) -> Void
    var onEnd: (UUID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.registry = registry
        context.coordinator.onArm = onArm
        context.coordinator.onTrack = onTrack
        context.coordinator.onHover = onHover
        context.coordinator.onEnd = onEnd
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
        }

        func installIfNeeded() {
            coordinator?.install(from: self)
        }
    }

    /// 按住一小段後、選單出現前若手指移動，就進入排序。停住不動則把這次手勢讓給選單。
    final class ReorderTouch: UIGestureRecognizer {
        var origin: CGPoint = .zero
        var armedOrigin: CGPoint = .zero
        private var startTime: TimeInterval = 0
        private let minimumHold: TimeInterval = 0.18
        private let movementThreshold: CGFloat = 12

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard state == .possible, let view, let touch = touches.first else {
                state = .failed
                return
            }
            origin = touch.location(in: view)
            startTime = touch.timestamp
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let view, let touch = touches.first else { return }
            let point = touch.location(in: view)
            let distance = hypot(point.x - origin.x, point.y - origin.y)
            if state == .possible {
                guard distance >= movementThreshold else { return }
                guard touch.timestamp - startTime >= minimumHold else {
                    state = .failed
                    return
                }
                armedOrigin = point
                cancelsTouchesInView = true
                state = .began
            } else if state == .began || state == .changed {
                state = .changed
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .began || state == .changed {
                state = .ended
            } else {
                state = .failed
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .began || state == .changed {
                state = .cancelled
            } else {
                state = .failed
            }
        }

        override func reset() {
            super.reset()
            cancelsTouchesInView = false
            origin = .zero
            armedOrigin = .zero
            startTime = 0
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = true
        var registry = AlbumCardRegistry()
        var onArm: (UUID, CGRect) -> Void = { _, _ in }
        var onTrack: (CGSize) -> Void = { _ in }
        var onHover: (UUID, CGRect) -> Void = { _, _ in }
        var onEnd: (UUID?) -> Void = { _ in }

        private static var recognizerKey: UInt8 = 0
        private var draggedID: UUID?
        private var armed = false
        private var lastTarget: UUID?
        private var suspendedScrolls: [(scroll: UIScrollView, enabled: Bool, canCancel: Bool)] = []
        private var silenced: [UIGestureRecognizer] = []

        func install(from marker: UIView) {
            guard let scroll = scrollView(from: marker) else { return }
            if let existing = objc_getAssociatedObject(scroll, &Self.recognizerKey) as? ReorderTouch {
                existing.removeTarget(nil, action: nil)
                existing.addTarget(self, action: #selector(handle(_:)))
                existing.delegate = self
                existing.isEnabled = enabled
                return
            }
            let recognizer = ReorderTouch(target: self, action: #selector(handle(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delegate = self
            recognizer.isEnabled = enabled
            scroll.addGestureRecognizer(recognizer)
            objc_setAssociatedObject(scroll, &Self.recognizerKey, recognizer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let view = gestureRecognizer.view, let touch = gestureRecognizer as? ReorderTouch else {
                return false
            }
            return registry.hit(touch.origin, in: view) != nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handle(_ recognizer: UIGestureRecognizer) {
            guard let view = recognizer.view, let touch = recognizer as? ReorderTouch else { return }
            let point = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                guard let draggedID = registry.hit(touch.origin, in: view) else { return }
                self.draggedID = draggedID
                armed = true
                lastTarget = nil
                lockScrolling(from: view)
                silenceCompeting(except: recognizer, in: view)
                dismissContextMenus(in: view)
                let frame = registry.frames(in: view)[draggedID] ?? .zero
                onArm(draggedID, frame)
                onTrack(.zero)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .changed:
                guard let draggedID else { return }
                let translation = CGSize(
                    width: point.x - touch.armedOrigin.x,
                    height: point.y - touch.armedOrigin.y
                )
                onTrack(translation)
                let frames = registry.frames(in: view)
                let target = registry.hit(point, in: view, excluding: draggedID)
                if target != lastTarget {
                    lastTarget = target
                    if let target, let frame = frames[target] {
                        onHover(target, frame)
                    }
                }
            case .ended, .cancelled, .failed:
                let hover = lastTarget
                restoreScrolling()
                restoreSilenced()
                if armed {
                    onEnd(hover)
                }
                draggedID = nil
                armed = false
                lastTarget = nil
            default:
                break
            }
        }

        private func scrollView(from marker: UIView) -> UIScrollView? {
            var current: UIView? = marker
            while let view = current {
                if let scroll = view as? UIScrollView { return scroll }
                current = view.superview
            }
            return nil
        }

        private func lockScrolling(from view: UIView?) {
            var current = view
            while let node = current {
                if let scroll = node as? UIScrollView,
                   !suspendedScrolls.contains(where: { $0.scroll === scroll }) {
                    suspendedScrolls.append((
                        scroll,
                        scroll.isScrollEnabled,
                        scroll.canCancelContentTouches
                    ))
                    scroll.isScrollEnabled = false
                    scroll.canCancelContentTouches = false
                }
                current = node.superview
            }
        }

        private func restoreScrolling() {
            for item in suspendedScrolls {
                item.scroll.isScrollEnabled = item.enabled
                item.scroll.canCancelContentTouches = item.canCancel
            }
            suspendedScrolls.removeAll()
        }

        private func silenceCompeting(except recognizer: UIGestureRecognizer, in view: UIView?) {
            guard let root = view else { return }
            func consider(_ other: UIGestureRecognizer) {
                guard other !== recognizer, other.isEnabled else { return }
                if other is UIPanGestureRecognizer, other.view is UIScrollView { return }
                guard other.state == .possible || other.state == .began || other.state == .changed else { return }
                other.isEnabled = false
                silenced.append(other)
            }
            func walk(_ node: UIView) {
                node.gestureRecognizers?.forEach(consider)
                node.subviews.forEach(walk)
            }
            walk(root)
            var current = root.superview
            while let node = current {
                node.gestureRecognizers?.forEach(consider)
                current = node.superview
            }
        }

        private func restoreSilenced() {
            silenced.forEach { $0.isEnabled = true }
            silenced.removeAll()
        }

        private func dismissContextMenus(in view: UIView?) {
            guard let root = view else { return }
            func walk(_ node: UIView) {
                node.interactions.forEach { interaction in
                    (interaction as? UIContextMenuInteraction)?.dismissMenu()
                }
                node.subviews.forEach(walk)
            }
            walk(root)
        }
    }
}

private struct AlbumDragFloat: Equatable {
    var title: String
    var covers: [Data]
    var isList: Bool
    var showsDragHandle: Bool
    var origin: CGPoint
    var size: CGSize
    var translation: CGSize
    var scale: CGFloat
    var opacity: Double
    var destination: CGPoint
}

private struct AlbumDragFloatCard: View {
    var model: AlbumDragFloat

    var body: some View {
        let growthX = model.size.width * (model.scale - 1) / 2
        let growthY = model.size.height * (model.scale - 1) / 2
        Group {
            if model.isList {
                ApplePhotoAlbumListRow(
                    primaryTitle: model.title,
                    secondaryTitle: nil,
                    coverImagesData: model.covers,
                    showsDragHandle: model.showsDragHandle
                )
            } else {
                ApplePhotoAlbumTile(
                    primaryTitle: model.title,
                    secondaryTitle: nil,
                    coverImagesData: model.covers
                )
            }
        }
        .frame(width: model.size.width, height: model.size.height)
        .scaleEffect(model.scale)
        .opacity(model.opacity)
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .offset(
            x: model.origin.x + model.translation.width + growthX,
            y: model.origin.y + model.translation.height + growthY
        )
        .allowsHitTesting(false)
    }
}

private enum AlbumCardLift {
    /// 往鏡頭方向浮起，不是畫面上移。
    static let scale: CGFloat = 1.06
    static let opacity: Double = 0.75
}

private extension View {
    /// 選單時沿 Z 軸浮起並半透明。拖動中的格子本體先藏起來，改由畫面最上層的跟隨卡片顯示。
    func albumCardLift(menu: Bool, dragging: Bool) -> some View {
        scaleEffect(menu && !dragging ? AlbumCardLift.scale : 1)
            .shadow(
                color: Color.black.opacity(menu && !dragging ? 0.28 : 0),
                radius: menu && !dragging ? 16 : 0,
                y: menu && !dragging ? 8 : 0
            )
            .opacity(dragging ? 0 : (menu ? AlbumCardLift.opacity : 1))
    }

    /// 長按選單掛在蓋住卡片的透明層。卡片不是選單來源，所以不會被藏起來，也不會被放大成預覽。
    func albumCardContextMenu(
        isEnabled: Bool,
        accessibilityLabel: String,
        onOpen: @escaping () -> Void,
        onCamera: @escaping () -> Void,
        onImport: @escaping () -> Void,
        renameTitle: String? = nil,
        onRename: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onMenuVisible: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        overlay {
            AlbumCardMenuPlate(
                isEnabled: isEnabled,
                onOpen: onOpen,
                onCamera: onCamera,
                onImport: onImport,
                renameTitle: renameTitle,
                onRename: onRename,
                onDelete: onDelete,
                onMenuVisible: onMenuVisible
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onOpen)
        }
    }
}

/// 只負責點擊與長按選單的透明 UIView。預覽用 1×1 透明層，不拿相簿卡片當預覽。
private struct AlbumCardMenuPlate: UIViewRepresentable {
    var isEnabled: Bool
    var onOpen: () -> Void
    var onCamera: () -> Void
    var onImport: () -> Void
    var renameTitle: String?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMenuVisible: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlateView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeUIView(context: Context) -> PlateView {
        let view = PlateView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isAccessibilityElement = false
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: PlateView, context: Context) {
        uiView.isUserInteractionEnabled = isEnabled
        let coordinator = context.coordinator
        coordinator.isEnabled = isEnabled
        coordinator.onOpen = onOpen
        coordinator.onCamera = onCamera
        coordinator.onImport = onImport
        coordinator.renameTitle = renameTitle
        coordinator.onRename = onRename
        coordinator.onDelete = onDelete
        coordinator.onMenuVisible = onMenuVisible
    }

    final class PlateView: UIView {
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let superview, superview.bounds.width > 1 {
                frame = superview.bounds
            }
        }
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
        var isEnabled = true
        var onOpen: () -> Void = {}
        var onCamera: () -> Void = {}
        var onImport: () -> Void = {}
        var renameTitle: String?
        var onRename: (() -> Void)?
        var onDelete: (() -> Void)?
        var onMenuVisible: (Bool) -> Void = { _ in }
        weak var interaction: UIContextMenuInteraction?
        private var ignoreOpenUntil: TimeInterval = 0
        private let decoy: UIView = {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            return view
        }()

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, isEnabled, CACurrentMediaTime() > ignoreOpenUntil else { return }
            onOpen()
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard isEnabled else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: {
                let controller = UIViewController()
                let preview = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
                preview.backgroundColor = .clear
                controller.view = preview
                controller.preferredContentSize = CGSize(width: 1, height: 1)
                return controller
            }, actionProvider: { [weak self] _ in
                self?.makeMenu()
            })
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            tinyPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configuration: UIContextMenuConfiguration,
            dismissalPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            tinyPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            ignoreOpenUntil = CACurrentMediaTime() + 60
            onMenuVisible(true)
            keepCardVisible(from: interaction.view)
            animator?.addAnimations { [weak self] in
                self?.keepCardVisible(from: interaction.view)
            }
            animator?.addCompletion { [weak self] in
                self?.keepCardVisible(from: interaction.view)
            }
            DispatchQueue.main.async { [weak self] in
                self?.keepCardVisible(from: interaction.view)
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            onMenuVisible(false)
            animator?.addCompletion { [weak self] in
                self?.ignoreOpenUntil = CACurrentMediaTime() + 0.35
                self?.keepCardVisible(from: interaction.view)
            }
        }

        private func tinyPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let host = interaction.view else { return nil }
            let container = host.superview ?? host
            let center = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: container)
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.shadowPath = UIBezierPath()
            parameters.visiblePath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
            let target = UIPreviewTarget(container: container, center: center)
            return UITargetedPreview(view: decoy, parameters: parameters, target: target)
        }

        private func keepCardVisible(from view: UIView?) {
            view?.alpha = 1
            view?.isHidden = false
            var current = view?.superview
            var steps = 0
            while let node = current, steps < 6, !(node is UIScrollView) {
                node.isHidden = false
                current = node.superview
                steps += 1
            }
        }

        private func makeMenu() -> UIMenu {
            let camera = UIAction(
                title: L10n.tr("拍照", "カメラ"),
                image: UIImage(systemName: "camera")
            ) { [weak self] _ in
                self?.onCamera()
            }
            let importAction = UIAction(
                title: L10n.tr("相簿", "アルバム"),
                image: UIImage(systemName: "photo.badge.plus")
            ) { [weak self] _ in
                self?.onImport()
            }
            var children: [UIMenuElement] = [
                UIMenu(options: .displayInline, children: [camera, importAction])
            ]
            var edits: [UIMenuElement] = []
            if let onRename, let renameTitle {
                edits.append(UIAction(title: renameTitle, image: UIImage(systemName: "pencil")) { _ in
                    onRename()
                })
            }
            if let onDelete {
                edits.append(UIAction(
                    title: L10n.tr("刪除", "削除"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    onDelete()
                })
            }
            if !edits.isEmpty {
                children.append(UIMenu(options: .displayInline, children: edits))
            }
            return UIMenu(children: children)
        }
    }
}

// MARK: - 4. GroupMembersAlbumView (團體 > 成員 第二層：點開某個團體後顯示該團體旗下的成員相冊)

private struct GroupMembersAlbumView: View {
    let group: IdolGroup
    let allItems: [ChekiItem]
    @Binding var albumPath: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @AppStorage("albumSortMethod") private var sortMethodRaw: String = AlbumSortMethod.custom.rawValue
    @AppStorage("albumDisplayMode") private var displayModeRaw: String = AlbumDisplayMode.grid.rawValue
    @AppStorage("albumCoverColumnCount") private var columnCount: Int = 2
    @State private var pinchBaselineColumnCount: Int?
    @State private var livePinchScale: CGFloat = 1

    @State private var showingQuickCreateSheet: Bool = false
    @State private var showingSettingsSheet: Bool = false
    @State private var showingCameraScanner: Bool = false
    @State private var pendingCaptureReview: CaptureReviewRequest?
    @State private var captureReviewRequest: CaptureReviewRequest?
    @State private var showingAlbumPhotosPicker: Bool = false
    @State private var selectedAlbumPhotos: [PhotosPickerItem] = []
    @State private var pendingBatchPhotos: [PhotosPickerItem] = []
    @State private var showingBatchPairingSheet: Bool = false
    @State private var actionTargetMember: IdolMember? = nil

    @State private var showingRenameGroupAlert: Bool = false
    @State private var renamingMember: IdolMember? = nil
    @State private var renameText: String = ""
    @State private var cardRegistry = AlbumCardRegistry()
    @State private var menuLiftedMemberID: UUID?
    @State private var dragLiftedMemberID: UUID?
    @State private var memberFloat: AlbumDragFloat?
    @State private var blockAlbumOpen = false
    @State private var isSelectingAlbums: Bool = false
    @State private var selectedMemberIDs: Set<UUID> = []
    @State private var pendingMemberDeletionIDs: Set<UUID>?
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

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

    private var albumColumns: [GridItem] {
        let count = GridPinchZoom.albumColumnCounts.contains(columnCount) ? columnCount : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var pinchZoomGesture: some Gesture {
        GridPinchZoom.gesture(
            columnCount: $columnCount,
            liveScale: $livePinchScale,
            baseline: $pinchBaselineColumnCount,
            counts: GridPinchZoom.albumColumnCounts
        )
    }

    var body: some View {
        ScrollView {
            Group {
            if displayedMembers.isEmpty {
                ContentUnavailableView {
                    Label(L10n.tr("尚無成員", "メンバーなし"), systemImage: "person.badge.plus")
                } description: {
                    Text(L10n.tr("點擊右上角 ＋ 建立成員相冊", "右上の ＋ から作成"))
                } actions: {
                    Button {
                        showingQuickCreateSheet = true
                    } label: {
                        Label(L10n.tr("成員", "メンバー"), systemImage: "plus")
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
                .overlay {
                    if isSelectingAlbums {
                        AlbumDragSelectOverlay(
                            itemIDs: displayedMembers.map(\.id),
                            registry: cardRegistry,
                            selectedItemIDs: $selectedMemberIDs
                        )
                    }
                }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(displayedMembers) { member in
                        groupMemberAlbumEntry(for: member, isList: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .overlay {
                    if isSelectingAlbums {
                        AlbumDragSelectOverlay(
                            itemIDs: displayedMembers.map(\.id),
                            registry: cardRegistry,
                            selectedItemIDs: $selectedMemberIDs
                        )
                    }
                }
            }
        }
        .background {
            AlbumLongPressReorder(
                enabled: !isSelectingAlbums && !displayedMembers.isEmpty,
                registry: cardRegistry,
                onArm: { id, frame in
                    blockAlbumOpen = true
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        dragLiftedMemberID = id
                        menuLiftedMemberID = nil
                        memberFloat = memberDragFloat(id: id, frame: frame)
                    }
                },
                onTrack: { translation in
                    trackMemberDrag(translation)
                },
                onHover: { target, frame in
                    guard let dragged = dragLiftedMemberID else { return }
                    memberFloat?.destination = CGPoint(x: frame.minX, y: frame.minY)
                    withAnimation(ChekiMotion.small) {
                        reorderDisplayedMembers(dragged: dragged, target: target)
                    }
                },
                onEnd: { _ in
                    settleMemberDrag()
                }
            )
        }
        }
        .overlay(alignment: .topLeading) {
            if let memberFloat {
                AlbumDragFloatCard(model: memberFloat)
            }
        }
        .scaleEffect(displayMode == .grid ? livePinchScale : 1, anchor: .top)
        .animation(ChekiMotion.layoutCommit, value: columnCount)
        .gridPinchGesture(enabled: displayMode == .grid && !isSelectingAlbums, pinchZoomGesture)
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
        .toolbar(isSelectingAlbums ? .hidden : .visible, for: .tabBar)
        .toolbar {
            if isSelectingAlbums {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "キャンセル")) {
                        withAnimation(ChekiMotion.toggle) {
                            isSelectingAlbums = false
                            selectedMemberIDs.removeAll()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("刪除", "削除"), role: .destructive) {
                        pendingMemberDeletionIDs = selectedMemberIDs
                    }
                    .disabled(selectedMemberIDs.isEmpty)
                }
            } else {
                AlbumNavTrailingToolbar(onCreate: { showingQuickCreateSheet = true }) {
                    Button {
                        withAnimation(ChekiMotion.toggle) {
                            isSelectingAlbums = true
                        }
                    } label: {
                        Label(L10n.tr("選擇", "選択"), systemImage: "checkmark.circle")
                    }

                    AlbumAddMenuItems(
                    onCamera: {
                        actionTargetMember = displayedMembers.first
                        showingCameraScanner = true
                    },
                    onImport: {
                        actionTargetMember = displayedMembers.first
                        showingAlbumPhotosPicker = true
                    }
                )

                Button {
                    renameText = group.name
                    showingRenameGroupAlert = true
                } label: {
                    Label(L10n.tr("團體名", "グループ名"), systemImage: "pencil")
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
                        Label(L10n.tr("成員名", "メンバー名"), systemImage: "person.text.rectangle")
                    }
                }

                Divider()

                AlbumSortDisplayMenus(
                    sortMethodRaw: $sortMethodRaw,
                    displayModeRaw: $displayModeRaw,
                    columnCount: $columnCount
                )

                Divider()

                SettingsMenuButton { showingSettingsSheet = true }
                }
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
            let pending = pendingCaptureReview
            pendingCaptureReview = nil
            CaptureReviewPresentation.presentAfterCameraDismiss(hasItems: pending != nil) {
                captureReviewRequest = pending
            }
            actionTargetMember = nil
        }) {
            CameraScannerView(defaultMember: actionTargetMember) { photos in
                guard !photos.isEmpty else { return }
                pendingCaptureReview = CaptureReviewRequest(photos: photos, member: actionTargetMember)
            }
        }
        .sheet(item: $captureReviewRequest) { request in
            BatchPairingView(
                initialSessionPhotos: request.photos,
                defaultMember: request.member
            )
        }
        .alert(
            L10n.tr("團體名", "グループ名"),
            isPresented: $showingRenameGroupAlert
        ) {
            TextField(L10n.tr("團體名稱", "グループ名"), text: $renameText)
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
            L10n.tr("成員名", "メンバー名"),
            isPresented: Binding(
                get: { renamingMember != nil },
                set: { if !$0 { renamingMember = nil } }
            )
        ) {
            TextField(L10n.tr("成員名稱", "メンバー名"), text: $renameText)
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
        .confirmationDialog(
            L10n.tr("刪除相冊？", "アルバムを削除？"),
            isPresented: Binding(
                get: { pendingMemberDeletionIDs != nil },
                set: { if !$0 { pendingMemberDeletionIDs = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("刪除", "削除"), role: .destructive) {
                let ids = pendingMemberDeletionIDs ?? []
                let members = displayedMembers.filter { ids.contains($0.id) }
                AlbumLibraryDeletion.deleteMembers(
                    members,
                    allItems: allItems,
                    allMembers: idolMembers,
                    in: modelContext
                )
                selectedMemberIDs.subtract(ids)
                pendingMemberDeletionIDs = nil
                if selectedMemberIDs.isEmpty {
                    isSelectingAlbums = false
                }
            }
            Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                pendingMemberDeletionIDs = nil
            }
        } message: {
            Text(L10n.tr("相冊會刪除，裡面的拍立得會移到未分類。", "アルバムは削除され、中のチェキは未分類に移動します。"))
        }
    }

    @ViewBuilder
    private func groupMemberAlbumEntry(for member: IdolMember, isList: Bool) -> some View {
        let covers = AlbumsRootView.memberCoverImages(for: member, allItems: allItems)
        let card = Group {
            if isList {
                ApplePhotoAlbumListRow(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    coverImagesData: covers,
                    showsDragHandle: sortMethod == .custom && !isSelectingAlbums
                )
            } else {
                ApplePhotoAlbumTile(
                    primaryTitle: member.albumTitle,
                    secondaryTitle: nil,
                    coverImagesData: covers
                )
            }
        }
        Group {
            if isSelectingAlbums {
                card.overlay(alignment: isList ? .trailing : .bottomTrailing) {
                    AlbumSelectionBadge(isSelected: selectedMemberIDs.contains(member.id))
                        .padding(.trailing, isList ? 8 : 0)
                }
                .allowsHitTesting(false)
            } else {
                card.albumCardContextMenu(
                    isEnabled: !blockAlbumOpen,
                    accessibilityLabel: member.albumTitle,
                    onOpen: { albumPath.append(member) },
                    onCamera: {
                        actionTargetMember = member
                        showingCameraScanner = true
                    },
                    onImport: {
                        actionTargetMember = member
                        showingAlbumPhotosPicker = true
                    },
                    renameTitle: L10n.tr("成員名", "メンバー名"),
                    onRename: {
                        renameText = member.stageName
                        renamingMember = member
                    },
                    onDelete: { pendingMemberDeletionIDs = [member.id] },
                    onMenuVisible: { visible in
                        withAnimation(ChekiMotion.small) {
                            if visible {
                                menuLiftedMemberID = member.id
                            } else if menuLiftedMemberID == member.id {
                                menuLiftedMemberID = nil
                            }
                        }
                    }
                )
            }
        }
        .albumCardLift(
            menu: menuLiftedMemberID == member.id,
            dragging: dragLiftedMemberID == member.id
        )
        .overlay {
            AlbumCardAnchor(
                id: member.id,
                registry: cardRegistry,
                isFront: menuLiftedMemberID == member.id
            )
        }
        .zIndex(menuLiftedMemberID == member.id ? 100 : 0)
    }

    private func reorderDisplayedMembers(dragged: UUID, target: UUID) {
        guard let from = displayedMembers.firstIndex(where: { $0.id == dragged }),
              let to = displayedMembers.firstIndex(where: { $0.id == target }),
              from != to else { return }
        var updated = displayedMembers
        let moved = updated.remove(at: from)
        updated.insert(moved, at: to)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sortMethodRaw = AlbumSortMethod.custom.rawValue
        for (index, member) in updated.enumerated() {
            member.sortOrder = index
        }
        try? modelContext.save()
    }

    private func trackMemberDrag(_ translation: CGSize) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            memberFloat?.translation = translation
        }
    }

    private func settleMemberDrag() {
        guard let float = memberFloat else {
            clearMemberDrag()
            return
        }
        let translation = CGSize(
            width: float.destination.x - float.origin.x,
            height: float.destination.y - float.origin.y
        )
        withAnimation(ChekiMotion.small, completionCriteria: .logicallyComplete) {
            memberFloat?.translation = translation
            memberFloat?.scale = 1
            memberFloat?.opacity = 1
        } completion: {
            clearMemberDrag()
        }
    }

    private func clearMemberDrag() {
        dragLiftedMemberID = nil
        memberFloat = nil
        DispatchQueue.main.async {
            blockAlbumOpen = false
        }
    }

    private func memberDragFloat(id: UUID, frame: CGRect) -> AlbumDragFloat? {
        guard let member = displayedMembers.first(where: { $0.id == id }) else { return nil }
        let origin = CGPoint(x: frame.minX, y: frame.minY)
        return AlbumDragFloat(
            title: member.albumTitle,
            covers: AlbumsRootView.memberCoverImages(for: member, allItems: allItems),
            isList: displayMode != .grid,
            showsDragHandle: sortMethod == .custom && displayMode != .grid,
            origin: origin,
            size: frame.size,
            translation: .zero,
            scale: AlbumCardLift.scale,
            opacity: AlbumCardLift.opacity,
            destination: origin
        )
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
    @AppStorage("chekiDateSortBasis") private var sortBasisRaw: String = ChekiDateSortBasis.judgedDate.rawValue

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
    @State private var pendingCaptureReview: CaptureReviewRequest?
    @State private var captureReviewRequest: CaptureReviewRequest?
    @State private var showingBatchPairingSheet: Bool = false
    @State private var showingRenameMemberAlert: Bool = false
    @State private var renameMemberText: String = ""
    @State private var inAppBacksideTargetItem: ChekiItem? = nil
    @State private var photosBacksideTargetItem: ChekiItem? = nil
    @State private var isShowingPhotosBacksidePicker: Bool = false

    @State private var sortAscending: Bool = false
    @State private var filterDualSideOnly: Bool = false

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

    private var sortBasis: ChekiDateSortBasis {
        ChekiDateSortBasis(rawValue: sortBasisRaw) ?? .judgedDate
    }

    private var displayedItems: [ChekiItem] {
        let source = liveItems
        let filtered = filterDualSideOnly ? source.filter(\.hasBothSides) : source
        return ChekiLibrarySort.sorted(filtered, basis: sortBasis, ascending: sortAscending)
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

    private var gridScopeID: String {
        "album-\(defaultMember?.id.uuidString ?? primaryTitle)"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground)
                .ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 6) {
                        heroHeaderView
                            .transaction { transaction in
                                transaction.animation = nil
                            }

                        if displayedItems.isEmpty && defaultMember == nil {
                            ContentUnavailableView {
                                Label(L10n.tr("尚無拍立得", "チェキなし"), systemImage: "photo.on.rectangle")
                            } description: {
                                Text(L10n.tr("由右上角 ＋ 加入拍立得", "右上の ＋ から追加"))
                            }
                            .padding(.vertical, 48)
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                                ForEach(displayedItems) { item in
                                    albumPhotoCell(for: item)
                                        .id(item.id)
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
                            .animation(ChekiMotion.layoutCommit, value: columnCount)

                            if displayedItems.isEmpty {
                                ContentUnavailableView {
                                    Label(L10n.tr("尚無拍立得", "チェキなし"), systemImage: "photo.on.rectangle")
                                } description: {
                                    Text(L10n.tr("點擊 ＋ 加入", "＋ から追加"))
                                }
                                .padding(.vertical, 28)
                            }
                        }
                    }
                    .padding(.bottom, isSelectionMode ? 96 : 40)
                }
                .simultaneousGesture(pinchZoomGesture)
                .ignoresSafeArea(edges: .top)
                .onChange(of: chromeState.activeZoomItemID) { _, newID in
                    guard let newID,
                          chromeState.activeDetailRoute?.sourceScopeID == gridScopeID,
                          displayedItems.contains(where: { $0.id == newID }) else { return }
                    let screenHeight = UIScreen.main.bounds.height
                    if let anchor = chromeState.gridCellAnchor(for: newID, scopeID: gridScopeID) {
                        if anchor.globalFrame.minY < 88 || anchor.globalFrame.maxY > screenHeight - 70 {
                            scrollProxy.scrollTo(newID, anchor: .center)
                        }
                    } else {
                        scrollProxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
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
            ToolbarItemGroup(placement: .topBarTrailing) {
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
                    }
                } else {
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: nil,
                        matching: .images,
                        preferredItemEncoding: .automatic,
                        photoLibrary: .shared()
                    ) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("相簿")

                    Menu {
                        Button {
                            showingCameraScanner = true
                        } label: {
                            CameraAddLabel()
                        }

                        PhotosPicker(
                            selection: $selectedPhotos,
                            maxSelectionCount: nil,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            AlbumImportLabel()
                        }

                        if let defaultMember {
                            Button {
                                renameMemberText = defaultMember.stageName
                                showingRenameMemberAlert = true
                            } label: {
                                Label(L10n.tr("成員名", "メンバー名"), systemImage: "pencil")
                            }
                        }

                        Menu {
                            ForEach(GridPinchZoom.columnCounts, id: \.self) { count in
                                Button {
                                    withAnimation(ChekiMotion.layoutCommit) {
                                        columnCount = count
                                    }
                                } label: {
                                    Label(L10n.tr("\(count) 欄", "\(count) 列"), systemImage: columnCount == count ? "checkmark" : "square.grid.3x3")
                                }
                            }
                        } label: {
                            Label(L10n.tr("顯示密度", "表示密度"), systemImage: "square.grid.3x3")
                        }

                        Menu {
                            Button {
                                sortBasisRaw = ChekiDateSortBasis.judgedDate.rawValue
                            } label: {
                                Label(
                                    ChekiDateSortBasis.judgedDate.menuTitle,
                                    systemImage: sortBasis == .judgedDate ? "checkmark" : "calendar"
                                )
                            }
                            Button {
                                sortBasisRaw = ChekiDateSortBasis.originalCaptureDate.rawValue
                            } label: {
                                Label(
                                    ChekiDateSortBasis.originalCaptureDate.menuTitle,
                                    systemImage: sortBasis == .originalCaptureDate ? "checkmark" : "camera"
                                )
                            }
                            Divider()
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
                                Label(L10n.tr("僅雙面", "両面のみ"), systemImage: filterDualSideOnly ? "checkmark" : "rectangle.portrait.on.rectangle.portrait")
                            }
                        } label: {
                            Label(L10n.tr("排序", "並び順"), systemImage: "line.3.horizontal.decrease")
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
                    .accessibilityLabel("更多")
                }

                if !displayedItems.isEmpty {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(ChekiMotion.toggle) {
                            isSelectionMode.toggle()
                            if !isSelectionMode {
                                selectedItemIDs.removeAll()
                            }
                        }
                    } label: {
                        if isSelectionMode {
                            Image(systemName: "xmark")
                        } else {
                            Text("選取")
                                .font(.subheadline.weight(.semibold))
                        }
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
            L10n.tr("刪除 \(selectedItemIDs.count) 張照片？", "\(selectedItemIDs.count)枚の写真を削除しますか？"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("刪除 \(selectedItemIDs.count) 張", "\(selectedItemIDs.count)枚を削除"), role: .destructive) {
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
                    ? L10n.tr("將從典藏庫與系統相簿刪除。", "ライブラリと写真アプリから削除されます。")
                    : L10n.tr("將從典藏庫移除且無法復原。", "ライブラリから削除され、元に戻せません。")
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
            let pending = pendingCaptureReview
            pendingCaptureReview = nil
            CaptureReviewPresentation.presentAfterCameraDismiss(hasItems: pending != nil) {
                captureReviewRequest = pending
            }
            if autoSyncToPhotos {
                Task {
                    await syncCurrentAlbumToPhotosLibrary(forceFullSync: false)
                }
            }
        }) {
            CameraScannerView(defaultMember: defaultMember) { photos in
                guard !photos.isEmpty else { return }
                pendingCaptureReview = CaptureReviewRequest(photos: photos, member: defaultMember)
            }
        }
        .sheet(item: $captureReviewRequest) { request in
            BatchPairingView(
                initialSessionPhotos: request.photos,
                defaultMember: request.member
            )
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
        .chekiBacksidePickerModals(
            inAppTargetItem: $inAppBacksideTargetItem,
            photosTargetItem: $photosBacksideTargetItem,
            isShowingPhotosPicker: $isShowingPhotosBacksidePicker
        )
        .alert(
            L10n.tr("成員名", "メンバー名"),
            isPresented: $showingRenameMemberAlert
        ) {
            TextField(L10n.tr("成員名稱", "メンバー名"), text: $renameMemberText)
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

    private var pinchZoomGesture: some Gesture {
        GridPinchZoom.gesture(
            columnCount: $columnCount,
            liveScale: $livePinchScale,
            baseline: $pinchBaselineColumnCount
        )
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
                        Text(L10n.tr("\(displayedItems.count) 張", "\(displayedItems.count)枚"))
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.top, 2)
                }
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)

                Spacer()

                if let firstItem = displayedItems.first {
                    Button {
                        NavigationChromeState.shared.presentDetail(
                            ChekiDetailRoute(
                                itemID: firstItem.id,
                                scopedItemIDs: displayedItems.map(\.id),
                                sourceScopeID: gridScopeID
                            )
                        )
                    } label: {
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
        .accessibilityLabel(L10n.tr("加入照片", "写真を追加"))
    }

    @ViewBuilder
    private func albumPhotoCell(for item: ChekiItem) -> some View {
        let isSelected = selectedItemIDs.contains(item.persistentModelID)
        if isSelectionMode {
            AlbumSquareThumbnailCell(item: item, cornerRadius: cellCornerRadius, scopeID: gridScopeID)
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
            Button {
                NavigationChromeState.shared.presentDetail(
                    ChekiDetailRoute(
                        itemID: item.id,
                        scopedItemIDs: displayedItems.map(\.id),
                        sourceScopeID: gridScopeID
                    )
                )
            } label: {
                AlbumSquareThumbnailCell(item: item, cornerRadius: cellCornerRadius, scopeID: gridScopeID)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Menu {
                    MemberAssignmentMenuContent(item: item) { showingQuickCreateMember = true }
                } label: {
                    Label(L10n.tr("成員", "メンバー"), systemImage: "person.crop.circle")
                }
                .menuActionDismissBehavior(.disabled)

                ChekiBacksideAssignmentMenu(
                    item: item,
                    onSelectInAppPhoto: {
                        inAppBacksideTargetItem = item
                    },
                    onSelectSystemPhoto: {
                        photosBacksideTargetItem = item
                        isShowingPhotosBacksidePicker = true
                    }
                )

                Divider()

                Button(role: .destructive) {
                    Task { @MainActor in
                        await PhotoLibraryManager.shared.deleteItemsAsync([item], modelContext: modelContext)
                    }
                } label: {
                    Label(L10n.tr("刪除", "削除"), systemImage: "trash")
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
                prompt: L10n.tr("成員、團體、#標籤", "メンバー・グループ・#タグ")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.tr("取消", "キャンセル"))
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $pickerTab) {
                        ForEach(PickerTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        commitPickedItems()
                    } label: {
                        if selectedItemIDs.isEmpty {
                            Image(systemName: "checkmark")
                        } else {
                            Text("\(selectedItemIDs.count)")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                    }
                    .disabled(selectedItemIDs.isEmpty)
                    .accessibilityLabel(L10n.tr("加入", "追加"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Text(
                        selectedItemIDs.isEmpty
                            ? L10n.tr("加入 \(targetMember.stageName)", "\(targetMember.stageName) に追加")
                            : L10n.tr("已選 \(selectedItemIDs.count) 張", "\(selectedItemIDs.count)枚選択中")
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
                    withAnimation(ChekiMotion.toggle) {
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
                    .background {
                        if filterUncategorizedOnly {
                            Capsule().fill(Color.accentColor)
                        }
                    }
                    .modifier(OptionalLiquidGlassCapsuleModifier(isEnabled: !filterUncategorizedOnly))
                }
                .buttonStyle(.plain)

                Menu {
                    MemberHierarchyMenuContent(
                        selectedMemberIDs: filterMemberIDs,
                        showsUncategorizedOption: !filterMemberIDs.isEmpty,
                        uncategorizedTitle: L10n.tr("清除", "クリア"),
                        uncategorizedIcon: "xmark.circle",
                        isUncategorizedDestructive: true,
                        onToggleMember: { member in
                            toggleFilterMember(member.id)
                        },
                        onClearSelection: {
                            filterMemberIDs.removeAll()
                        },
                        onCreateMember: nil
                    )
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.2")
                            .font(.caption.weight(.semibold))
                        Text(
                            filterMemberIDs.isEmpty
                                ? L10n.tr("成員", "メンバー")
                                : L10n.tr("成員 · \(filterMemberIDs.count)", "メンバー · \(filterMemberIDs.count)")
                        )
                        .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(!filterMemberIDs.isEmpty ? .white : .primary)
                    .background {
                        if !filterMemberIDs.isEmpty {
                            Capsule().fill(Color.accentColor)
                        }
                    }
                    .modifier(OptionalLiquidGlassCapsuleModifier(isEnabled: filterMemberIDs.isEmpty))
                }
                .menuActionDismissBehavior(.disabled)

                if filterUncategorizedOnly || !filterMemberIDs.isEmpty {
                    Button {
                        withAnimation(ChekiMotion.toggle) {
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
                withAnimation(ChekiMotion.toggle) {
                    browseAlbumScope = nil
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.tr("相冊", "アルバム"))
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
                Label(L10n.tr("無符合項目", "該当なし"), systemImage: "photo.on.rectangle")
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
                                    Text(L10n.tr("已加入", "追加済"))
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
                            .animation(ChekiMotion.toggle, value: isSelected)
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
                        Text(L10n.tr("成員", "メンバー"))
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
                        Text(L10n.tr("團體", "グループ"))
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
    var scopeID: String? = nil
    private var chromeState = NavigationChromeState.shared

    var body: some View {
        let isValid = !item.isDeleted && item.modelContext != nil
        let isHiddenForZoom = chromeState.isGridCellHidden(itemID: item.id, scopeID: scopeID)

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
            .opacity(isHiddenForZoom ? 0.0 : 1.0)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newFrame in
                guard let scopeID else { return }
                NavigationChromeState.shared.updateGridCellAnchor(
                    itemID: item.id,
                    scopeID: scopeID,
                    globalFrame: newFrame,
                    cornerRadius: cornerRadius,
                    isSquareCropped: true
                )
            }
    }
}

// MARK: - 6. LibrarySearchView (底部右側圓形「🔍 搜尋」Tab)

struct LibrarySearchView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]
    @AppStorage("chekiDateSortBasis") private var sortBasisRaw: String = ChekiDateSortBasis.judgedDate.rawValue

    @State private var searchText: String = ""
    @State private var showingSettingsSheet: Bool = false
    @State private var showingQuickCreateSheet: Bool = false
    @State private var inAppBacksideTargetItem: ChekiItem? = nil
    @State private var photosBacksideTargetItem: ChekiItem? = nil
    @State private var isShowingPhotosBacksidePicker: Bool = false
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
        let matched = validChekiItems.filter { LibraryView.matchesSearch(item: $0, query: searchText, allMembers: idolMembers) }
        let basis = ChekiDateSortBasis(rawValue: sortBasisRaw) ?? .judgedDate
        return ChekiLibrarySort.sorted(matched, basis: basis, ascending: false)
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
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if searchText.isEmpty {
                            if !availableHashtags.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(L10n.tr("#標籤", "#タグ"))
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
                                    Text(L10n.tr("成員", "メンバー"))
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
                            Text(L10n.tr("\(filteredItems.count) 張", "\(filteredItems.count)枚"))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)

                            LazyVGrid(columns: threeColumns, spacing: 10) {
                                ForEach(filteredItems) { item in
                                    searchPhotoGridCell(for: item)
                                        .id(item.id)
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: chromeState.activeZoomItemID) { _, newID in
                    guard let newID,
                          chromeState.activeDetailRoute?.sourceScopeID == "library-search",
                          filteredItems.contains(where: { $0.id == newID }) else { return }
                    let screenHeight = UIScreen.main.bounds.height
                    if let anchor = chromeState.gridCellAnchor(for: newID, scopeID: "library-search") {
                        if anchor.globalFrame.minY < 88 || anchor.globalFrame.maxY > screenHeight - 70 {
                            scrollProxy.scrollTo(newID, anchor: .center)
                        }
                    } else {
                        scrollProxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("搜尋")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(chromeState.shouldHideMainTabBar ? .hidden : .visible, for: .tabBar)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.tr("成員、團體、#標籤", "メンバー・グループ・#タグ")
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
            .sheet(isPresented: $showingQuickCreateSheet) {
                QuickCreateIdolSheet()
            }
            .chekiBacksidePickerModals(
                inAppTargetItem: $inAppBacksideTargetItem,
                photosTargetItem: $photosBacksideTargetItem,
                isShowingPhotosPicker: $isShowingPhotosBacksidePicker
            )
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

    @ViewBuilder
    private func searchPhotoGridCell(for item: ChekiItem) -> some View {
        Button {
            NavigationChromeState.shared.presentDetail(
                ChekiDetailRoute(
                    itemID: item.id,
                    scopedItemIDs: filteredItems.map(\.id),
                    sourceScopeID: "library-search"
                )
            )
        } label: {
            AppleLibraryPhotoCell(item: item, cornerRadius: 9, scopeID: "library-search")
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu {
                MemberAssignmentMenuContent(item: item) { showingQuickCreateSheet = true }
            } label: {
                Label(L10n.tr("成員", "メンバー"), systemImage: "person.crop.circle")
            }
            .menuActionDismissBehavior(.disabled)

            ChekiBacksideAssignmentMenu(
                item: item,
                onSelectInAppPhoto: {
                    inAppBacksideTargetItem = item
                },
                onSelectSystemPhoto: {
                    photosBacksideTargetItem = item
                    isShowingPhotosBacksidePicker = true
                }
            )

            Divider()

            Button(role: .destructive) {
                Task { @MainActor in
                    await PhotoLibraryManager.shared.deleteItemsAsync([item], modelContext: modelContext)
                }
            } label: {
                Label(L10n.tr("刪除", "削除"), systemImage: "trash")
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
                Section(L10n.tr("成員與團體", "メンバー・グループ")) {
                    TextField("姓名", text: $stageName)
                    TextField("團體", text: $groupName)
                    TextField("標籤", text: $tagsText)
                }

                if !groups.isEmpty {
                    Section(L10n.tr("現有團體", "既存グループ")) {
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
            .navigationTitle(L10n.tr("團體 / 成員", "グループ / メンバー"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseToolbarButton { dismiss() }
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
                    item.applyAutomaticJudgedDate(recognizedDate, preservingTimeFrom: item.appOriginalCaptureDate)
                }
                item.processingState = .completed
            }
        } catch {
            let manager = VisionManager()
            let recognizedDate = await manager.recognizeDate(from: cgImage)?.date
            await MainActor.run {
                if let recognizedDate {
                    item.applyAutomaticJudgedDate(recognizedDate, preservingTimeFrom: item.appOriginalCaptureDate)
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
            // 左下圓形液態玻璃分享按鈕
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: ChromeMetrics.iconPointSize, weight: .semibold))
                    .darkSystemCircleChrome(size: ChromeMetrics.circle)
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)
            .accessibilityLabel("分享")
            .accessibilityIdentifier(ChromeID.librarySelectionShare)

            Spacer()

            // 中央已選取張數狀態文字（對齊 Apple 原生相簿「2枚選択中 / 已選 N 張」）
            Text(selectedCount == 0 ? L10n.tr("選擇項目", "項目を選択") : L10n.tr("已選 \(selectedCount) 張", "\(selectedCount)枚選択中"))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(ChekiMotion.toggle, value: selectedCount)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)

            Spacer()

            // 右下圓形液態玻璃刪除按鈕
            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: ChromeMetrics.iconPointSize, weight: .semibold))
                    .darkSystemCircleChrome(size: ChromeMetrics.circle)
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)
            .accessibilityLabel("刪除")
            .accessibilityIdentifier(ChromeID.librarySelectionDelete)
        }
        .padding(.horizontal, ChromeMetrics.edgeHorizontal)
        .padding(.top, 10)
        .padding(.bottom, ChromeMetrics.edgeBottom)
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

/// 仿照 Apple 原生相簿的拖選多選覆蓋層。照片格用欄數與長寬比命中；相冊封面用 `frameProvider` 讀卡片的即時位置。
/// - 單指點擊：切換該格的選取
/// - 單指橫向或斜向滑動：從起點格到目前格做範圍選取或取消
/// - 單指垂直滑動：不攔截，交給外層 `ScrollView`
private struct ApplePhotosDragSelectOverlay<ID: Hashable>: UIViewRepresentable {
    let itemIDs: [ID]
    let columnCount: Int
    let spacing: CGFloat
    let cellAspectRatio: CGFloat
    var frameProvider: ((UIView) -> [ID: CGRect])? = nil
    @Binding var selectedItemIDs: Set<ID>

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: proposal.height ?? uiView.bounds.height)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.itemIDs = itemIDs.map(AnyHashable.init)
        coordinator.columnCount = columnCount
        coordinator.spacing = spacing
        coordinator.cellAspectRatio = cellAspectRatio
        coordinator.selected = Set(selectedItemIDs.map(AnyHashable.init))
        if let frameProvider {
            coordinator.frameProvider = { view in
                var frames: [AnyHashable: CGRect] = [:]
                for (id, frame) in frameProvider(view) {
                    frames[AnyHashable(id)] = frame
                }
                return frames
            }
        } else {
            coordinator.frameProvider = nil
        }
        coordinator.onChange = { updated in
            var next = Set<ID>()
            next.reserveCapacity(updated.count)
            for value in updated {
                if let id = value.base as? ID {
                    next.insert(id)
                }
            }
            if next != selectedItemIDs {
                selectedItemIDs = next
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var itemIDs: [AnyHashable] = []
        var frameProvider: ((UIView) -> [AnyHashable: CGRect])?
        var columnCount = 1
        var spacing: CGFloat = 0
        var cellAspectRatio: CGFloat = 1
        var selected: Set<AnyHashable> = []
        var onChange: (Set<AnyHashable>) -> Void = { _ in }

        private var dragStartIndex: Int?
        private var lastDraggedIndex: Int?
        private var dragIsSelecting: Bool = true
        private var dragBaselineSelection: Set<AnyHashable> = []
        private let feedbackGenerator = UISelectionFeedbackGenerator()

        private func itemIndex(at point: CGPoint, in view: UIView, clampToBounds: Bool) -> Int? {
            if frameProvider != nil {
                return frameIndex(at: point, in: view, clampToBounds: clampToBounds)
            }
            return geometricIndex(at: point, in: view.bounds.size, clampToBounds: clampToBounds)
        }

        private func geometricIndex(at point: CGPoint, in boundsSize: CGSize, clampToBounds: Bool) -> Int? {
            let count = itemIDs.count
            guard count > 0, boundsSize.width > 1 else { return nil }

            let cols = max(1, columnCount)
            let totalHSpacing = CGFloat(cols - 1) * spacing
            let cellWidth = max(1, (boundsSize.width - totalHSpacing) / CGFloat(cols))
            let cellHeight = max(1, cellWidth / max(0.1, cellAspectRatio))

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

        private func frameIndex(at point: CGPoint, in view: UIView, clampToBounds: Bool) -> Int? {
            guard !itemIDs.isEmpty, let frames = frameProvider?(view) else { return nil }
            for (index, id) in itemIDs.enumerated() {
                if let frame = frames[id], frame.contains(point) {
                    return index
                }
            }
            guard clampToBounds else { return nil }
            var best: (index: Int, distance: CGFloat)?
            for (index, id) in itemIDs.enumerated() {
                guard let frame = frames[id] else { continue }
                let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
                let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
                let distance = dx * dx + dy * dy
                if best == nil || distance < best!.distance {
                    best = (index, distance)
                }
            }
            return best?.index
        }

        private func publish(_ updated: Set<AnyHashable>) {
            guard updated != selected else { return }
            selected = updated
            onChange(updated)
            feedbackGenerator.selectionChanged()
            feedbackGenerator.prepare()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let view = gesture.view,
                  let index = itemIndex(at: gesture.location(in: view), in: view, clampToBounds: false),
                  itemIDs.indices.contains(index) else {
                return
            }
            let id = itemIDs[index]
            var updated = selected
            if updated.contains(id) {
                updated.remove(id)
            } else {
                updated.insert(id)
            }
            publish(updated)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }

            switch gesture.state {
            case .began:
                let currentPoint = gesture.location(in: view)
                let translation = gesture.translation(in: view)
                let touchDownPoint = CGPoint(
                    x: currentPoint.x - translation.x,
                    y: currentPoint.y - translation.y
                )
                guard let startIdx = itemIndex(at: touchDownPoint, in: view, clampToBounds: true),
                      itemIDs.indices.contains(startIdx) else {
                    return
                }
                dragStartIndex = startIdx
                lastDraggedIndex = nil
                dragIsSelecting = !selected.contains(itemIDs[startIdx])
                dragBaselineSelection = selected
                feedbackGenerator.prepare()
                applyDragSelection(at: currentPoint, in: view)

            case .changed:
                applyDragSelection(at: gesture.location(in: view), in: view)

            case .ended, .cancelled, .failed:
                dragStartIndex = nil
                lastDraggedIndex = nil
                dragBaselineSelection = []

            default:
                break
            }
        }

        private func applyDragSelection(at point: CGPoint, in view: UIView) {
            guard let startIdx = dragStartIndex,
                  let currentIdx = itemIndex(at: point, in: view, clampToBounds: true) else {
                return
            }
            guard currentIdx != lastDraggedIndex else { return }
            lastDraggedIndex = currentIdx

            let lower = min(startIdx, currentIdx)
            let upper = max(startIdx, currentIdx)
            var updated = dragBaselineSelection

            for index in lower...upper where itemIDs.indices.contains(index) {
                let id = itemIDs[index]
                if dragIsSelecting {
                    updated.insert(id)
                } else {
                    updated.remove(id)
                }
            }

            publish(updated)
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
