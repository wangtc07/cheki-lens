import SwiftUI
import SwiftData
import Photos
import PhotosUI
import UIKit

// MARK: - ChekiDetailView (Task 4.5: 05. 写真詳細 單張全螢幕檢視 — 嚴格遵循 Apple iOS 18 原生相簿設計)

/// 單張拍立得全螢幕檢視器（對齊 iOS 18 Apple 原生「照片」單張檢視介面）
/// - 頂部：左側圓形毛玻璃返回鈕、中央半透明「日期時間藥丸 (`9月17日 · 16:26`)」、右側圓形 `⋯` 更多選單
/// - 中央：支援 3D Y 軸 180° 翻轉動畫（查看背面手寫簽名）、雙指縮放、左右滑動切換上/下一張、向上滑動呼出資訊面板
/// - 底部：縮圖膠卷滾動條 (Filmstrip Scrubber) ＋ Apple 標準 5 大工具列按鈕（分享、愛心、ℹ️、調整、垃圾桶）
// MARK: - ChekiDetailRoute (Value-type navigation route to prevent NavigationStack from holding deleted @Model references)

struct ChekiDetailRoute: Hashable {
    let itemID: UUID
    let scopedItemIDs: [UUID]?
    let sourceScopeID: String?

    init(itemID: UUID, scopedItemIDs: [UUID]? = nil, sourceScopeID: String? = nil) {
        self.itemID = itemID
        self.scopedItemIDs = scopedItemIDs
        self.sourceScopeID = sourceScopeID
    }
}

struct ChekiDetailView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var allChekiItems: [ChekiItem]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]
    @AppStorage("hasSeenDetailCoachMark") private var hasSeenDetailCoachMark: Bool = false

    /// 初始點進來的拍立得 UUID（不直接持有 `@Model` 強引用，避免刪除後 SwiftData 觸發已刪除物件 Fault 閃退）
    private let initialItemID: UUID
    /// 從相冊、搜尋或特定篩選排序點進來時的「限定範圍與排序 ID 列表」（Task 6.5.9：確保左右滑動與底部膠卷僅顯示該相冊內容與當前排序）
    private let scopedItemIDs: [UUID]?
    /// 來源一覽網格識別碼（Task 6.5.11：定位底層一覽中對應相片格位的全螢幕座標與圓角）
    private let sourceScopeID: String?

    /// 當前正在檢視的拍立得（透過底部縮圖膠卷或左右滑動可即時切換）
    @State private var showingQuickCreateMember: Bool = false
    @State private var currentItemID: UUID?
    /// 上一張檢視的拍立得 ID（確保跨張點擊縮圖時離場卡片也能平滑滑動）
    @State private var previousItemID: UUID?
    /// 已標記刪除的拍立得 ID 集合（在 SwiftData context.delete 前先行由視圖樹排除）
    @State private var deletedItemIDs: Set<UUID> = []
    /// 是否正在執行刪除程序
    @State private var isDeletingItem: Bool = false
    /// 是否翻轉至背面（true = 顯示背面手寫簽名，false = 顯示正面照片）
    @State private var isShowingBack: Bool = false
    /// 3D 翻轉連續動畫進度（0.0 = 正面 0°，1.0 = 背面 180°，供 Animatable 連續插值與 Z 軸浮起使用）
    @State private var flipProgress: Double = 0.0
    /// 點擊單下隱藏/顯示上下工具列（沉浸式全螢幕檢視）
    @State private var isChromeHidden: Bool = false

    /// 左右滑動跟手偏移量（1:1 跟隨手指水平滑動）
    @State private var horizontalDragOffset: CGFloat = 0
    /// 拖曳方向鎖定（區分水平切換相片 vs 垂直呼出備忘/返回）
    @State private var dragAxisLock: Axis? = nil

    /// Task 6.5.11: 下滑取消回到一覽時的跟手位移縮小與放開縮回原格位動畫狀態（對齊 iOS 系統相簿互動過渡）
    @State private var isAnimatingOpenFromGrid: Bool
    @State private var isDraggingDownToDismiss: Bool = false
    @State private var dismissDragOffset: CGSize = .zero
    @State private var isAnimatingDismissToGrid: Bool = false
    @State private var fallbackFadeOutDismiss: Bool = false

    /// 雙指縮放倍率與放大後平移偏移量
    @State private var zoomScale: CGFloat = 1.0
    @State private var activePinchScale: CGFloat = 1.0
    @State private var zoomPanOffset: CGSize = .zero
    @State private var activeZoomPanDelta: CGSize = .zero
    /// 記錄開始雙指放大時是否處於全畫面模式（確保放大後單擊切換 icon 時，圖片位置與倍率 100% 鎖定不跳動）
    @State private var isZoomedFromFullScreen: Bool = false

    /// 彈窗與面板控制
    @State private var showingInfoSheet: Bool = false
    @State private var showingAdjustmentSheet: Bool = false
    @State private var showDeleteConfirm: Bool = false

    /// Task 6.5.8: 點選白色部分自動校正白平衡（Core Image CITemperatureAndTint 色溫／色調）狀態
    @State private var isWhiteBalancePickerActive: Bool = false
    @State private var whiteBalanceTapNormalizedPoint: CGPoint? = nil
    @State private var whiteBalanceSummaryText: String? = nil
    @State private var preWhiteBalanceFrontDataByItemID: [UUID: Data] = [:]
    @State private var preWhiteBalanceBackDataByItemID: [UUID: Data] = [:]

    /// 補上/替換背面照片的 PhotosPicker 與 App 內選擇器
    @State private var backsidePickerItem: PhotosPickerItem? = nil
    @State private var isShowingBacksidePicker: Bool = false
    @State private var showingInAppBacksidePicker: Bool = false

    /// Task 5.4: Mode B 雙角度去反光合成第二角度照片選擇器 (Pro 專屬)
    @State private var modeBSecondAnglePickerItem: PhotosPickerItem? = nil
    @State private var isShowingModeBSecondAnglePicker: Bool = false

    /// 同步至系統相簿提示
    @State private var syncStatusToast: String? = nil
    @State private var detailViewInstanceID = UUID()

    init(itemID: UUID, scopedItemIDs: [UUID]? = nil, sourceScopeID: String? = nil) {
        self.initialItemID = itemID
        self.scopedItemIDs = scopedItemIDs
        self.sourceScopeID = sourceScopeID
        _currentItemID = State(initialValue: itemID)
        let hasAnchor = NavigationChromeState.shared.gridCellAnchor(for: itemID, scopeID: sourceScopeID) != nil
        _isAnimatingOpenFromGrid = State(initialValue: hasAnchor)
    }

    init(item: ChekiItem, scopedItemIDs: [UUID]? = nil, sourceScopeID: String? = nil) {
        let id = item.id
        self.initialItemID = id
        self.scopedItemIDs = scopedItemIDs
        self.sourceScopeID = sourceScopeID
        _currentItemID = State(initialValue: id)
        let hasAnchor = NavigationChromeState.shared.gridCellAnchor(for: id, scopeID: sourceScopeID) != nil
        _isAnimatingOpenFromGrid = State(initialValue: hasAnchor)
    }

    /// 典藏庫中所有有效項目（供「從 App 內選取背面」跨相冊挑選使用）
    private var allValidLibraryItems: [ChekiItem] {
        allChekiItems
            .filter { !$0.isDeleted && $0.modelContext != nil && !deletedItemIDs.contains($0.id) }
            .sorted { $0.displayDate > $1.displayDate }
    }

    /// 膠卷滾動條與左右滑動中的所有有效項目：
    /// - 若有傳入 `scopedItemIDs`（例如從指定相冊點開），嚴格依照該相冊內的項目與其當前排序呈現；
    /// - 否則預設顯示全部有效項目（依顯示日期由新到舊）。
    private var filmstripItems: [ChekiItem] {
        let validItems = allChekiItems
            .filter { !$0.isDeleted && $0.modelContext != nil && !deletedItemIDs.contains($0.id) }
        if let scopedItemIDs, !scopedItemIDs.isEmpty {
            let itemByID = Dictionary(uniqueKeysWithValues: validItems.map { ($0.id, $0) })
            let scopedOrdered = scopedItemIDs.compactMap { itemByID[$0] }
            if !scopedOrdered.isEmpty {
                return scopedOrdered
            }
        }
        return validItems.sorted { $0.displayDate > $1.displayDate }
    }

    /// 目前選中的索引位置
    private var currentIndex: Int {
        let items = filmstripItems
        guard !items.isEmpty else { return 0 }
        if let id = currentItemID,
           let idx = items.firstIndex(where: { $0.id == id }) {
            return idx
        }
        return items.firstIndex(where: { $0.id == initialItemID }) ?? 0
    }

    /// 目前選中的有效 `ChekiItem?`（若最後一張剛被刪除則為 `nil`）
    private var currentItemOpt: ChekiItem? {
        let items = filmstripItems
        guard !items.isEmpty else { return nil }
        let idx = currentIndex
        if items.indices.contains(idx) {
            return items[idx]
        }
        return items.first
    }

    /// 目前選中的 `ChekiItem`（僅在確認 `currentItemOpt != nil` 的視圖分支中呼叫）
    private var currentItem: ChekiItem {
        currentItemOpt!
    }

    /// 是否已加入「最愛」（以備忘錄中含有 `#最愛` 或 `#お気に入り` 判定）
    private var isFavorite: Bool {
        guard let active = currentItemOpt,
              let tags = active.memo?.hashtags else { return false }
        return tags.contains { $0 == "#最愛" || $0 == "最愛" || $0 == "#お気に入り" }
    }

    /// 當前圖片是否處於放大狀態
    private var isImageZoomed: Bool {
        (zoomScale * activePinchScale) > 1.002
    }

    /// 是否正處於「貼齊底層一覽格位（剛點開起點 或 放開手指縮回原格位終點）」狀態
    private var isCardDockedToGridCell: Bool {
        isAnimatingOpenFromGrid || isAnimatingDismissToGrid
    }

    /// 是否隱藏頂部與底部導覽列/膠卷（沉浸模式、下滑跟手縮小中、或縮回一覽格位動畫中）
    private var shouldHideOverlayChrome: Bool {
        isChromeHidden || isDraggingDownToDismiss || isCardDockedToGridCell || fallbackFadeOutDismiss
    }

    /// 黑色背景不透明度（下滑期間隨手指距離漸淡透出底層相冊一覽，放開縮回格位時平滑淡出至 0）
    private var backdropOpacity: Double {
        if isCardDockedToGridCell || fallbackFadeOutDismiss {
            return 0.0
        }
        if isDraggingDownToDismiss {
            let dragY = max(0, dismissDragOffset.height)
            let progress = min(1.0, Double(dragY / 280.0))
            return max(0.12, 1.0 - progress * 0.85)
        }
        return 1.0
    }

    /// 下滑跟手期間的即時縮放比例（隨手指下滑距離平滑縮小）
    private var interactiveDismissDragScale: CGFloat {
        guard isDraggingDownToDismiss else { return 1.0 }
        let dragY = max(0, dismissDragOffset.height)
        let progress = min(1.0, dragY / 320.0)
        return 1.0 - progress * 0.46
    }

    private func gridAnchor(for itemID: UUID) -> GridCellAnchor? {
        NavigationChromeState.shared.gridCellAnchor(for: itemID, scopeID: sourceScopeID)
    }

    var body: some View {
        ZStack {
            // 1. 全黑沉浸式背景（符合 Apple Photos 單張檢視暗色模式；下滑返回時隨手指漸淡透出底層一覽）
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            if let activeItem = currentItemOpt {
                // 2. 主拍立得卡片檢視區（直接套用 .ignoresSafeArea() 於 GeometryReader，確保全顯示時 100% 填滿全畫面）
                GeometryReader { fullScreenGeo in
                    let isLandscape = fullScreenGeo.size.width > fullScreenGeo.size.height
                    let viewportGlobalFrame = fullScreenGeo.frame(in: .global)
                    mainCardViewport(
                        fullScreenSize: fullScreenGeo.size,
                        viewportGlobalFrame: viewportGlobalFrame,
                        isLandscape: isLandscape
                    )
                }
                .ignoresSafeArea()

                // 3. 頂部與底部懸浮控制介面（常駐視圖樹並以 opacity/offset 漸進漸出動畫切換，根除視圖重建造成的單擊抖動）
                GeometryReader { overlayGeo in
                    let isLandscape = overlayGeo.size.width > overlayGeo.size.height
                    VStack(spacing: 0) {
                        topOverlayNavigationBar(isLandscape: isLandscape)
                            .opacity(shouldHideOverlayChrome ? 0.0 : 1.0)
                            .offset(y: shouldHideOverlayChrome ? -18 : 0)

                        Spacer(minLength: 0)

                        if isWhiteBalancePickerActive {
                            whiteBalanceInstructionBanner
                                .padding(.bottom, 8)
                                .opacity(shouldHideOverlayChrome ? 0.0 : 1.0)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if !hasSeenDetailCoachMark && !isLandscape {
                            detailCoachMarkBanner
                                .padding(.bottom, 6)
                                .opacity(shouldHideOverlayChrome ? 0.0 : 1.0)
                        }

                        bottomControlsStack(isLandscape: isLandscape, containerWidth: overlayGeo.size.width)
                            .opacity(shouldHideOverlayChrome ? 0.0 : 1.0)
                            .offset(y: shouldHideOverlayChrome ? 22 : 0)
                    }
                    .frame(width: overlayGeo.size.width, height: overlayGeo.size.height)
                }
                .allowsHitTesting(!shouldHideOverlayChrome)

                Color.clear
                    .frame(width: 0, height: 0)
                    .task(id: activeItem.id) {
                        let didSyncExternal = await PhotoLibraryManager.shared.syncExternalEditsFromSystemPhotoLibrary(
                            for: activeItem,
                            modelContext: modelContext
                        )
                        if didSyncExternal {
                            showToast(L10n.tr("已同步系統相簿修改", "写真アプリの編集を同期しました"))
                        }
                        await ensureCoverDateAndFormatNormalized(for: activeItem)
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        guard newPhase == .active else { return }
                        Task {
                            let didSync = await PhotoLibraryManager.shared.syncExternalEditsFromSystemPhotoLibrary(
                                for: activeItem,
                                modelContext: modelContext
                            )
                            if didSync {
                                showToast(L10n.tr("已同步系統相簿修改", "写真アプリの編集を同期しました"))
                            }
                        }
                    }
            }

            if let toast = syncStatusToast {
                VStack {
                    Spacer()
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 90)
                }
                .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            if NavigationChromeState.shared.activeDetailRoute == nil {
                NavigationChromeState.shared.registerDetail(detailViewInstanceID)
            }
            if isAnimatingOpenFromGrid {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                    isAnimatingOpenFromGrid = false
                }
            }
        }
        .onDisappear {
            NavigationChromeState.shared.unregisterDetail(detailViewInstanceID)
        }
        .photosPicker(
            isPresented: $isShowingBacksidePicker,
            selection: $backsidePickerItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: backsidePickerItem) { _, newPickerItem in
            guard let newPickerItem else { return }
            backsidePickerItem = nil
            Task { await attachBacksidePhoto(from: newPickerItem) }
        }
        .photosPicker(
            isPresented: $isShowingModeBSecondAnglePicker,
            selection: $modeBSecondAnglePickerItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: modeBSecondAnglePickerItem) { _, newPickerItem in
            guard let newPickerItem else { return }
            modeBSecondAnglePickerItem = nil
            Task { await synthesizeModeBSecondAnglePhoto(from: newPickerItem) }
        }
        .sheet(isPresented: $showingQuickCreateMember) {
            QuickCreateIdolSheet()
        }
        .sheet(isPresented: $showingInfoSheet) {
            if let activeItem = currentItemOpt {
                NavigationStack {
                    ChekiInfoView(item: activeItem)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showingInAppBacksidePicker) {
            if let activeItem = currentItemOpt {
                InAppBacksidePickerSheet(
                    targetItem: activeItem,
                    candidates: allValidLibraryItems.filter { $0.id != activeItem.id },
                    onSelectItem: { selectedSource, mergeAndRemoveSource in
                        attachBacksideFromInAppItem(selectedSource, mergeAndRemoveSource: mergeAndRemoveSource)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(isPresented: $showingAdjustmentSheet) {
            if let activeItem = currentItemOpt {
                ChekiQuadCropEditorView(
                    item: activeItem,
                    initialEditingBackside: isShowingBack && activeItem.hasBothSides,
                    onRequestBacksidePicker: {
                        showingAdjustmentSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            isShowingBacksidePicker = true
                        }
                    },
                    onAppliedToast: { msg in
                        showToast(msg)
                    }
                )
            }
        }
        .confirmationDialog(
            L10n.tr("刪除此照片？", "この写真を削除しますか？"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("刪除", "削除"), role: .destructive) {
                deleteCurrentItem()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                PhotoLibraryManager.shouldSyncDeleteFromSystemPhotoLibrary(for: currentItemOpt)
                    ? L10n.tr("將從典藏庫與系統相簿刪除。", "ライブラリと写真アプリから削除されます。")
                    : L10n.tr("將從典藏庫永久移除。", "ライブラリから完全に削除されます。")
            )
        }
    }

    // MARK: - 1. 頂部懸浮導覽列與「日期時間藥丸」 (Apple iOS 18 Photos Header)

    private func topOverlayNavigationBar(isLandscape: Bool) -> some View {
        let buttonSize: CGFloat = isLandscape ? 30 : 36
        let iconSize: CGFloat = isLandscape ? 13 : 15.5

        return HStack(alignment: .center, spacing: 10) {
            // 左側：圓形液態玻璃返回按鈕
            Button {
                triggerAnimatedDismissToGrid()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .detailLiquidGlassCircle(size: buttonSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Spacer()

            // 中央：液態玻璃日期時間藥丸 (如：9月17日 / 16:26 · 河田陽菜)
            Button {
                showingInfoSheet = true
            } label: {
                VStack(spacing: isLandscape ? 0 : 1) {
                    Text(Self.datePillPrimaryString(from: currentItem.displayDate))
                        .font(.system(size: isLandscape ? 11.5 : 13, weight: .bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 4) {
                        Text(Self.datePillTimeString(from: currentItem.displayDate))
                        if !currentItem.isUncategorized {
                            Text("·")
                            Image(systemName: "person.fill")
                                .font(.system(size: 8))
                            Text(currentItem.assignedMembersDisplayString(from: idolMembers))
                                .lineLimit(1)
                        } else if currentItem.ocrDate != nil {
                            Text("· OCR")
                        }
                    }
                    .font(.system(size: isLandscape ? 9 : 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, isLandscape ? 12 : 18)
                .padding(.vertical, isLandscape ? 2.5 : 5)
                .detailLiquidGlassCapsule()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("資訊")

            Spacer()

            // 右側：圓形液態玻璃更多選單 (`⋯`)
            Menu {
                if currentItem.hasBothSides {
                    Button {
                        trigger3DFlip()
                    } label: {
                        Label(
                            L10n.tr(isShowingBack ? "正面" : "背面", isShowingBack ? "表面" : "裏面"),
                            systemImage: "rectangle.portrait.rotate"
                        )
                    }

                    Divider()
                }

                Menu {
                    Button {
                        showingInAppBacksidePicker = true
                    } label: {
                        Label(
                            L10n.tr("App 內照片", "アプリ内の写真"),
                            systemImage: "square.grid.2x2"
                        )
                    }

                    Button {
                        isShowingBacksidePicker = true
                    } label: {
                        Label(
                            L10n.tr("系統相簿", "写真アプリ"),
                            systemImage: "photo.badge.plus"
                        )
                    }

                    if currentItem.hasBothSides {
                        Divider()

                        Button {
                            swapCurrentItemSides()
                        } label: {
                            Label(L10n.tr("正反對調", "表裏を入れ替え"), systemImage: "arrow.left.arrow.right")
                        }

                        Button {
                            PhotoLibraryManager.shared.detachBackside(
                                from: currentItem,
                                modelContext: modelContext
                            )
                            isShowingBack = false
                            withAnimation(flipAnimation) {
                                flipProgress = 0.0
                            }
                            showToast(L10n.tr("已取消背面設定", "裏面設定を解除しました"))
                        } label: {
                            Label(L10n.tr("取消背面", "裏面を解除"), systemImage: "rectangle.on.rectangle.slash")
                        }

                        Button(role: .destructive) {
                            PhotoLibraryManager.shared.removeBackside(
                                from: currentItem,
                                modelContext: modelContext
                            )
                            isShowingBack = false
                            withAnimation(flipAnimation) {
                                flipProgress = 0.0
                            }
                        } label: {
                            Label(L10n.tr("背面", "裏面"), systemImage: "trash")
                        }
                    }
                } label: {
                    Label(L10n.tr("背面設定", "裏面設定"), systemImage: "rectangle.portrait.on.rectangle.portrait")
                }

                Menu {
                    MemberAssignmentMenuContent(item: currentItem) { showingQuickCreateMember = true }
                } label: {
                    Label(L10n.tr("成員", "メンバー"), systemImage: "person.crop.circle")
                }
                .menuActionDismissBehavior(.disabled)

                Button {
                    Task { await syncCurrentItemToSystemPhotos() }
                } label: {
                    Label(L10n.tr("同步至相簿", "写真アプリに同期"), systemImage: "photo.on.rectangle.angled")
                }

                Divider()

                Button {
                    showingAdjustmentSheet = true
                } label: {
                    Label(L10n.tr("裁切與比例", "トリミングと比率"), systemImage: "slider.horizontal.3")
                }

                Button {
                    rotateCurrentFaceQuarterTurn()
                } label: {
                    Label(L10n.tr("旋轉", "回転"), systemImage: "rotate.left")
                }

                Button {
                    toggleWhiteBalancePickerMode()
                } label: {
                    Label(
                        isWhiteBalancePickerActive ? L10n.tr("完成白平衡", "ホワイトバランス完了") : L10n.tr("白平衡", "ホワイトバランス"),
                        systemImage: "eyedropper.halffull"
                    )
                }

                if hasActiveWhiteBalanceBackup(for: currentItem, backside: isShowingBack && currentItem.hasBothSides) {
                    Button {
                        Task {
                            await resetWhiteBalanceForCurrentSide()
                        }
                    } label: {
                        Label(L10n.tr("白平衡", "ホワイトバランス"), systemImage: "arrow.counterclockwise")
                    }
                }

                Button {
                    if PhotoLibraryManager.isProLifetimeUnlocked {
                        isShowingModeBSecondAnglePicker = true
                    } else {
                        showToast(L10n.tr("去反光合成為 Pro 功能", "反射除去合成は Pro 機能です"))
                    }
                } label: {
                    Label(
                        PhotoLibraryManager.isProLifetimeUnlocked
                            ? L10n.tr("去反光合成", "反射除去合成")
                            : L10n.tr("去反光合成 · Pro", "反射除去合成 · Pro"),
                        systemImage: "sparkles.rectangle.stack"
                    )
                }

                if currentItem.canRevertToOriginal(backside: isShowingBack && currentItem.hasBothSides) {
                    Button {
                        Task {
                            await revertCurrentItemToOriginal(backside: isShowingBack && currentItem.hasBothSides)
                        }
                    } label: {
                        Label(L10n.tr("復原原圖", "元の画像に戻す"), systemImage: "arrow.uturn.backward.circle")
                    }
                }

                Button {
                    showingInfoSheet = true
                } label: {
                    Label(L10n.tr("資訊", "情報"), systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .detailLiquidGlassCircle(size: buttonSize)
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 16)
        .padding(.top, isLandscape ? 4 : 8)
        .padding(.bottom, isLandscape ? 2 : 8)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 2. 中央拍立得水平滑動分頁與 3D Y 軸翻轉動畫 (Interactive Horizontal Pager + 3D Flip)

    private func mainCardViewport(
        fullScreenSize: CGSize,
        viewportGlobalFrame: CGRect,
        isLandscape: Bool
    ) -> some View {
        // 固定基準可用尺寸（以顯示工具列時的預留空間為固定基準 Frame，全螢幕放大與位移完全透過 GPU scaleEffect / offset 漸進漸出驅動，根除 Frame 重算造成的單擊抖動）
        let baseTopInset: CGFloat = isLandscape ? 42 : 98
        let baseBottomInset: CGFloat = isLandscape ? 58 : 138
        let baseHorizontalInset: CGFloat = isLandscape ? 20 : 18
        let normalVerticalOffset: CGFloat = (baseTopInset - baseBottomInset) / 2.0

        let baseAvailableSize = CGSize(
            width: max(120, fullScreenSize.width - baseHorizontalInset * 2),
            height: max(120, fullScreenSize.height - baseTopInset - baseBottomInset)
        )
        let fullScreenAvailableSize = CGSize(
            width: max(120, fullScreenSize.width - (isLandscape ? 16 : 0)),
            height: max(120, fullScreenSize.height - (isLandscape ? 12 : 0))
        )

        // 仿照 iOS 原生相簿：相鄰兩張照片之間保留 24pt 黑色間距，隨手指 1:1 水平推動
        let pageStride: CGFloat = fullScreenSize.width + 24
        let items = filmstripItems
        let activeIndex = currentIndex

        return ZStack {
            Color.clear
                .contentShape(Rectangle())

            ForEach(Array(items.enumerated()), id: \.element.id) { index, pageItem in
                if abs(index - activeIndex) <= 8 || pageItem.id == previousItemID {
                    let isCurrent = (index == activeIndex)
                    singleCardPageView(
                        for: pageItem,
                        isCurrent: isCurrent,
                        baseAvailableSize: baseAvailableSize,
                        fullScreenAvailableSize: fullScreenAvailableSize,
                        normalVerticalOffset: normalVerticalOffset,
                        viewportGlobalFrame: viewportGlobalFrame,
                        isLandscape: isLandscape
                    )
                    .frame(width: fullScreenSize.width, height: fullScreenSize.height)
                    .offset(x: CGFloat(index - activeIndex) * pageStride + horizontalDragOffset)
                }
            }
        }
        .frame(width: fullScreenSize.width, height: fullScreenSize.height)
        .clipped()
        .contentShape(Rectangle())
        .allowsHitTesting(!isAnimatingDismissToGrid)
        .gesture(
            cardMagnifyGesture(
                baseAvailableSize: baseAvailableSize,
                fullScreenAvailableSize: fullScreenAvailableSize
            )
        )
        .simultaneousGesture(
            cardDragAndSwipeGesture(
                pageStride: pageStride,
                fullScreenSize: fullScreenSize
            )
        )
    }

    /// 計算指定卡片由一般模式放大至全畫面時的平滑倍率
    private func fullScreenExpandScale(
        for pageItem: ChekiItem,
        baseAvailableSize: CGSize,
        fullScreenAvailableSize: CGSize
    ) -> CGFloat {
        let activeData = pageItem.frontImageData ?? pageItem.backImageData
        let imgSize: CGSize
        if let activeData, let uiImg = ChekiDetailDecodedImageCache.image(for: activeData), uiImg.size.width > 0, uiImg.size.height > 0 {
            imgSize = uiImg.size
        } else {
            imgSize = CGSize(width: 540, height: 860)
        }
        let baseSize = fittedCardSize(for: imgSize, in: baseAvailableSize)
        let fullSize = fittedCardSize(for: imgSize, in: fullScreenAvailableSize)
        return max(1.0, fullSize.width / max(1.0, baseSize.width))
    }

    /// 單張卡片頁面：透過 `Cheki3DFlipContainer` (Animatable) 驅動 0° ↔ 180° 連續 3D 翻轉、Z 軸浮起、下滑跟手縮小，以及放開縮回一覽原位置動畫
    @ViewBuilder
    private func singleCardPageView(
        for pageItem: ChekiItem,
        isCurrent: Bool,
        baseAvailableSize: CGSize,
        fullScreenAvailableSize: CGSize,
        normalVerticalOffset: CGFloat,
        viewportGlobalFrame: CGRect,
        isLandscape: Bool
    ) -> some View {
        let targetAnchor: GridCellAnchor? = isCurrent ? gridAnchor(for: pageItem.id) : nil
        let isDockedToGrid = isCurrent && isCardDockedToGridCell && targetAnchor != nil

        let effectiveFlipProgress = (isCurrent && !isDockedToGrid && !isDraggingDownToDismiss) ? flipProgress : 0.0
        let expandScale = fullScreenExpandScale(
            for: pageItem,
            baseAvailableSize: baseAvailableSize,
            fullScreenAvailableSize: fullScreenAvailableSize
        )

        // 計算當前卡片的基準尺寸；當縮回一覽格狀縮圖且該格為 1:1 置中裁切時，平滑轉換為 1:1 正方形框並對齊目標格尺寸
        let activeCardSize: CGSize = {
            let activeData = pageItem.frontImageData ?? pageItem.backImageData
            let imgSize: CGSize
            if let activeData, let uiImg = ChekiDetailDecodedImageCache.image(for: activeData), uiImg.size.width > 0, uiImg.size.height > 0 {
                imgSize = uiImg.size
            } else {
                imgSize = CGSize(width: 540, height: 860)
            }
            let normalCardSize = fittedCardSize(for: imgSize, in: baseAvailableSize)
            if isDockedToGrid, let anchor = targetAnchor, anchor.isSquareCropped {
                let squareSide = min(normalCardSize.width, normalCardSize.height)
                return CGSize(width: squareSide, height: squareSide)
            }
            return normalCardSize
        }()

        // 當圖片已放大 (isImageZoomed) 時：單擊切換全畫面僅隱藏/顯示 icon，圖片本身的倍率與座標 100% 鎖定不跳動
        // 當下滑跟手 (isDraggingDownToDismiss) 時：隨手指下滑距離平滑縮小
        // 當放開縮回一覽 (isDockedToGrid) 時：精準縮放至底層一覽中該照片格子的寬度比例
        let effectiveScale: CGFloat = {
            guard isCurrent else {
                return isChromeHidden ? expandScale : 1.0
            }
            if isDockedToGrid, let anchor = targetAnchor {
                return max(0.05, anchor.globalFrame.width / max(1.0, activeCardSize.width))
            } else if fallbackFadeOutDismiss {
                return max(0.18, interactiveDismissDragScale * 0.45)
            } else if isDraggingDownToDismiss {
                let baseScale: CGFloat = isChromeHidden ? expandScale : 1.0
                return baseScale * interactiveDismissDragScale
            } else if isImageZoomed {
                return zoomScale * activePinchScale
            } else {
                return isChromeHidden ? expandScale : 1.0
            }
        }()

        let effectiveOffset: CGSize = {
            guard isCurrent else {
                return CGSize(width: 0, height: isChromeHidden ? 0 : normalVerticalOffset)
            }
            if isDockedToGrid, let anchor = targetAnchor {
                return CGSize(
                    width: anchor.globalFrame.midX - viewportGlobalFrame.midX,
                    height: anchor.globalFrame.midY - viewportGlobalFrame.midY
                )
            } else if isDraggingDownToDismiss || fallbackFadeOutDismiss {
                let baseY: CGFloat = isChromeHidden ? 0 : normalVerticalOffset
                return CGSize(
                    width: dismissDragOffset.width,
                    height: baseY + dismissDragOffset.height
                )
            } else if isImageZoomed {
                let anchorY: CGFloat = isZoomedFromFullScreen ? 0 : normalVerticalOffset
                return CGSize(
                    width: zoomPanOffset.width + activeZoomPanDelta.width,
                    height: anchorY + zoomPanOffset.height + activeZoomPanDelta.height
                )
            } else {
                return CGSize(width: 0, height: isChromeHidden ? 0 : normalVerticalOffset)
            }
        }()

        let dockedCornerRadius: CGFloat = {
            if isDockedToGrid, let anchor = targetAnchor {
                let scaleRatio = max(0.05, anchor.globalFrame.width / max(1.0, activeCardSize.width))
                return anchor.cornerRadius / scaleRatio
            }
            return 10.0
        }()

        Cheki3DFlipContainer(
            flipProgress: effectiveFlipProgress,
            front: {
                frontCardFace(
                    for: pageItem,
                    isCurrent: isCurrent,
                    availableSize: baseAvailableSize,
                    overrideCardSize: isDockedToGrid ? activeCardSize : nil,
                    isSquareCroppedForGrid: isDockedToGrid && (targetAnchor?.isSquareCropped ?? false),
                    cardCornerRadius: dockedCornerRadius,
                    isLandscape: isLandscape
                )
            },
            back: {
                backCardFace(
                    for: pageItem,
                    isCurrent: isCurrent,
                    availableSize: baseAvailableSize,
                    isLandscape: isLandscape
                )
            }
        )
        .scaleEffect(effectiveScale)
        .offset(x: effectiveOffset.width, y: effectiveOffset.height)
        .opacity(
            (!isCurrent && (isDraggingDownToDismiss || isCardDockedToGridCell || fallbackFadeOutDismiss))
                ? 0.0
                : (fallbackFadeOutDismiss && isCurrent ? 0.0 : 1.0)
        )
    }

    /// 卡片右上角翻轉按鈕（正面與背面皆固定於各自畫面的右上角 `topTrailing`；若圖片放大中或下滑返回中則直接隱藏 icon）
    @ViewBuilder
    private func cardTopRightFlipButton(
        for pageItem: ChekiItem,
        isCurrent: Bool,
        isBackFace: Bool,
        isLandscape: Bool
    ) -> some View {
        let shouldShow = pageItem.hasBothSides
            && isCurrent
            && !isImageZoomed
            && !isDraggingDownToDismiss
            && !isCardDockedToGridCell
            && (!isChromeHidden || isBackFace)
        Button {
            trigger3DFlip()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.portrait.rotate")
                    .font(.system(size: isLandscape ? 9 : 10.5, weight: .semibold))
                Text(L10n.tr(isBackFace ? "正面" : (pageItem.hasBothSides ? "背面" : "單面"), isBackFace ? "表面" : (pageItem.hasBothSides ? "裏面" : "片面")))
                    .font(.system(size: isLandscape ? 9 : 10.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isLandscape ? 7 : 9)
            .padding(.vertical, isLandscape ? 3 : 4.5)
            .detailLiquidGlassCapsule()
        }
        .buttonStyle(.plain)
        .padding(isLandscape ? 6 : 8)
        .opacity(shouldShow ? 1.0 : 0.0)
        .allowsHitTesting(shouldShow)
        .environment(\.colorScheme, .dark)
    }

    /// 卡片本體的單擊（沉浸模式切換 / 白平衡點選取樣）與雙擊（3D 翻轉 / 重置縮放）手勢，綁定在底圖上以避免干擾右上角翻轉按鈕
    /// 注意：一般檢視模式下必須依序串接 `.onTapGesture(count: 2)` 再 `.onTapGesture(count: 1)`（不可使用 `.simultaneousGesture`），
    /// 否則雙擊的第一下會立即觸發 `isChromeHidden.toggle()` 導致卡片先往 Z 軸放大上移再卡一下才翻面。
    @ViewBuilder
    private func applyCardTapGestures<V: View>(
        to view: V,
        cardSize: CGSize? = nil,
        insetScale: CGFloat = 1.0,
        isCurrent: Bool = false,
        isBackside: Bool = false
    ) -> some View {
        if isCurrent && isWhiteBalancePickerActive {
            view
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 1, coordinateSpace: .local)
                        .onEnded { value in
                            if let cardSize, cardSize.width > 10, cardSize.height > 10 {
                                let safeScale = max(0.5, insetScale)
                                let rawNormX = (value.location.x - cardSize.width * 0.5) / (cardSize.width * safeScale) + 0.5
                                let rawNormY = (value.location.y - cardSize.height * 0.5) / (cardSize.height * safeScale) + 0.5
                                let clampedPoint = CGPoint(
                                    x: min(max(rawNormX, 0.0), 1.0),
                                    y: min(max(rawNormY, 0.0), 1.0)
                                )
                                handleWhiteBalanceTap(at: clampedPoint, isBackside: isBackside)
                            }
                        }
                )
        } else {
            view
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if isImageZoomed {
                        withAnimation(pageAndZoomAnimation) {
                            let returnToFullScreen = isZoomedFromFullScreen
                            zoomScale = 1.0
                            activePinchScale = 1.0
                            zoomPanOffset = .zero
                            activeZoomPanDelta = .zero
                            isZoomedFromFullScreen = false
                            isChromeHidden = returnToFullScreen
                        }
                    } else {
                        trigger3DFlip()
                    }
                }
                .onTapGesture(count: 1) {
                    withAnimation(pageAndZoomAnimation) {
                        isChromeHidden.toggle()
                    }
                }
        }
    }

    @ViewBuilder
    private func whiteBalanceTargetMarkerOverlay(
        cardSize: CGSize,
        isCurrent: Bool,
        isBackside: Bool
    ) -> some View {
        if isCurrent,
           isWhiteBalancePickerActive,
           isShowingBack == isBackside,
           let tapPt = whiteBalanceTapNormalizedPoint {
            let markerX = tapPt.x * cardSize.width
            let markerY = tapPt.y * cardSize.height
            ZStack {
                Circle()
                    .strokeBorder(Color.black.opacity(0.65), lineWidth: 3.0)
                    .frame(width: 34, height: 34)
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2.0)
                    .frame(width: 32, height: 32)
                Image(systemName: "eyedropper.halffull")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.75), radius: 2, x: 0, y: 1)
            }
            .position(x: markerX, y: markerY)
            .allowsHitTesting(false)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func fittedCardSize(for imageSize: CGSize, in availableSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: min(availableSize.width, 300), height: min(availableSize.height, 460))
        }
        let scale = min(availableSize.width / imageSize.width, availableSize.height / imageSize.height)
        return CGSize(
            width: max(80, imageSize.width * scale),
            height: max(80, imageSize.height * scale)
        )
    }

    @ViewBuilder
    private func frontCardFace(
        for targetItem: ChekiItem,
        isCurrent: Bool,
        availableSize: CGSize,
        overrideCardSize: CGSize? = nil,
        isSquareCroppedForGrid: Bool = false,
        cardCornerRadius: CGFloat = 10,
        isLandscape: Bool
    ) -> some View {
        let baseInsetScale = CGFloat(1.0 - targetItem.borderInsetRatio * 1.4)
        let effectiveImageScale: CGFloat = isSquareCroppedForGrid ? 1.22 : baseInsetScale
        if let data = targetItem.frontImageData,
           let uiImage = ChekiDetailDecodedImageCache.image(for: data) {
            let cardSize = overrideCardSize ?? fittedCardSize(for: uiImage.size, in: availableSize)
            applyCardTapGestures(
                to: Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(effectiveImageScale)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .overlay {
                        ChekiWatermarkOverlayView(compact: isSquareCroppedForGrid)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        whiteBalanceTargetMarkerOverlay(
                            cardSize: cardSize,
                            isCurrent: isCurrent,
                            isBackside: false
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)),
                cardSize: cardSize,
                insetScale: baseInsetScale,
                isCurrent: isCurrent,
                isBackside: false
            )
            .overlay(alignment: .topTrailing) {
                cardTopRightFlipButton(
                    for: targetItem,
                    isCurrent: isCurrent,
                    isBackFace: false,
                    isLandscape: isLandscape
                )
            }
        } else {
            applyCardTapGestures(
                to: placeholderCardFace(
                    title: L10n.tr("無正面照片", "表面なし"),
                    subtitle: "",
                    availableSize: availableSize
                )
            )
            .overlay(alignment: .topTrailing) {
                cardTopRightFlipButton(
                    for: targetItem,
                    isCurrent: isCurrent,
                    isBackFace: false,
                    isLandscape: isLandscape
                )
            }
        }
    }

    @ViewBuilder
    private func backCardFace(
        for targetItem: ChekiItem,
        isCurrent: Bool,
        availableSize: CGSize,
        isLandscape: Bool
    ) -> some View {
        if let backData = targetItem.backImageData,
           let uiImage = ChekiDetailDecodedImageCache.image(for: backData) {
            let cardSize = fittedCardSize(for: uiImage.size, in: availableSize)
            applyCardTapGestures(
                to: Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardSize.width, height: cardSize.height)
                    .overlay {
                        ChekiWatermarkOverlayView(compact: false)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        whiteBalanceTargetMarkerOverlay(
                            cardSize: cardSize,
                            isCurrent: isCurrent,
                            isBackside: true
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)),
                cardSize: cardSize,
                insetScale: 1.0,
                isCurrent: isCurrent,
                isBackside: true
            )
            .overlay(alignment: .topTrailing) {
                cardTopRightFlipButton(
                    for: targetItem,
                    isCurrent: isCurrent,
                    isBackFace: true,
                    isLandscape: isLandscape
                )
            }
        } else {
            // 若此張拍立得尚無背面，提供原生引導卡直接從 App 內選取或從系統相簿補上背面，且支援雙擊卡片翻回正面
            applyCardTapGestures(
                to: VStack(spacing: 14) {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white.opacity(0.75))

                    VStack(spacing: 5) {
                        Text(L10n.tr("尚無背面照片", "裏面なし"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)

                        Text(L10n.tr("雙擊卡片翻回正面", "ダブルタップで表面へ"))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.68))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }

                    VStack(spacing: 8) {
                        Button {
                            showingInAppBacksidePicker = true
                        } label: {
                            Label(L10n.tr("App 內照片", "アプリ内の写真"), systemImage: "square.grid.2x2")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            isShowingBacksidePicker = true
                        } label: {
                            Label(L10n.tr("系統相簿", "写真アプリ"), systemImage: "photo.badge.plus")
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.white)
                    }
                    .padding(.horizontal, 20)
                }
                .frame(
                    width: min(availableSize.width, min(availableSize.height * 0.65, 290)),
                    height: min(availableSize.height, 440)
                )
                .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
            )
            .overlay(alignment: .topTrailing) {
                cardTopRightFlipButton(
                    for: targetItem,
                    isCurrent: isCurrent,
                    isBackFace: true,
                    isLandscape: isLandscape
                )
            }
        }
    }

    private func placeholderCardFace(title: String, subtitle: String, availableSize: CGSize) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(
            width: min(availableSize.width, min(availableSize.height * 0.65, 280)),
            height: min(availableSize.height, 420)
        )
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 3. 初次檢視亮點提示 (Spotlight Coach Mark) & 點選白色部分白平衡導引橫幅

    private var whiteBalanceInstructionBanner: some View {
        let isBack = isShowingBack && currentItem.hasBothSides
        let canReset = hasActiveWhiteBalanceBackup(for: currentItem, backside: isBack)

        return HStack(spacing: 10) {
            Image(systemName: "eyedropper.halffull")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(L10n.tr("點選白色邊框校正白平衡", "白い枠をタップして補正"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                if let summary = whiteBalanceSummaryText {
                    Text(summary)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.78))
                } else {
                    Text(L10n.tr("自動計算色溫與色調", "色温度と色合いを自動計算"))
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            if canReset {
                Button {
                    Task {
                        await resetWhiteBalanceForCurrentSide()
                    }
                } label: {
                    Text("重置")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isWhiteBalancePickerActive = false
                }
            } label: {
                Text("完成")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .detailLiquidGlassCapsule(interactive: false)
        .padding(.horizontal, 12)
        .environment(\.colorScheme, .dark)
    }

    private var detailCoachMarkBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw.fill")
                .font(.caption)
                .foregroundStyle(.white)

            Text(L10n.tr("雙擊翻面 · 上滑備忘", "ダブルタップで裏返す · 上スワイプでメモ"))
                .font(.caption)
                .foregroundStyle(.white)

            Button {
                withAnimation {
                    hasSeenDetailCoachMark = true
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .detailLiquidGlassCapsule(interactive: false)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 4. 底部縮圖膠卷 (Filmstrip Scrubber) + 5 大標準工具列按鈕

    private func bottomControlsStack(isLandscape: Bool, containerWidth: CGFloat) -> some View {
        VStack(spacing: isLandscape ? 4 : 18) {
            // 底部縮圖膠卷 (Filmstrip Scrubber)
            filmstripScrubberBar(isLandscape: isLandscape, containerWidth: containerWidth)

            // Apple Photos 標準 5 大工具列按鈕（左圓分享、中膠囊、右圓刪除）
            standardFiveIconToolbar(isLandscape: isLandscape)
        }
        .padding(.top, isLandscape ? 2 : 8)
        .padding(.bottom, isLandscape ? -4 : -10)
        .background(
            LinearGradient(
                colors: [
                    .black.opacity(0.0),
                    .black.opacity(0.68),
                    .black.opacity(0.90)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
        .environment(\.colorScheme, .dark)
    }

    private func filmstripScrubberBar(isLandscape: Bool, containerWidth: CGFloat) -> some View {
        let currentWidth: CGFloat = isLandscape ? 16 : 26
        let currentHeight: CGFloat = isLandscape ? 22 : 36
        let normalWidth: CGFloat = isLandscape ? 12 : 19
        let normalHeight: CGFloat = isLandscape ? 16.5 : 26

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: isLandscape ? 3 : 4.5) {
                    ForEach(filmstripItems) { stripItem in
                        let isCurrent = (stripItem.id == currentItem.id)
                        Button {
                            selectFilmstripItem(stripItem)
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                if let data = stripItem.frontImageData,
                                   let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(
                                            width: isCurrent ? currentWidth : normalWidth,
                                            height: isCurrent ? currentHeight : normalHeight
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: isCurrent ? 2.5 : 2, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Color(white: 0.25))
                                        .frame(
                                            width: isCurrent ? currentWidth : normalWidth,
                                            height: isCurrent ? currentHeight : normalHeight
                                        )
                                }

                                if stripItem.hasBothSides && isCurrent {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: isLandscape ? 4 : 5, height: isLandscape ? 4 : 5)
                                        .padding(1)
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: isCurrent ? 2.5 : 2, style: .continuous)
                                    .strokeBorder(.white, lineWidth: isCurrent ? (isLandscape ? 1.2 : 1.6) : 0.0)
                            )
                            .opacity(isCurrent ? 1.0 : 0.56)
                        }
                        .buttonStyle(.plain)
                        .id(stripItem.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, isLandscape ? 1 : 3)
                .frame(minWidth: containerWidth)
            }
            .onAppear {
                proxy.scrollTo(currentItem.id, anchor: .center)
            }
            .onChange(of: currentItemID) { _, newID in
                guard let newID else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func standardFiveIconToolbar(isLandscape: Bool) -> some View {
        let iconFontSize: CGFloat = isLandscape ? 14 : 18
        let pillHeight: CGFloat = isLandscape ? 34 : 44
        let centerButtonWidth: CGFloat = isLandscape ? 38 : 44
        let outerPillSpacing: CGFloat = isLandscape ? 18 : 24

        return HStack(alignment: .center, spacing: outerPillSpacing) {
            // 左側獨立圓形膠囊：1. 分享 (Share)
            Button {
                shareCurrentItem()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: iconFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .detailLiquidGlassCircle(size: pillHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享")

            // 中央膠囊：2. 愛心 (Favorite) + 3. 資訊 (Info) + 4. 點選白邊白平衡 (Eyedropper WB) + 5. 調整邊界 (Adjust)
            HStack(spacing: isLandscape ? 2 : 2) {
                // 2. 愛心 / 最愛 (Favorite)
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: iconFontSize, weight: .medium))
                        .foregroundStyle(isFavorite ? .pink : .white)
                        .symbolEffect(.bounce, value: isFavorite)
                        .frame(width: centerButtonWidth, height: pillHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "取消最愛" : "最愛")

                // 3. ℹ️ 資訊與特典會備忘 (Info & Memo Sheet)
                Button {
                    hasSeenDetailCoachMark = true
                    showingInfoSheet = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: showingInfoSheet ? "info.circle.fill" : "info.circle")
                            .font(.system(size: iconFontSize, weight: .medium))
                            .foregroundStyle(.white)

                        if let note = currentItem.memo?.noteText, !note.isEmpty {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: isLandscape ? 4.5 : 6, height: isLandscape ? 4.5 : 6)
                                .offset(x: 2.5, y: -1.5)
                        }
                    }
                    .frame(width: centerButtonWidth, height: pillHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("資訊")

                // 4. 點選白色部分校正白平衡 (Auto White Balance Eyedropper)
                Button {
                    toggleWhiteBalancePickerMode()
                } label: {
                    Image(systemName: "eyedropper.halffull")
                        .font(.system(size: iconFontSize, weight: .medium))
                        .foregroundStyle(isWhiteBalancePickerActive ? .black : .white)
                        .frame(width: centerButtonWidth - 4, height: pillHeight - 8)
                        .background(
                            isWhiteBalancePickerActive ? Color.white : Color.clear,
                            in: Capsule()
                        )
                        .frame(width: centerButtonWidth, height: pillHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("白平衡")

                // 5. 調整邊界與比例 (Adjust Border Inset & Format)
                Button {
                    showingAdjustmentSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: iconFontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: centerButtonWidth, height: pillHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("裁切")
            }
            .padding(.horizontal, isLandscape ? 4 : 4)
            .frame(height: pillHeight)
            .detailLiquidGlassCapsule()

            // 右側獨立圓形膠囊：5. 垃圾桶 (Delete)
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: iconFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .detailLiquidGlassCircle(size: pillHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刪除")
        }
    }

    // MARK: - 5. 手勢與互動動作 (Gestures & Actions)

    private func cardMagnifyGesture(
        baseAvailableSize: CGSize,
        fullScreenAvailableSize: CGSize
    ) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if activePinchScale == 1.0 && zoomScale <= 1.01 {
                    isZoomedFromFullScreen = isChromeHidden
                    if isChromeHidden {
                        zoomScale = fullScreenExpandScale(
                            for: currentItem,
                            baseAvailableSize: baseAvailableSize,
                            fullScreenAvailableSize: fullScreenAvailableSize
                        )
                    }
                }
                activePinchScale = max(0.75, min(3.5, value.magnification))
                // 若圖片開始放大，直接取消顯示 icon（不觸發卡片位移或額外縮放）
                if (zoomScale * activePinchScale) > 1.04 && !isChromeHidden {
                    withAnimation(pageAndZoomAnimation) {
                        isChromeHidden = true
                    }
                }
            }
            .onEnded { value in
                let expandScale = fullScreenExpandScale(
                    for: currentItem,
                    baseAvailableSize: baseAvailableSize,
                    fullScreenAvailableSize: fullScreenAvailableSize
                )
                let minBaseScale: CGFloat = isZoomedFromFullScreen ? expandScale : 1.0
                let rawFinalScale = zoomScale * value.magnification
                if rawFinalScale <= minBaseScale + 0.03 {
                    withAnimation(pageAndZoomAnimation) {
                        let returnToFullScreen = isZoomedFromFullScreen
                        zoomScale = 1.0
                        activePinchScale = 1.0
                        zoomPanOffset = .zero
                        activeZoomPanDelta = .zero
                        isZoomedFromFullScreen = false
                        isChromeHidden = returnToFullScreen
                    }
                } else {
                    let finalScale = min(3.5, rawFinalScale)
                    withAnimation(pageAndZoomAnimation) {
                        zoomScale = finalScale
                        activePinchScale = 1.0
                    }
                }
            }
    }

    private func cardDragAndSwipeGesture(
        pageStride: CGFloat,
        fullScreenSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !isAnimatingDismissToGrid && !fallbackFadeOutDismiss else { return }

                if isImageZoomed {
                    activeZoomPanDelta = value.translation
                    return
                }

                let dx = value.translation.width
                let dy = value.translation.height

                if dragAxisLock == nil {
                    if abs(dx) > 8 || abs(dy) > 8 {
                        dragAxisLock = abs(dx) >= abs(dy) ? .horizontal : .vertical
                    }
                }

                if dragAxisLock == .vertical {
                    // 向下滑動：相片跟隨手指 2D 位移並平滑縮小，同時背景漸淡透出底層一覽
                    if dy > 0 || isDraggingDownToDismiss {
                        if !isDraggingDownToDismiss {
                            isDraggingDownToDismiss = true
                        }
                        dismissDragOffset = CGSize(width: dx, height: max(-24, dy))
                    }
                    return
                }

                guard dragAxisLock == .horizontal else { return }

                let itemsCount = filmstripItems.count
                let idx = currentIndex
                let isOverscrollingLeading = (idx == 0 && dx > 0)
                let isOverscrollingTrailing = (idx >= itemsCount - 1 && dx < 0)

                if isOverscrollingLeading || isOverscrollingTrailing {
                    // 首尾邊界橡皮筋阻尼回饋
                    horizontalDragOffset = dx * 0.28
                } else {
                    horizontalDragOffset = dx
                }
            }
            .onEnded { value in
                defer { dragAxisLock = nil }
                guard !isAnimatingDismissToGrid && !fallbackFadeOutDismiss else { return }

                if isImageZoomed {
                    let maxPanX = max(40, (fullScreenSize.width * (zoomScale - 1.0)) * 0.52)
                    let maxPanY = max(60, (fullScreenSize.height * (zoomScale - 1.0)) * 0.52)
                    let targetX = min(max(zoomPanOffset.width + value.translation.width, -maxPanX), maxPanX)
                    let targetY = min(max(zoomPanOffset.height + value.translation.height, -maxPanY), maxPanY)
                    withAnimation(pageAndZoomAnimation) {
                        zoomPanOffset = CGSize(width: targetX, height: targetY)
                        activeZoomPanDelta = .zero
                    }
                    return
                }

                let dx = value.translation.width
                let dy = value.translation.height
                let predictedDx = value.predictedEndTranslation.width
                let predictedDy = value.predictedEndTranslation.height
                let activeAxis = dragAxisLock ?? (abs(dx) >= abs(dy) ? .horizontal : .vertical)

                if isDraggingDownToDismiss {
                    // 放開手指時：若下滑距離或慣性超過門檻，圖片平滑縮回一覽中該相片的原本位置；否則彈回中央
                    if dy > 45 || predictedDy > 120 {
                        triggerAnimatedDismissToGrid()
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            isDraggingDownToDismiss = false
                            dismissDragOffset = .zero
                        }
                    }
                    return
                }

                if activeAxis == .vertical {
                    withAnimation(pageAndZoomAnimation) {
                        horizontalDragOffset = 0
                    }
                    // 向上滑動 -> 呼出資訊與備忘面板 (Task 4.6)
                    if dy < -50 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        hasSeenDetailCoachMark = true
                        showingInfoSheet = true
                    } else if dy > 65 {
                        // 向下滑動 -> 圖片縮回一覽原本位置並返回
                        triggerAnimatedDismissToGrid()
                    }
                } else {
                    // 左右水平滑動 -> 判斷是否翻至上一張 / 下一張，或回彈至原位
                    let items = filmstripItems
                    let idx = currentIndex
                    let threshold = min(85.0, pageStride * 0.20)

                    if (dx < -threshold || predictedDx < -threshold * 1.6), idx + 1 < items.count {
                        selectFilmstripItem(items[idx + 1])
                    } else if (dx > threshold || predictedDx > threshold * 1.6), idx - 1 >= 0 {
                        selectFilmstripItem(items[idx - 1])
                    } else {
                        withAnimation(pageAndZoomAnimation) {
                            horizontalDragOffset = 0
                        }
                    }
                }
            }
    }

    /// 觸發「放開時圖片縮回一覽中原本位置」的平滑過渡動畫（與系統相簿一致）
    private func triggerAnimatedDismissToGrid() {
        guard !isAnimatingDismissToGrid && !fallbackFadeOutDismiss else { return }

        // 若是由舊版 NavigationStack 路徑推入，直接呼叫 dismiss()
        guard NavigationChromeState.shared.activeDetailRoute != nil else {
            dismiss()
            return
        }

        let activeID = currentItem.id
        NavigationChromeState.shared.activeZoomItemID = activeID

        if gridAnchor(for: activeID) != nil {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                isDraggingDownToDismiss = false
                isAnimatingDismissToGrid = true
                dismissDragOffset = .zero
                isShowingBack = false
                flipProgress = 0.0
                zoomScale = 1.0
                activePinchScale = 1.0
                zoomPanOffset = .zero
                activeZoomPanDelta = .zero
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) {
                NavigationChromeState.shared.dismissDetail()
            }
        } else {
            withAnimation(.easeOut(duration: 0.22)) {
                fallbackFadeOutDismiss = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) {
                NavigationChromeState.shared.dismissDetail()
            }
        }
    }

    private func performImmediateDismiss() {
        if NavigationChromeState.shared.activeDetailRoute != nil {
            NavigationChromeState.shared.dismissDetail()
        } else {
            dismiss()
        }
    }

    /// 全畫面放大與左右翻頁共用的平滑漸進漸出曲線（Ease-In-Ease-Out，慢進慢出無急跳）
    private var pageAndZoomAnimation: Animation {
        .timingCurve(0.26, 0.08, 0.22, 1.0, duration: 0.38)
    }

    /// 3D 翻轉曲線：慢進慢出（減速強調 / 減速を強調する），速度較先前放慢約 0.7 倍（時長 0.84 秒）
    private var flipAnimation: Animation {
        .timingCurve(0.24, 0.06, 0.12, 1.0, duration: 0.84)
    }

    private func trigger3DFlip() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if !hasSeenDetailCoachMark {
            hasSeenDetailCoachMark = true
        }
        let nextBack = !isShowingBack
        withAnimation(flipAnimation) {
            isShowingBack = nextBack
            flipProgress = nextBack ? 1.0 : 0.0
        }
    }

    private func selectFilmstripItem(_ targetItem: ChekiItem) {
        guard targetItem.id != currentItem.id else {
            withAnimation(pageAndZoomAnimation) {
                horizontalDragOffset = 0
            }
            return
        }
        previousItemID = currentItem.id
        NavigationChromeState.shared.activeZoomItemID = targetItem.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(pageAndZoomAnimation) {
            currentItemID = targetItem.id
            horizontalDragOffset = 0
            isShowingBack = false
            flipProgress = 0.0
            zoomScale = 1.0
            activePinchScale = 1.0
            zoomPanOffset = .zero
            activeZoomPanDelta = .zero
            isZoomedFromFullScreen = false
            whiteBalanceTapNormalizedPoint = nil
            whiteBalanceSummaryText = nil
        }
    }

    // MARK: - Task 6.5.8: 點選白色部分自動白平衡動作 (Tap-on-White Auto White Balance)

    private func toggleWhiteBalancePickerMode() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        hasSeenDetailCoachMark = true
        withAnimation(.snappy(duration: 0.22)) {
            isWhiteBalancePickerActive.toggle()
            if isWhiteBalancePickerActive {
                isChromeHidden = false
            } else {
                whiteBalanceTapNormalizedPoint = nil
            }
        }
    }

    private func hasActiveWhiteBalanceBackup(for item: ChekiItem, backside: Bool) -> Bool {
        if backside {
            return preWhiteBalanceBackDataByItemID[item.id] != nil
        } else {
            return preWhiteBalanceFrontDataByItemID[item.id] != nil
        }
    }

    @MainActor
    private func handleWhiteBalanceTap(at normalizedPoint: CGPoint, isBackside: Bool) {
        guard let target = currentItemOpt, !target.isDeleted, target.modelContext != nil else { return }
        let editingBack = isBackside && target.hasBothSides

        // 1. 取得尚未套用白平衡前的基準卡片影像（確保連續點選白邊不同位置時不會重複疊加色溫偏移）
        let baseData: Data? = {
            if editingBack {
                if let cached = preWhiteBalanceBackDataByItemID[target.id] {
                    return cached
                }
                if let current = target.backImageData {
                    preWhiteBalanceBackDataByItemID[target.id] = current
                    return current
                }
                return nil
            } else {
                if let cached = preWhiteBalanceFrontDataByItemID[target.id] {
                    return cached
                }
                if let current = target.frontImageData {
                    preWhiteBalanceFrontDataByItemID[target.id] = current
                    return current
                }
                return nil
            }
        }()

        guard let sourceData = baseData,
              let sourceImage = UIImage(data: sourceData) else {
            showToast(L10n.tr("無法讀取影像", "画像を読み込めません"))
            return
        }

        withAnimation(.snappy(duration: 0.18)) {
            whiteBalanceTapNormalizedPoint = normalizedPoint
        }

        switch PhotoLibraryManager.applyAutoWhiteBalance(to: sourceImage, normalizedTapPoint: normalizedPoint) {
        case .failure(let err):
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showToast(err.localizedDescription)

        case .success(let outcome):
            if editingBack {
                target.backImageData = outcome.calibratedJPEGData
            } else {
                target.frontImageData = outcome.calibratedJPEGData
            }
            try? modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            let tempSign = outcome.deltaTemperatureKelvin >= 0 ? "+" : ""
            let tintSign = outcome.deltaTint >= 0 ? "+" : ""
            let summary = L10n.tr(
                "色溫 \(tempSign)\(outcome.deltaTemperatureKelvin)K · 色調 \(tintSign)\(outcome.deltaTint)",
                "色温度 \(tempSign)\(outcome.deltaTemperatureKelvin)K · 色合い \(tintSign)\(outcome.deltaTint)"
            )
            withAnimation(.snappy(duration: 0.2)) {
                whiteBalanceSummaryText = summary
            }

            Task { @MainActor in
                let _ = await PhotoLibraryManager.shared.syncWhiteBalanceEditToSystemPhotoLibrary(
                    for: target,
                    backside: editingBack,
                    outcome: outcome,
                    normalizedTapPoint: normalizedPoint
                )
                showToast(
                    L10n.tr(
                        "白平衡 · \(summary)",
                        "ホワイトバランス · \(summary)"
                    )
                )
            }
        }
    }

    @MainActor
    private func resetWhiteBalanceForCurrentSide() async {
        guard let target = currentItemOpt, !target.isDeleted, target.modelContext != nil else { return }
        let editingBack = isShowingBack && target.hasBothSides

        if editingBack {
            guard let backup = preWhiteBalanceBackDataByItemID[target.id],
                  let backupUI = UIImage(data: backup) else { return }
            target.backImageData = backup
            preWhiteBalanceBackDataByItemID.removeValue(forKey: target.id)
            try? modelContext.save()
            if let backID = target.backAssetIdentifier,
               !backID.isEmpty,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [backID], options: nil).firstObject {
                try? await PhotoLibraryManager.shared.modifyAssetInPlace(
                    asset: asset,
                    croppedImage: backupUI
                )
            }
        } else {
            guard let backup = preWhiteBalanceFrontDataByItemID[target.id],
                  let backupUI = UIImage(data: backup) else { return }
            target.frontImageData = backup
            preWhiteBalanceFrontDataByItemID.removeValue(forKey: target.id)
            try? modelContext.save()
            if let frontID = target.frontAssetIdentifier,
               !frontID.isEmpty,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [frontID], options: nil).firstObject {
                try? await PhotoLibraryManager.shared.modifyAssetInPlace(
                    asset: asset,
                    croppedImage: backupUI
                )
            }
        }

        withAnimation(.snappy(duration: 0.2)) {
            whiteBalanceTapNormalizedPoint = nil
            whiteBalanceSummaryText = nil
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast(L10n.tr("已還原白平衡", "ホワイトバランスをリセット"))
    }

    private func navigateFilmstrip(offset: Int) {
        let items = filmstripItems
        let targetIndex = currentIndex + offset
        guard items.indices.contains(targetIndex) else { return }
        selectFilmstripItem(items[targetIndex])
    }

    private func toggleFavorite() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let target = currentItem
        if let memo = target.memo {
            if let idx = memo.hashtags.firstIndex(where: { $0 == "#最愛" || $0 == "最愛" || $0 == "#お気に入り" }) {
                memo.hashtags.remove(at: idx)
            } else {
                memo.hashtags.insert("#最愛", at: 0)
            }
        } else {
            let newMemo = ChekiMemo(
                eventName: nil,
                noteText: nil,
                hashtags: ["#最愛"],
                chekiItem: target
            )
            target.memo = newMemo
            modelContext.insert(newMemo)
        }
        try? modelContext.save()
    }

    private func swapCurrentItemSides() {
        guard let backData = currentItem.backImageData else { return }
        let frontData = currentItem.frontImageData
        let origFront = currentItem.originalFrontImageData
        let origBack = currentItem.originalBackImageData
        let frontPts = currentItem.perspectivePointsJSON
        let backPts = currentItem.backPerspectivePointsJSON
        let frontAsset = currentItem.frontAssetIdentifier
        let backAsset = currentItem.backAssetIdentifier

        currentItem.frontImageData = backData
        currentItem.backImageData = frontData
        currentItem.originalFrontImageData = origBack
        currentItem.originalBackImageData = origFront
        currentItem.perspectivePointsJSON = backPts
        currentItem.backPerspectivePointsJSON = frontPts
        currentItem.frontAssetIdentifier = backAsset
        currentItem.backAssetIdentifier = frontAsset

        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    private func revertCurrentItemToOriginal(backside: Bool) async {
        guard currentItem.canRevertToOriginal(backside: backside) else { return }
        currentItem.revertToOriginal(backside: backside)
        try? modelContext.save()

        let assetID = backside ? currentItem.backAssetIdentifier : currentItem.frontAssetIdentifier
        if let assetID, !assetID.isEmpty {
            _ = try? await PhotoLibraryManager.shared.revertAssetToOriginal(assetIdentifier: assetID)
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToast(L10n.tr("已復原原圖", "元の画像に戻しました"))
    }

    @MainActor
    private func attachBacksidePhoto(from pickerItem: PhotosPickerItem) async {
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
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

        currentItem.originalBackImageData = rawJPEG
        currentItem.backPerspectivePointsJSON = encodedCorners
        currentItem.backImageData = finalData
        currentItem.backAssetIdentifier = pickerItem.itemIdentifier
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        isShowingBack = true
        withAnimation(flipAnimation) {
            flipProgress = 1.0
        }

        if UserDefaults.standard.bool(forKey: "autoSyncToPhotosLibrary") {
            let target = currentItem
            Task {
                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                    [target],
                    modelContext: modelContext,
                    onlyAlbumAndDateIfAlreadySynced: false
                )
            }
        }
    }

    /// Task 5.4 & 6.1: 從相簿選取第 2 張不同傾斜角度的照片，與當前照片進行極速 Mode B 雙角度去反光合成
    @MainActor
    private func synthesizeModeBSecondAnglePhoto(from pickerItem: PhotosPickerItem) async {
        guard PhotoLibraryManager.isProLifetimeUnlocked else {
            showToast(L10n.tr("去反光合成為 Pro 功能", "反射除去合成は Pro 機能です"))
            return
        }
        guard let secondData = try? await pickerItem.loadTransferable(type: Data.self) else {
            showToast(L10n.tr("無法讀取照片", "写真を読み込めません"))
            return
        }

        let editingBack = isShowingBack && currentItem.hasBothSides
        let primarySourceData = editingBack
            ? (currentItem.originalBackImageData ?? currentItem.backImageData)
            : (currentItem.originalFrontImageData ?? currentItem.frontImageData)

        guard let primaryData = primarySourceData else {
            showToast(L10n.tr("無法讀取照片", "写真を読み込めません"))
            return
        }

        let insetRatio = currentItem.borderInsetRatio
        let preferredFmt = currentItem.filmFormat
        showToast(L10n.tr("去反光合成中⋯", "反射除去を合成中⋯"))

        let fusedOutcome: (fusedCardJPEG: Data, fusedOriginalJPEG: Data?, cornersJSON: String?)? = await Task.detached(priority: .userInitiated) { () -> (fusedCardJPEG: Data, fusedOriginalJPEG: Data?, cornersJSON: String?)? in
            guard let primaryCG = UIImage(data: primaryData)?.normalizedImage.cgImage,
                  let secondCG = UIImage(data: secondData)?.normalizedImage.cgImage else {
                return nil
            }
            let visionManager = VisionManager()
            guard let result = try? await visionManager.synthesizeModeBDualAngleAntiGlare(
                primaryImage: primaryCG,
                secondaryImage: secondCG,
                borderInsetRatio: insetRatio,
                preferredFormat: preferredFmt
            ),
            let cardJPEG = UIImage(cgImage: result.fusedCGImage).jpegData(compressionQuality: 0.92) else {
                return nil
            }
            let origJPEG = UIImage(cgImage: result.fusedOriginalCGImage).jpegData(compressionQuality: 0.92)
            let cornersJSON = ChekiItem.encodeNormalizedCorners(
                result.primaryDetection.corners,
                imageSize: result.primaryDetection.imageSize
            )
            return (cardJPEG, origJPEG, cornersJSON)
        }.value

        if let fusedOutcome {
            if editingBack {
                currentItem.originalBackImageData = fusedOutcome.fusedOriginalJPEG ?? currentItem.originalBackImageData ?? currentItem.backImageData
                if let cornersJSON = fusedOutcome.cornersJSON {
                    currentItem.backPerspectivePointsJSON = cornersJSON
                }
                currentItem.backImageData = fusedOutcome.fusedCardJPEG
            } else {
                currentItem.originalFrontImageData = fusedOutcome.fusedOriginalJPEG ?? currentItem.originalFrontImageData ?? currentItem.frontImageData
                if let cornersJSON = fusedOutcome.cornersJSON {
                    currentItem.perspectivePointsJSON = cornersJSON
                }
                currentItem.frontImageData = fusedOutcome.fusedCardJPEG
            }
            try? modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast(L10n.tr("已完成去反光合成", "反射除去合成が完了しました"))
            await syncCurrentItemToSystemPhotos()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showToast(L10n.tr("對位失敗，請確認四邊完整", "位置合わせに失敗しました"))
        }
    }

    /// 從 App 內現有的拍立得項目 (`sourceItem`) 選取照片綁定為當前項目的背面
    @MainActor
    private func attachBacksideFromInAppItem(_ sourceItem: ChekiItem, mergeAndRemoveSource: Bool) {
        let target = currentItem
        guard sourceItem.id != target.id,
              let sourceImageData = sourceItem.frontImageData else { return }

        target.backImageData = sourceImageData
        target.originalBackImageData = sourceItem.originalFrontImageData ?? sourceImageData
        target.backPerspectivePointsJSON = sourceItem.perspectivePointsJSON
        target.backAssetIdentifier = sourceItem.frontAssetIdentifier

        if mergeAndRemoveSource {
            if let sourceBackData = sourceItem.backImageData {
                // 若原項目本身已有背面，將其背面升格為正面保留，不遺失照片
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
        isShowingBack = true
        withAnimation(flipAnimation) {
            flipProgress = 1.0
        }
        showToast(L10n.tr("已設定背面照片", "裏面を設定しました"))

        if UserDefaults.standard.bool(forKey: "autoSyncToPhotosLibrary") {
            Task {
                await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
                    [target],
                    modelContext: modelContext,
                    onlyAlbumAndDateIfAlreadySynced: false
                )
            }
        }
    }

    /// 把目前這一面逆時針轉 90° 並存檔。直式被存成橫式時可從選單直接轉正。
    private func rotateCurrentFaceQuarterTurn() {
        let editingBack = isShowingBack && currentItem.hasBothSides
        let sourceData = editingBack ? currentItem.backImageData : currentItem.frontImageData
        guard let sourceData, let image = UIImage(data: sourceData) else { return }
        let rotated = image.rotatedQuarterTurnCounterClockwise()
        guard let jpeg = rotated.jpegData(compressionQuality: 0.92) else { return }

        if editingBack {
            currentItem.backImageData = jpeg
        } else {
            currentItem.frontImageData = jpeg
            if currentItem.detectedAspectRatio > 0 {
                currentItem.detectedAspectRatio = 1.0 / currentItem.detectedAspectRatio
            }
        }
        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await syncCurrentItemToSystemPhotos() }
    }

    @MainActor
    private func syncCurrentItemToSystemPhotos() async {
        guard let frontData = currentItem.frontImageData,
              let frontImage = UIImage(data: frontData) else { return }

        let syncDate = currentItem.displayDate
        let albumName = currentItem.idolMember?.albumTitle ?? "ChekiLens"
        let folderName = currentItem.idolMember?.group?.name

        do {
            let album = try await PhotoLibraryManager.shared.getOrCreateAlbum(
                albumName: albumName,
                inFolder: folderName
            )
            let updatedFrontAssetID = try await PhotoLibraryManager.shared.updateOrSaveImage(
                frontImage,
                originalImageData: currentItem.originalFrontImageData,
                existingAssetIdentifier: currentItem.frontAssetIdentifier,
                creationDate: syncDate,
                to: album
            )
            currentItem.frontAssetIdentifier = updatedFrontAssetID

            if let backData = currentItem.backImageData,
               let backImage = UIImage(data: backData) {
                let updatedBackAssetID = try await PhotoLibraryManager.shared.updateOrSaveImage(
                    backImage,
                    originalImageData: currentItem.originalBackImageData,
                    existingAssetIdentifier: currentItem.backAssetIdentifier,
                    creationDate: syncDate,
                    to: album
                )
                currentItem.backAssetIdentifier = updatedBackAssetID
            }
            currentItem.isSyncedToPhotoLibrary = true
            currentItem.isDateWrittenToAlbum = (currentItem.ocrDate != nil)
            try? modelContext.save()
            if PhotoLibraryManager.isProLifetimeUnlocked {
                showToast(L10n.tr("已更新系統相簿 · \(albumName)", "写真アプリを更新 · \(albumName)"))
            } else {
                showToast(L10n.tr("已同步至系統相簿", "写真アプリに同期しました"))
            }
        } catch {
            showToast(L10n.tr("請開啟照片存取權限", "写真へのアクセス許可が必要です"))
        }
    }

    private func showToast(_ message: String) {
        withAnimation {
            syncStatusToast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation {
                if syncStatusToast == message {
                    syncStatusToast = nil
                }
            }
        }
    }

    private func shareCurrentItem() {
        StoreKitManager.shared.refreshDailyFreeQuotaIfNeeded()
        let isPro = PhotoLibraryManager.isProLifetimeUnlocked
        let canUseDailyFreeQuota = !isPro && StoreKitManager.shared.hasDailyFreeQuotaAvailable
        let shouldExportFullResWithoutWatermark = isPro || canUseDailyFreeQuota

        var shareItems: [Any] = []
        if let frontData = currentItem.frontImageData,
           let frontUI = UIImage(data: frontData) {
            shareItems.append(
                shouldExportFullResWithoutWatermark
                    ? frontUI
                    : ChekiWatermarkRenderer.applyWatermarkIfNeeded(to: frontUI, downscaleForSNS: true)
            )
        }
        if let backData = currentItem.backImageData,
           let backUI = UIImage(data: backData) {
            shareItems.append(
                shouldExportFullResWithoutWatermark
                    ? backUI
                    : ChekiWatermarkRenderer.applyWatermarkIfNeeded(to: backUI, downscaleForSNS: true)
            )
        }
        guard !shareItems.isEmpty else { return }

        if !isPro && !canUseDailyFreeQuota {
            showToast(L10n.tr("今日免費高畫質已用畢，以 SNS 畫質輸出", "本日の無料高画質枠は使用済みです"))
        }

        let activityVC = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else { return }
            Task { @MainActor in
                if canUseDailyFreeQuota {
                    StoreKitManager.shared.consumeDailyFreeQuotaIfAvailable()
                    showToast(L10n.tr("已使用今日免費高畫質輸出", "本日の無料高画質出力を使用しました"))
                }
            }
        }

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = scene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func deleteCurrentItem() {
        guard !isDeletingItem, let targetToDelete = currentItemOpt else { return }
        isDeletingItem = true

        let items = filmstripItems
        let targetID = targetToDelete.id
        var nextID: UUID? = nil
        if let idx = items.firstIndex(where: { $0.id == targetID }) {
            if idx + 1 < items.count {
                nextID = items[idx + 1].id
            } else if idx - 1 >= 0 {
                nextID = items[idx - 1].id
            }
        }

        Task { @MainActor in
            await PhotoLibraryManager.shared.deleteItemsAsync(
                [targetToDelete],
                modelContext: modelContext,
                onBeforeContextDelete: {
                    deletedItemIDs.insert(targetID)
                    if let nextID {
                        NavigationChromeState.shared.activeZoomItemID = nextID
                        withAnimation(.snappy(duration: 0.25)) {
                            currentItemID = nextID
                            isShowingBack = false
                            flipProgress = 0.0
                        }
                    } else {
                        performImmediateDismiss()
                    }
                }
            )
            isDeletingItem = false
        }
    }

    // MARK: - 6. 日期藥丸格式化與背景封面手寫日期補齊

    @MainActor
    private func ensureCoverDateAndFormatNormalized(for target: ChekiItem) async {
        guard !target.isDeleted, target.modelContext != nil else { return }
        var didMutate = false

        // 1. 確保規格為三種具體規格之一（Instax Mini / Square / Wide）
        if target.filmFormat == .auto {
            var imgSize: CGSize? = nil
            if let data = target.frontImageData, let img = UIImage(data: data) {
                imgSize = img.size
            }
            let concrete = FilmFormat.resolvedConcreteFormat(
                preferred: .auto,
                specName: nil,
                outputSize: imgSize
            )
            target.filmFormat = concrete
            target.detectedAspectRatio = concrete.aspectRatio
            didMutate = true
        }

        // 2. 清除舊版自動塞入的系統匯入備忘文字
        if let memo = target.memo {
            if let note = memo.noteText,
               (note.hasPrefix("透過批次配對工作台") || note.hasPrefix("透過批次工作台")) {
                memo.noteText = nil
                didMutate = true
            }
            if memo.eventName == "批次配對匯入" {
                memo.eventName = nil
                didMutate = true
            }
        }

        if didMutate {
            try? modelContext.save()
        }

        // 3. 若尚未辨識出封面手寫日期，自動於背景辨識並填入拍攝日期
        guard !target.isDeleted, target.modelContext != nil, target.ocrDate == nil, !target.isJudgedDateManuallySet else { return }
        guard let data = target.frontImageData ?? target.originalFrontImageData,
              let uiImage = UIImage(data: data)?.normalizedImage,
              let cgImage = uiImage.cgImage else { return }

        let visionManager = VisionManager()
        if let ocrResult = await visionManager.recognizeDate(from: cgImage) {
            guard !target.isDeleted, target.modelContext != nil else { return }
            target.applyAutomaticJudgedDate(ocrResult.date, preservingTimeFrom: target.appOriginalCaptureDate)
            try? modelContext.save()
        } else if let origData = target.originalFrontImageData,
                  origData != data,
                  let origUI = UIImage(data: origData)?.normalizedImage,
                  let origCG = origUI.cgImage,
                  let fallbackResult = await visionManager.recognizeDate(from: origCG) {
            guard !target.isDeleted, target.modelContext != nil else { return }
            target.applyAutomaticJudgedDate(fallbackResult.date, preservingTimeFrom: target.appOriginalCaptureDate)
            try? modelContext.save()
        }
    }

    static func datePillPrimaryString(from date: Date) -> String {
        ChekiItem.formatFullDateWithWeekday(date)
    }

    static func datePillTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - ChekiQuadCropEditorView (Apple Photos 風格全螢幕手動四頂點透視裁切與雙指縮放編輯器)

private struct ChekiQuadCropEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let item: ChekiItem
    let initialEditingBackside: Bool
    let onRequestBacksidePicker: () -> Void
    let onAppliedToast: (String) -> Void

    // 編輯正/反面狀態
    @State private var editingBackside: Bool

    // 來源底圖（含完整外圍區域供重新手動調整四個頂點）
    @State private var sourceUIImage: UIImage?
    // 四個頂點（正規化 0.0 ~ 1.0，順序：[TL, TR, BR, BL]）
    @State private var normalizedCorners: [CGPoint] = [
        CGPoint(x: 0.12, y: 0.12),
        CGPoint(x: 0.88, y: 0.12),
        CGPoint(x: 0.88, y: 0.88),
        CGPoint(x: 0.12, y: 0.88)
    ]
    @State private var initialCornersSnapshot: [CGPoint] = []
    @State private var activeDraggingCornerIndex: Int? = nil

    // 雙指縮放與畫布平移狀態 (Two-finger Pinch-to-Zoom & Pan)
    @State private var zoomScale: CGFloat = 1.0
    @State private var activePinchScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var activePanDelta: CGSize = .zero

    // 相紙比例與設定邊界微調
    @AppStorage("defaultBorderInsetPercentage") private var defaultBorderInsetPercentage: Double = 0.0
    @State private var selectedFormat: FilmFormat
    @State private var isProcessingCrop: Bool = false
    @State private var statusBannerText: String? = nil
    @State private var showingSettingsSheet: Bool = false

    private let cornerNames = ["左上", "右上", "右下", "左下"]

    init(
        item: ChekiItem,
        initialEditingBackside: Bool,
        onRequestBacksidePicker: @escaping () -> Void,
        onAppliedToast: @escaping (String) -> Void
    ) {
        self.item = item
        self.initialEditingBackside = initialEditingBackside
        self.onRequestBacksidePicker = onRequestBacksidePicker
        self.onAppliedToast = onAppliedToast
        _editingBackside = State(initialValue: initialEditingBackside && item.hasBothSides)
        _selectedFormat = State(initialValue: item.filmFormat)
    }

    private var effectiveZoom: CGFloat {
        max(0.65, min(4.5, zoomScale * activePinchScale))
    }

    private var hasUnsavedChanges: Bool {
        guard initialCornersSnapshot.count == 4, normalizedCorners.count == 4 else { return true }
        for i in 0..<4 {
            if hypot(normalizedCorners[i].x - initialCornersSnapshot[i].x,
                     normalizedCorners[i].y - initialCornersSnapshot[i].y) > 0.002 {
                return true
            }
        }
        if selectedFormat != item.filmFormat { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topNavigationToolbar

                cropCanvasArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomAdjustmentToolbar
            }

            if isProcessingCrop {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text(L10n.tr("裁切中…", "トリミング中…"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
        }
        .onAppear {
            loadSourceImageAndCorners(forBackside: editingBackside)
        }
        .onChange(of: editingBackside) { _, newValue in
            resetZoomAndPan()
            loadSourceImageAndCorners(forBackside: newValue)
        }
    }

    // MARK: - 1. 頂部工具列 (取消 / 正反切換 / 完成)

    private var topNavigationToolbar: some View {
        HStack(spacing: 12) {
            // 左側：取消 (✕)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .detailLiquidGlassCircle(size: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消裁切")

            Spacer()

            // 中央：若有正反雙面可切換
            if item.hasBothSides {
                HStack(spacing: 2) {
                    Button {
                        editingBackside = false
                    } label: {
                        Text(L10n.tr("正面", "表面"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(!editingBackside ? Color.black : Color.white)
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(!editingBackside ? Color.white : Color.clear, in: Capsule())
                    }
                    Button {
                        editingBackside = true
                    } label: {
                        Text(L10n.tr("背面", "裏面"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(editingBackside ? Color.black : Color.white)
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(editingBackside ? Color.white : Color.clear, in: Capsule())
                    }
                }
                .padding(3)
                .detailLiquidGlassCapsule()

                Spacer()
            }

            // 縮放倍率重置標籤（當雙指縮放時顯示）
            if abs(effectiveZoom - 1.0) > 0.03 {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        resetZoomAndPan()
                    }
                } label: {
                    Text(String(format: "%.1fx", effectiveZoom))
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .detailLiquidGlassCapsule()
                }
                .buttonStyle(.plain)
            }

            // 右側：完成 (✓)
            Button {
                Task {
                    await applyManualQuadCropAndSave()
                }
            } label: {
                Text(L10n.tr("完成", "完了"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .detailLiquidGlassCapsule()
            }
            .disabled(isProcessingCrop)
            .accessibilityLabel("完成裁切")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 2. 中央互動畫布（透明灰色切除遮罩 + 四頂點可移出相片外拖曳 + 雙指縮放 + 放大鏡）

    private var cropCanvasArea: some View {
        GeometryReader { geo in
            let viewportSize = geo.size
            if let uiImage = sourceUIImage {
                // 預留充足畫布邊距 (44pt)，方便將四個頂點直接拉到相片邊界外
                let baseRect = Self.aspectFitRect(imageSize: uiImage.size, in: viewportSize, padding: 44)
                let transformedRect = Self.transformedImageRect(
                    baseRect: baseRect,
                    viewportSize: viewportSize,
                    scale: effectiveZoom,
                    pan: CGSize(
                        width: panOffset.width + activePanDelta.width,
                        height: panOffset.height + activePanDelta.height
                    )
                )
                let screenCorners = normalizedCorners.map { pt in
                    CGPoint(
                        x: transformedRect.minX + pt.x * transformedRect.width,
                        y: transformedRect.minY + pt.y * transformedRect.height
                    )
                }

                ZStack {
                    // 底層：原始圖片（支援雙指縮放與平移，並繪製細虛線標示相片原始邊界）
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .overlay(
                            Rectangle()
                                .strokeBorder(
                                    Color.white.opacity(0.28),
                                    style: StrokeStyle(lineWidth: 1.0, dash: [4, 4])
                                )
                        )
                        .frame(width: transformedRect.width, height: transformedRect.height)
                        .position(x: transformedRect.midX, y: transformedRect.midY)

                    // 切除的部分用透明灰色 (Even-Odd Fill 並裁切於 transformedRect 內，避免頂點拉出相片外時產生反向灰塊)
                    Path { path in
                        path.addRect(transformedRect)
                        if screenCorners.count == 4 {
                            path.move(to: screenCorners[0])
                            path.addLine(to: screenCorners[1])
                            path.addLine(to: screenCorners[2])
                            path.addLine(to: screenCorners[3])
                            path.closeSubpath()
                        }
                    }
                    .fill(Color(white: 0.22).opacity(0.66), style: FillStyle(eoFill: true))
                    .clipShape(Rectangle().path(in: transformedRect))
                    .allowsHitTesting(false)

                    // 雙指縮放與單指空白處拖曳平移手勢層
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(canvasPanAndPinchGesture(baseRect: baseRect, viewportSize: viewportSize))
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                if abs(effectiveZoom - 1.0) > 0.05 {
                                    resetZoomAndPan()
                                } else {
                                    zoomScale = 2.0
                                }
                            }
                        }

                    // 四邊形白色邊框 + 3x3 透視九宮格輔助線（可延伸至相片外）
                    if screenCorners.count == 4 {
                        quadGridAndBorderOverlay(screenCorners: screenCorners)
                            .allowsHitTesting(false)
                    }

                    // 四個可獨立移動的頂點控制柄 (TL, TR, BR, BL)，支援拉出相片外
                    ForEach(0..<min(4, screenCorners.count), id: \.self) { index in
                        vertexHandle(
                            index: index,
                            screenPoint: screenCorners[index],
                            transformedRect: transformedRect,
                            viewportSize: viewportSize
                        )
                    }

                    // 拖曳頂點時的局部放大鏡 (Magnifying Loupe)
                    if let activeIdx = activeDraggingCornerIndex,
                       activeIdx < normalizedCorners.count {
                        vertexLoupeView(
                            uiImage: uiImage,
                            normalizedPoint: normalizedCorners[activeIdx],
                            cornerIndex: activeIdx,
                            viewportSize: viewportSize
                        )
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }

                    // 頂部操作提示膠囊
                    VStack {
                        if let banner = statusBannerText {
                            Text(banner)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.top, 6)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else if activeDraggingCornerIndex == nil {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.point.up.left.and.text")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(L10n.tr("拖曳四角微調 · 雙指縮放", "四隅をドラッグ · ピンチで拡大"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(.top, 6)
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                .coordinateSpace(name: "QuadCropViewport")
                .clipped()
            } else {
                ContentUnavailableView(L10n.tr("無法載入影像", "画像を読み込めません"), systemImage: "photo.badge.exclamationmark")
            }
        }
    }

    // MARK: - 四邊形格線與外框繪製

    private func quadGridAndBorderOverlay(screenCorners: [CGPoint]) -> some View {
        ZStack {
            // 3x3 雙線性插值透視網格
            Path { path in
                let tl = screenCorners[0]
                let tr = screenCorners[1]
                let br = screenCorners[2]
                let bl = screenCorners[3]

                for step in 1...2 {
                    let t = CGFloat(step) / 3.0
                    // 垂直分割線 (Top -> Bottom)
                    let topPt = CGPoint(x: tl.x + (tr.x - tl.x) * t, y: tl.y + (tr.y - tl.y) * t)
                    let botPt = CGPoint(x: bl.x + (br.x - bl.x) * t, y: bl.y + (br.y - bl.y) * t)
                    path.move(to: topPt)
                    path.addLine(to: botPt)

                    // 水平分割線 (Left -> Right)
                    let leftPt = CGPoint(x: tl.x + (bl.x - tl.x) * t, y: tl.y + (bl.y - tl.y) * t)
                    let rightPt = CGPoint(x: tr.x + (br.x - tr.x) * t, y: tr.y + (br.y - tr.y) * t)
                    path.move(to: leftPt)
                    path.addLine(to: rightPt)
                }
            }
            .stroke(
                Color.white.opacity(activeDraggingCornerIndex != nil ? 0.58 : 0.30),
                style: StrokeStyle(lineWidth: 0.85)
            )

            // 四頂點實線主外框
            Path { path in
                path.move(to: screenCorners[0])
                path.addLine(to: screenCorners[1])
                path.addLine(to: screenCorners[2])
                path.addLine(to: screenCorners[3])
                path.closeSubpath()
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
        }
    }

    // MARK: - 單一頂點控制柄 (Apple Photos L 型角標 + 圓形精準錨點，支援移出相片邊界外)

    private func vertexHandle(
        index: Int,
        screenPoint: CGPoint,
        transformedRect: CGRect,
        viewportSize: CGSize
    ) -> some View {
        let isDragging = (activeDraggingCornerIndex == index)

        return ZStack {
            // 外圈觸控光暈
            Circle()
                .fill(isDragging ? Color.white.opacity(0.28) : Color.black.opacity(0.28))
                .frame(width: isDragging ? 42 : 30, height: isDragging ? 42 : 30)

            // 白色/黃色粗框圓環 + 中心準星
            Circle()
                .strokeBorder(Color.white, lineWidth: 3.0)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.55), radius: 3, y: 1)

            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
        }
        .frame(width: 52, height: 52)
        .contentShape(Circle())
        .position(screenPoint)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("QuadCropViewport"))
                .onChanged { value in
                    if activeDraggingCornerIndex != index {
                        activeDraggingCornerIndex = index
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    guard transformedRect.width > 10, transformedRect.height > 10 else { return }
                    let safeScreenX = min(max(value.location.x, 12), max(12, viewportSize.width - 12))
                    let safeScreenY = min(max(value.location.y, 12), max(12, viewportSize.height - 12))
                    let nx = (safeScreenX - transformedRect.minX) / transformedRect.width
                    let ny = (safeScreenY - transformedRect.minY) / transformedRect.height
                    // 允許頂點移出相片範圍外 (-0.45 ~ 1.45)，方便處理邊角稍微超出畫面的傾斜拍立得
                    let clamped = CGPoint(
                        x: min(max(nx, -0.45), 1.45),
                        y: min(max(ny, -0.45), 1.45)
                    )
                    normalizedCorners[index] = clamped
                }
                .onEnded { _ in
                    activeDraggingCornerIndex = nil
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
        )
        .accessibilityLabel("移動\(cornerNames[index])頂點")
    }

    // MARK: - 頂點局部放大鏡 (Magnifying Loupe + 中心十字準星)

    private func vertexLoupeView(
        uiImage: UIImage,
        normalizedPoint: CGPoint,
        cornerIndex: Int,
        viewportSize: CGSize
    ) -> some View {
        let loupeDiameter: CGFloat = 108
        let zoomFactor: CGFloat = 2.8
        let displayedW = loupeDiameter * zoomFactor
        let displayedH = displayedW * (uiImage.size.height / max(1, uiImage.size.width))
        let offsetX = (0.5 - normalizedPoint.x) * displayedW
        let offsetY = (0.5 - normalizedPoint.y) * displayedH
        let center = loupeDiameter / 2.0
        let armLength: CGFloat = 18.0

        return VStack {
            HStack {
                if cornerIndex == 0 || cornerIndex == 3 {
                    Spacer()
                }

                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .overlay(
                        Rectangle()
                            .strokeBorder(
                                Color.white.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1.0, dash: [3, 3])
                            )
                    )
                    .frame(width: displayedW, height: displayedH)
                    .offset(x: offsetX, y: offsetY)
                    .frame(width: loupeDiameter, height: loupeDiameter)
                    .background(Color(white: 0.10))
                    .clipShape(Circle())
                    .overlay {
                        // 放大鏡中心標記（十字準星 + 黑色高對比描邊，確保在白邊/深色背景皆清晰可見）
                        ZStack {
                            // 全幅細輔助十字線
                            Path { path in
                                path.move(to: CGPoint(x: center, y: 0))
                                path.addLine(to: CGPoint(x: center, y: loupeDiameter))
                                path.move(to: CGPoint(x: 0, y: center))
                                path.addLine(to: CGPoint(x: loupeDiameter, y: center))
                            }
                            .stroke(Color.white.opacity(0.32), lineWidth: 0.75)

                            // 中心十字準星深色外框襯底（在拍立得白邊上提供高對比）
                            Path { path in
                                path.move(to: CGPoint(x: center - armLength, y: center))
                                path.addLine(to: CGPoint(x: center + armLength, y: center))
                                path.move(to: CGPoint(x: center, y: center - armLength))
                                path.addLine(to: CGPoint(x: center, y: center + armLength))
                            }
                            .stroke(Color.black.opacity(0.78), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))

                            // 中心十字準星亮黃色主線 (+)
                            Path { path in
                                path.move(to: CGPoint(x: center - armLength, y: center))
                                path.addLine(to: CGPoint(x: center + armLength, y: center))
                                path.move(to: CGPoint(x: center, y: center - armLength))
                                path.addLine(to: CGPoint(x: center, y: center + armLength))
                            }
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

                            // 中心精準定位小圓環
                            Circle()
                                .strokeBorder(Color.black.opacity(0.75), lineWidth: 2.2)
                                .frame(width: 7, height: 7)

                            Circle()
                                .strokeBorder(Color.white, lineWidth: 1.2)
                                .frame(width: 7, height: 7)
                        }
                        .frame(width: loupeDiameter, height: loupeDiameter)
                        .clipShape(Circle())
                    }
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 2.5)
                    )
                    .overlay(alignment: .bottom) {
                        Text(cornerNames[cornerIndex])
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .offset(y: 8)
                    }
                    .shadow(color: .black.opacity(0.65), radius: 10, y: 4)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                if cornerIndex == 1 || cornerIndex == 2 {
                    Spacer()
                }
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: - 3. 底部 Apple Photos 風格控制面板（相紙比例膠囊 + 自動吸附/旋轉/展開/設定）

    private var bottomAdjustmentToolbar: some View {
        VStack(spacing: 12) {
            // (A) 相紙比例鎖定膠囊列 (Auto / Mini / Square / Wide)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilmFormat.allCases, id: \.self) { format in
                        let isSelected = (selectedFormat == format)
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                selectedFormat = format
                            }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: format == .square ? "square" : (format == .wide ? "rectangle" : "rectangle.portrait"))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(format.displayName)
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.78))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.white : Color.white.opacity(0.16),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }

            // (B) 底部工具動作列（Vision 自動吸附 / 旋轉 90° / 展開四點 / 邊界設定 / 補拍背面）
            HStack(spacing: 16) {
                Button {
                    Task {
                        await runAutoDetectCorners()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "viewfinder.rectangular")
                            .font(.system(size: 18, weight: .semibold))
                        Text(L10n.tr("自動", "自動"))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    rotateSourceImage90DegreesCounterClockwise()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "rotate.left")
                            .font(.system(size: 18, weight: .semibold))
                        Text(L10n.tr("旋轉", "回転"))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        normalizedCorners = [
                            CGPoint(x: 0.04, y: 0.04),
                            CGPoint(x: 0.96, y: 0.04),
                            CGPoint(x: 0.96, y: 0.96),
                            CGPoint(x: 0.04, y: 0.96)
                        ]
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 17, weight: .semibold))
                        Text(L10n.tr("展開", "展開"))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    showingSettingsSheet = true
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.below.square.and.square.filled")
                            .font(.system(size: 17, weight: .semibold))
                        Text(abs(defaultBorderInsetPercentage) > 0.05 ? String(format: "%+.1f%%", defaultBorderInsetPercentage) : L10n.tr("邊界", "余白"))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    onRequestBacksidePicker()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                        Text(L10n.tr("背面", "裏面"))
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .padding(.top, 10)
        .background(Color(white: 0.08).opacity(0.96))
    }

    // MARK: - 4. 雙指縮放與平移手勢計算

    private func canvasPanAndPinchGesture(baseRect: CGRect, viewportSize: CGSize) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { value in
                activePinchScale = value.magnification
            }
            .onEnded { value in
                zoomScale = max(0.65, min(4.5, zoomScale * value.magnification))
                activePinchScale = 1.0
                if abs(zoomScale - 1.0) <= 0.03 {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        zoomScale = 1.0
                        panOffset = .zero
                    }
                } else {
                    panOffset = Self.clampedPanOffset(
                        panOffset,
                        baseRect: baseRect,
                        viewportSize: viewportSize,
                        scale: zoomScale
                    )
                }
            }

        let pan = DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(effectiveZoom - 1.0) > 0.01 else { return }
                activePanDelta = value.translation
            }
            .onEnded { value in
                guard abs(effectiveZoom - 1.0) > 0.01 else {
                    activePanDelta = .zero
                    return
                }
                let rawPan = CGSize(
                    width: panOffset.width + value.translation.width,
                    height: panOffset.height + value.translation.height
                )
                panOffset = Self.clampedPanOffset(
                    rawPan,
                    baseRect: baseRect,
                    viewportSize: viewportSize,
                    scale: zoomScale
                )
                activePanDelta = .zero
            }

        return SimultaneousGesture(magnify, pan)
    }

    private func resetZoomAndPan() {
        zoomScale = 1.0
        activePinchScale = 1.0
        panOffset = .zero
        activePanDelta = .zero
    }

    private func resetCornersToInitial() {
        if initialCornersSnapshot.count == 4 {
            normalizedCorners = initialCornersSnapshot
        }
    }

    // MARK: - 5. 載入底圖、自動偵測與套用四頂點透視裁切

    private func loadSourceImageAndCorners(forBackside: Bool) {
        if forBackside {
            if let origBackData = item.originalBackImageData,
               let origBackImg = UIImage(data: origBackData)?.normalizedImage {
                sourceUIImage = origBackImg
                if let saved = ChekiItem.decodeNormalizedCorners(from: item.backPerspectivePointsJSON) {
                    normalizedCorners = saved
                } else {
                    normalizedCorners = Self.defaultQuadCorners
                }
            } else if let croppedBackData = item.backImageData,
                      let croppedBackImg = UIImage(data: croppedBackData)?.normalizedImage {
                let (canvasImg, defaultCorners) = Self.synthesizeUncroppedCanvas(around: croppedBackImg)
                sourceUIImage = canvasImg
                normalizedCorners = defaultCorners
                if let jpeg = canvasImg.jpegData(compressionQuality: 0.92) {
                    item.originalBackImageData = jpeg
                    item.backPerspectivePointsJSON = ChekiItem.encodeNormalizedCorners(defaultCorners)
                }
            }
        } else {
            if let origFrontData = item.originalFrontImageData,
               let origFrontImg = UIImage(data: origFrontData)?.normalizedImage {
                sourceUIImage = origFrontImg
                if let saved = ChekiItem.decodeNormalizedCorners(from: item.perspectivePointsJSON) {
                    normalizedCorners = saved
                } else {
                    normalizedCorners = Self.defaultQuadCorners
                }
            } else if let croppedFrontData = item.frontImageData,
                      let croppedFrontImg = UIImage(data: croppedFrontData)?.normalizedImage {
                let (canvasImg, defaultCorners) = Self.synthesizeUncroppedCanvas(around: croppedFrontImg)
                sourceUIImage = canvasImg
                normalizedCorners = defaultCorners
                if let jpeg = canvasImg.jpegData(compressionQuality: 0.92) {
                    item.originalFrontImageData = jpeg
                    item.perspectivePointsJSON = ChekiItem.encodeNormalizedCorners(defaultCorners)
                }
            }
        }
        initialCornersSnapshot = normalizedCorners
    }

    @MainActor
    private func runAutoDetectCorners() async {
        guard let uiImage = sourceUIImage, let cgImage = uiImage.cgImage else { return }
        let imgSize = CGSize(width: cgImage.width, height: cgImage.height)
        let visionManager = VisionManager()
        let defaultInsetRatio = defaultBorderInsetPercentage / 100.0

        if let detection = try? await visionManager.detectQuadFastForCamera(
            in: cgImage,
            imageSize: imgSize,
            isKnownFrontPhoto: !editingBackside,
            priorNormalizedCorners: nil
        ),
           detection.corners.count == 4 {
            let ordered = VisionManager.orderPoints(detection.corners)
            let adjusted = await visionManager.applyBorderInset(
                corners: ordered,
                imageSize: imgSize,
                ratio: defaultInsetRatio
            )
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                normalizedCorners = adjusted.map { pt in
                    CGPoint(
                        x: min(max(pt.x / max(1, imgSize.width), -0.45), 1.45),
                        y: min(max(pt.y / max(1, imgSize.height), -0.45), 1.45)
                    )
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if abs(defaultBorderInsetPercentage) > 0.05 {
                showBanner(
                    L10n.tr(
                        String(format: "已自動吸附 · %+.1f%%", defaultBorderInsetPercentage),
                        String(format: "自動吸着 · %+.1f%%", defaultBorderInsetPercentage)
                    )
                )
            } else {
                showBanner(L10n.tr("已自動吸附", "自動吸着しました"))
            }
        } else {
            let basePixels = Self.defaultQuadCorners.map {
                CGPoint(x: $0.x * imgSize.width, y: $0.y * imgSize.height)
            }
            let adjusted = await visionManager.applyBorderInset(
                corners: basePixels,
                imageSize: imgSize,
                ratio: defaultInsetRatio
            )
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                normalizedCorners = adjusted.map { pt in
                    CGPoint(
                        x: min(max(pt.x / max(1, imgSize.width), -0.45), 1.45),
                        y: min(max(pt.y / max(1, imgSize.height), -0.45), 1.45)
                    )
                }
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showBanner(L10n.tr("已重設範圍", "範囲をリセットしました"))
        }
    }

    private func rotateSourceImage90DegreesCounterClockwise() {
        guard let currentImg = sourceUIImage else { return }
        let newSize = CGSize(width: currentImg.size.height, height: currentImg.size.width)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let rotated = renderer.image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: -.pi / 2)
            currentImg.draw(in: CGRect(
                x: -currentImg.size.width / 2,
                y: -currentImg.size.height / 2,
                width: currentImg.size.width,
                height: currentImg.size.height
            ))
        }
        sourceUIImage = rotated
        // 同步逆時針旋轉正規化頂點：(x, y) -> (y, 1 - x)
        let rotatedPts = normalizedCorners.map { pt in
            CGPoint(x: pt.y, y: 1.0 - pt.x)
        }
        normalizedCorners = VisionManager.orderPoints(rotatedPts)
        if let jpeg = rotated.jpegData(compressionQuality: 0.92) {
            if editingBackside {
                item.originalBackImageData = jpeg
            } else {
                item.originalFrontImageData = jpeg
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    private func revertToOriginalAndDismiss() async {
        guard item.canRevertToOriginal(backside: editingBackside) else { return }
        item.revertToOriginal(backside: editingBackside)
        try? modelContext.save()

        let assetID = editingBackside ? item.backAssetIdentifier : item.frontAssetIdentifier
        if let assetID, !assetID.isEmpty {
            _ = try? await PhotoLibraryManager.shared.revertAssetToOriginal(assetIdentifier: assetID)
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onAppliedToast(L10n.tr("已復原原圖", "元画像に戻しました"))
        dismiss()
    }

    @MainActor
    private func applyManualQuadCropAndSave() async {
        guard let uiImage = sourceUIImage, let cgImage = uiImage.cgImage else {
            dismiss()
            return
        }

        isProcessingCrop = true
        defer { isProcessingCrop = false }

        let imgSize = CGSize(width: cgImage.width, height: cgImage.height)
        // 保持使用者在畫布上拉動的 [TL, TR, BR, BL] 頂點順序與精確位置
        let manualNorm = normalizedCorners.count == 4 ? normalizedCorners : Self.defaultQuadCorners
        let pixelCorners = manualNorm.map { pt in
            CGPoint(x: pt.x * imgSize.width, y: pt.y * imgSize.height)
        }

        let visionManager = VisionManager()

        let chekiFormat: ChekiFilmFormat = {
            switch selectedFormat {
            case .mini: return .mini
            case .square: return .square
            case .wide: return .wide
            case .auto: return .auto
            }
        }()

        let manualDetection = DetectionResult(
            corners: pixelCorners,
            method: .visionNative,
            confidence: 1.0,
            imageSize: imgSize
        )

        if let cropResult = try? await visionManager.perspectiveCorrect(
            image: cgImage,
            corners: pixelCorners,
            detection: manualDetection,
            format: chekiFormat,
            preserveCornerOrder: true
        ) {
            let croppedUIImage = UIImage(cgImage: cropResult.cgImage)
            if let croppedJPEG = croppedUIImage.jpegData(compressionQuality: 0.92) {
                let encodedJSON = ChekiItem.encodeNormalizedCorners(manualNorm)
                if editingBackside {
                    if item.originalBackImageData == nil {
                        item.originalBackImageData = item.backImageData ?? uiImage.jpegData(compressionQuality: 0.92)
                    }
                    item.backImageData = croppedJPEG
                    item.backPerspectivePointsJSON = encodedJSON
                } else {
                    if item.originalFrontImageData == nil {
                        item.originalFrontImageData = item.frontImageData ?? uiImage.jpegData(compressionQuality: 0.92)
                    }
                    item.frontImageData = croppedJPEG
                    item.perspectivePointsJSON = encodedJSON
                    if item.ocrDate == nil,
                       !item.isJudgedDateManuallySet,
                       let ocrRes = await visionManager.recognizeDate(from: cropResult.cgImage) {
                        item.applyAutomaticJudgedDate(ocrRes.date, preservingTimeFrom: item.appOriginalCaptureDate)
                    }
                }
                item.borderInsetRatio = defaultBorderInsetPercentage / 100.0
                let resolvedFormat = FilmFormat.resolvedConcreteFormat(
                    preferred: selectedFormat,
                    specName: cropResult.filmSpecification?.format.rawValue,
                    outputSize: cropResult.outputSize
                )
                item.filmFormat = resolvedFormat
                if cropResult.outputSize.width > 0 {
                    item.detectedAspectRatio = Double(cropResult.outputSize.height / cropResult.outputSize.width)
                }
                try? modelContext.save()

                // 若此照片關聯系統相簿 PHAsset，直接修改原圖（不新增重複照片，且保留原始底圖供復原）
                let targetAssetID = editingBackside ? item.backAssetIdentifier : item.frontAssetIdentifier
                let origData = editingBackside ? item.originalBackImageData : item.originalFrontImageData
                if targetAssetID != nil || item.isSyncedToPhotoLibrary {
                    let albumName = item.idolMember?.albumTitle ?? "ChekiLens"
                    let folderName = item.idolMember?.group?.name
                    if let album = try? await PhotoLibraryManager.shared.getOrCreateAlbum(albumName: albumName, inFolder: folderName),
                       let updatedID = try? await PhotoLibraryManager.shared.updateOrSaveImage(
                           croppedUIImage,
                           originalImageData: origData,
                           existingAssetIdentifier: targetAssetID,
                           creationDate: item.displayDate,
                           to: album
                       ) {
                        if editingBackside {
                            item.backAssetIdentifier = updatedID
                        } else {
                            item.frontAssetIdentifier = updatedID
                        }
                        try? modelContext.save()
                    }
                }

                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onAppliedToast(L10n.tr("已儲存裁切", "トリミングを保存しました"))
                dismiss()
            }
        } else {
            showBanner(L10n.tr("頂點不可交錯", "四隅が交差しています"))
        }
    }

    private func showBanner(_ text: String) {
        withAnimation {
            statusBannerText = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                if statusBannerText == text {
                    statusBannerText = nil
                }
            }
        }
    }

    // MARK: - 6. 幾何計算與合成外框輔助函數

    private static let defaultQuadCorners: [CGPoint] = [
        CGPoint(x: 0.12, y: 0.12),
        CGPoint(x: 0.88, y: 0.12),
        CGPoint(x: 0.88, y: 0.88),
        CGPoint(x: 0.12, y: 0.88)
    ]

    /// 為僅有裁切後成品圖的舊資料合成外圍桌面背景，讓使用者進入編輯器時依然能看到外圍「透明灰色切除區」並自由微調四個頂點
    private static func synthesizeUncroppedCanvas(around croppedImage: UIImage) -> (UIImage, [CGPoint]) {
        let marginRatio: CGFloat = 0.12
        let innerW = max(1, croppedImage.size.width)
        let innerH = max(1, croppedImage.size.height)
        let canvasW = round(innerW / (1.0 - marginRatio * 2.0))
        let canvasH = round(innerH / (1.0 - marginRatio * 2.0))
        let originX = round((canvasW - innerW) / 2.0)
        let originY = round((canvasH - innerH) / 2.0)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH), format: format)
        let synthesized = renderer.image { ctx in
            let cg = ctx.cgContext
            // 外圍深色木紋/桌面質感底色
            UIColor(red: 0.16, green: 0.15, blue: 0.18, alpha: 1.0).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

            // 淡淡的環境格紋讓雙指縮放與頂點拖曳有清楚的視覺參照
            UIColor(white: 1.0, alpha: 0.04).setStroke()
            cg.setLineWidth(1.5)
            let step = max(24.0, min(canvasW, canvasH) / 14.0)
            stride(from: 0.0, through: canvasW, by: step).forEach { x in
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: canvasH))
            }
            stride(from: 0.0, through: canvasH, by: step).forEach { y in
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: canvasW, y: y))
            }
            cg.strokePath()

            // 繪製中央拍立得影像
            croppedImage.draw(in: CGRect(x: originX, y: originY, width: innerW, height: innerH))
        }

        let minX = originX / canvasW
        let minY = originY / canvasH
        let maxX = (originX + innerW) / canvasW
        let maxY = (originY + innerH) / canvasH

        let corners = [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: maxY)
        ]
        return (synthesized, corners)
    }

    private static func aspectFitRect(imageSize: CGSize, in viewportSize: CGSize, padding: CGFloat) -> CGRect {
        let availW = max(1, viewportSize.width - padding * 2)
        let availH = max(1, viewportSize.height - padding * 2)
        let imgW = max(1, imageSize.width)
        let imgH = max(1, imageSize.height)
        let scale = min(availW / imgW, availH / imgH)
        let fitW = imgW * scale
        let fitH = imgH * scale
        return CGRect(
            x: (viewportSize.width - fitW) / 2.0,
            y: (viewportSize.height - fitH) / 2.0,
            width: fitW,
            height: fitH
        )
    }

    private static func transformedImageRect(
        baseRect: CGRect,
        viewportSize: CGSize,
        scale: CGFloat,
        pan: CGSize
    ) -> CGRect {
        let clampedPan = clampedPanOffset(pan, baseRect: baseRect, viewportSize: viewportSize, scale: scale)
        let scaledW = baseRect.width * scale
        let scaledH = baseRect.height * scale
        let centerX = viewportSize.width / 2.0 + clampedPan.width
        let centerY = viewportSize.height / 2.0 + clampedPan.height
        return CGRect(
            x: centerX - scaledW / 2.0,
            y: centerY - scaledH / 2.0,
            width: scaledW,
            height: scaledH
        )
    }

    private static func clampedPanOffset(
        _ pan: CGSize,
        baseRect: CGRect,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let scaledW = baseRect.width * scale
        let scaledH = baseRect.height * scale
        let maxOffsetX = max(40, (scaledW - viewportSize.width) / 2.0 + 60)
        let maxOffsetY = max(40, (scaledH - viewportSize.height) / 2.0 + 60)
        return CGSize(
            width: min(max(pan.width, -maxOffsetX), maxOffsetX),
            height: min(max(pan.height, -maxOffsetY), maxOffsetY)
        )
    }

    private static func insetPolygonPoints(_ pts: [CGPoint], ratio: CGFloat) -> [CGPoint] {
        guard pts.count == 4 else { return pts }
        let cx = pts.map(\.x).reduce(0, +) / 4.0
        let cy = pts.map(\.y).reduce(0, +) / 4.0
        let scale = 1.0 + ratio
        return pts.map { pt in
            CGPoint(
                x: cx + (pt.x - cx) * scale,
                y: cy + (pt.y - cy) * scale
            )
        }
    }
}


// MARK: - 單張檢視已解碼圖片快取 (Decoded UIImage Cache for Smooth 120fps Flip & Paging)

private enum ChekiDetailDecodedImageCache {
    private static let cache: NSCache<NSNumber, UIImage> = {
        let c = NSCache<NSNumber, UIImage>()
        c.countLimit = 48
        return c
    }()

    static func image(for data: Data) -> UIImage? {
        var hasher = Hasher()
        hasher.combine(data.count)
        if data.count <= 256 {
            hasher.combine(data)
        } else {
            hasher.combine(data.prefix(128))
            hasher.combine(data.suffix(128))
        }
        let key = NSNumber(value: hasher.finalize())
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = UIImage(data: data) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }
}

// MARK: - 3D 拍立得正反翻轉與 Z 軸浮起容器 (Animatable 3D Flip + Z-Axis Lift)

/// 透過 `Animatable` 連續插值 `flipProgress (0.0 ... 1.0)`：
/// 1. 保持正反兩面同時駐留於 `ZStack`（於 `init` 預先建構視圖，避免 `Animatable` 每幀重跑 closure 與圖片解碼），於 `90°` 垂直切面瞬間無縫切換正反面可見度。
/// 2. 結合 `sin(flipProgress * .pi)` 在翻轉中段將拍立得沿 Z 軸向觀察者微微浮起 (`scale` 放大) 並向上微移 (`offset.y` 上提)，落定時平滑復原。
private struct Cheki3DFlipContainer<Front: View, Back: View>: View, Animatable {
    var flipProgress: Double
    let front: Front
    let back: Back

    init(
        flipProgress: Double,
        @ViewBuilder front: () -> Front,
        @ViewBuilder back: () -> Back
    ) {
        self.flipProgress = flipProgress
        self.front = front()
        self.back = back()
    }

    var animatableData: Double {
        get { flipProgress }
        set { flipProgress = newValue }
    }

    var body: some View {
        let clamped = min(max(flipProgress, 0.0), 1.0)
        let angle = clamped * 180.0
        let isBackVisible = angle >= 90.0

        // Z 軸與向上微幅浮起曲線：0 -> 1 (90° 中點最高峰) -> 0 (180° 落定復原)
        let liftPhase = sin(clamped * .pi)
        let zLiftScale = 1.0 + 0.085 * liftPhase
        let upwardLiftOffset = -18.0 * liftPhase
        let shadowRadius = 22.0 + 18.0 * liftPhase
        let shadowY = 12.0 + 14.0 * liftPhase

        ZStack {
            front
                .opacity(isBackVisible ? 0.0 : 1.0)
                .allowsHitTesting(!isBackVisible)

            back
                .rotation3DEffect(
                    .degrees(180),
                    axis: (x: 0, y: 1, z: 0)
                )
                .opacity(isBackVisible ? 1.0 : 0.0)
                .allowsHitTesting(isBackVisible)
        }
        .rotation3DEffect(
            .degrees(angle),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.45
        )
        .scaleEffect(zLiftScale)
        .offset(y: upwardLiftOffset)
        .shadow(color: .black.opacity(0.76), radius: shadowRadius, x: 0, y: shadowY)
    }
}

// MARK: - 從 App 內選取背面照片選擇器 (InAppBacksidePickerSheet)

struct InAppBacksidePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let targetItem: ChekiItem
    let candidates: [ChekiItem]
    let onSelectItem: (ChekiItem, Bool) -> Void

    enum FilterScope: String, CaseIterable, Identifiable {
        case all = "全部照片"
        case sameAlbum = "同相冊"
        case singleOnly = "僅單面"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all:
                return L10n.tr("全部", "すべて")
            case .sameAlbum:
                return L10n.tr("同相冊", "同アルバム")
            case .singleOnly:
                return L10n.tr("單面", "片面")
            }
        }
    }

    @State private var filterScope: FilterScope = .all
    @State private var selectedCandidateID: UUID? = nil
    @State private var mergeAndRemoveSource: Bool = true

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var availableScopes: [FilterScope] {
        if targetItem.idolMember != nil {
            return [.all, .sameAlbum, .singleOnly]
        }
        return [.all, .singleOnly]
    }

    private var filteredCandidates: [ChekiItem] {
        let base = candidates.filter { $0.frontImageData != nil }
        switch filterScope {
        case .all:
            return base
        case .sameAlbum:
            guard let targetMemberID = targetItem.idolMember?.id else {
                return base.filter { $0.idolMember == nil }
            }
            return base.filter { $0.idolMember?.id == targetMemberID }
        case .singleOnly:
            return base.filter { !$0.hasBothSides }
        }
    }

    private var selectedCandidate: ChekiItem? {
        guard let id = selectedCandidateID else { return nil }
        return filteredCandidates.first(where: { $0.id == id }) ?? candidates.first(where: { $0.id == id })
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy.MM.dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if availableScopes.count > 1 {
                        Picker("篩選範圍", selection: $filterScope.animation(.snappy(duration: 0.2))) {
                            ForEach(availableScopes) { scope in
                                if scope == .sameAlbum, let name = targetItem.idolMember?.stageName {
                                    Text("\(scope.displayName) · \(name)").tag(scope)
                                } else {
                                    Text(scope.displayName).tag(scope)
                                }
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle(isOn: $mergeAndRemoveSource) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("合併原項目", "元項目を統合"))
                                .font(.subheadline.weight(.medium))
                            Text(L10n.tr("避免重複顯示", "重複表示を防ぎます"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemGroupedBackground))

                Divider()

                if filteredCandidates.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.tr("無可用照片", "写真なし"), systemImage: "photo.on.rectangle.angled")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(filteredCandidates) { candidate in
                                candidateCell(for: candidate)
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.tr("選擇背面", "裏面を選択"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "完了")) {
                        if let chosen = selectedCandidate {
                            onSelectItem(chosen, mergeAndRemoveSource)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedCandidate == nil)
                }
            }
        }
        .applyAppAppearanceAndLocale()
    }

    @ViewBuilder
    private func candidateCell(for candidate: ChekiItem) -> some View {
        let isSelected = (selectedCandidateID == candidate.id)
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.18)) {
                if selectedCandidateID == candidate.id {
                    onSelectItem(candidate, mergeAndRemoveSource)
                    dismiss()
                } else {
                    selectedCandidateID = candidate.id
                }
            }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    if let data = candidate.frontImageData,
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .aspectRatio(0.72, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                            .aspectRatio(0.72, contentMode: .fit)
                    }

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isSelected ? .white : .white.opacity(0.85),
                            isSelected ? .blue : .black.opacity(0.35)
                        )
                        .padding(6)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2.5)
                )

                HStack(spacing: 4) {
                    Text(Self.dateFormatter.string(from: candidate.displayDate))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let memberName = candidate.idolMember?.stageName {
                        Text(memberName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    @ViewBuilder
    func detailLiquidGlassCircle(size: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            self
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
                )
        }
    }

    @ViewBuilder
    func detailLiquidGlassCapsule(interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                self
                    .glassEffect(.regular, in: .capsule)
            }
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.6)
                )
        }
    }
}

// MARK: - Preview

#Preview("05. 單張全螢幕檢視 (Apple Photos Detail)") {
    let container = try! ModelContainerProvider.preview(withSampleData: true)
    let firstItem = (try? container.mainContext.fetch(FetchDescriptor<ChekiItem>()).first) ?? ChekiItem()
    return NavigationStack {
        ChekiDetailView(item: firstItem)
    }
    .modelContainer(container)
}
