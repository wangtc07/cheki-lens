import SwiftUI
import SwiftData
import PhotosUI
import UIKit

// MARK: - ChekiDetailView (Task 4.5: 05. 写真詳細 單張全螢幕檢視 — 嚴格遵循 Apple iOS 18 原生相簿設計)

/// 單張拍立得全螢幕檢視器（對齊 iOS 18 Apple 原生「照片」單張檢視介面）
/// - 頂部：左側圓形毛玻璃返回鈕、中央半透明「日期時間藥丸 (`9月17日 · 16:26`)」、右側圓形 `⋯` 更多選單
/// - 中央：支援 3D Y 軸 180° 翻轉動畫（查看背面手寫簽名）、雙指縮放、左右滑動切換上/下一張、向上滑動呼出資訊面板
/// - 底部：縮圖膠卷滾動條 (Filmstrip Scrubber) ＋ Apple 標準 5 大工具列按鈕（分享、愛心、ℹ️、調整、垃圾桶）
struct ChekiDetailView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var allChekiItems: [ChekiItem]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]
    @AppStorage("hasSeenDetailCoachMark") private var hasSeenDetailCoachMark: Bool = false

    /// 初始點進來的拍立得項目
    let item: ChekiItem

    /// 當前正在檢視的拍立得（透過底部縮圖膠卷或左右滑動可即時切換）
    @State private var currentItemID: UUID?
    /// 上一張檢視的拍立得 ID（確保跨張點擊縮圖時離場卡片也能平滑滑動）
    @State private var previousItemID: UUID?
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

    /// 雙指縮放倍率
    @State private var zoomScale: CGFloat = 1.0
    @State private var activePinchScale: CGFloat = 1.0

    /// 彈窗與面板控制
    @State private var showingInfoSheet: Bool = false
    @State private var showingAdjustmentSheet: Bool = false
    @State private var showDeleteConfirm: Bool = false

    /// 補上/替換背面照片的 PhotosPicker
    @State private var backsidePickerItem: PhotosPickerItem? = nil
    @State private var isShowingBacksidePicker: Bool = false

    /// Task 5.4: Mode B 雙角度去反光合成第二角度照片選擇器 (Pro 專屬)
    @State private var modeBSecondAnglePickerItem: PhotosPickerItem? = nil
    @State private var isShowingModeBSecondAnglePicker: Bool = false

    /// 同步至系統相簿提示
    @State private var syncStatusToast: String? = nil

    init(item: ChekiItem) {
        self.item = item
        _currentItemID = State(initialValue: item.id)
    }

    /// 膠卷滾動條中的所有項目（依顯示日期由新到舊排列，並確保包含初始 `item`）
    private var filmstripItems: [ChekiItem] {
        let sorted = allChekiItems.sorted { $0.displayDate > $1.displayDate }
        if sorted.contains(where: { $0.id == item.id }) {
            return sorted
        }
        return [item] + sorted
    }

    /// 目前選中的索引位置
    private var currentIndex: Int {
        let items = filmstripItems
        if let id = currentItemID,
           let idx = items.firstIndex(where: { $0.id == id }) {
            return idx
        }
        return items.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    /// 目前選中的 `ChekiItem`
    private var currentItem: ChekiItem {
        let items = filmstripItems
        let idx = currentIndex
        if items.indices.contains(idx) {
            return items[idx]
        }
        return item
    }

    /// 是否已加入「最愛」（以備忘錄中含有 `#最愛` 或 `#お気に入り` 判定）
    private var isFavorite: Bool {
        guard let tags = currentItem.memo?.hashtags else { return false }
        return tags.contains { $0 == "#最愛" || $0 == "最愛" || $0 == "#お気に入り" }
    }

    var body: some View {
        ZStack {
            // 1. 全黑沉浸式背景（符合 Apple Photos 單張檢視暗色模式）
            Color.black
                .ignoresSafeArea()

            // 2. 主拍立得卡片檢視區（直接套用 .ignoresSafeArea() 於 GeometryReader，確保全顯示時 100% 填滿全畫面）
            GeometryReader { fullScreenGeo in
                let isLandscape = fullScreenGeo.size.width > fullScreenGeo.size.height
                mainCardViewport(
                    fullScreenSize: fullScreenGeo.size,
                    isLandscape: isLandscape
                )
            }
            .ignoresSafeArea()

            // 3. 頂部與底部懸浮控制介面（點擊畫面可隱藏進入全螢幕沉浸模式）
            if !isChromeHidden {
                GeometryReader { overlayGeo in
                    let isLandscape = overlayGeo.size.width > overlayGeo.size.height
                    VStack(spacing: 0) {
                        topOverlayNavigationBar(isLandscape: isLandscape)
                            .transition(.move(edge: .top).combined(with: .opacity))

                        Spacer(minLength: 0)

                        if !hasSeenDetailCoachMark && !isLandscape {
                            detailCoachMarkBanner
                                .padding(.bottom, 6)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }

                        bottomControlsStack(isLandscape: isLandscape, containerWidth: overlayGeo.size.width)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .frame(width: overlayGeo.size.width, height: overlayGeo.size.height)
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
        .statusBarHidden(isChromeHidden)
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
        .sheet(isPresented: $showingInfoSheet) {
            NavigationStack {
                ChekiInfoView(item: currentItem)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: currentItem.id) {
            await ensureCoverDateAndFormatNormalized(for: currentItem)
        }
        .fullScreenCover(isPresented: $showingAdjustmentSheet) {
            ChekiQuadCropEditorView(
                item: currentItem,
                initialEditingBackside: isShowingBack && currentItem.hasBothSides,
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
        .confirmationDialog(
            "確定要刪除此張拍立得嗎？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("刪除拍立得", role: .destructive) {
                deleteCurrentItem()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此拍立得（含背面與特典會備忘）將從典藏庫永久移除。")
        }
    }

    // MARK: - 1. 頂部懸浮導覽列與「日期時間藥丸」 (Apple iOS 18 Photos Header)

    private func topOverlayNavigationBar(isLandscape: Bool) -> some View {
        let buttonSize: CGFloat = isLandscape ? 30 : 36
        let iconSize: CGFloat = isLandscape ? 13 : 15.5

        return HStack(alignment: .center, spacing: 10) {
            // 左側：圓形毛玻璃返回按鈕
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("返回相簿")

            Spacer()

            // 中央：半透明日期時間藥丸 (如：9月17日 / 16:26 · 河田陽菜)
            Button {
                showingInfoSheet = true
            } label: {
                VStack(spacing: isLandscape ? 0 : 1) {
                    Text(Self.datePillPrimaryString(from: currentItem.displayDate))
                        .font(.system(size: isLandscape ? 11.5 : 13, weight: .bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 4) {
                        Text(Self.datePillTimeString(from: currentItem.displayDate))
                        if let memberName = currentItem.idolMember?.stageName {
                            Text("·")
                            Image(systemName: "person.fill")
                                .font(.system(size: 8))
                            Text(memberName)
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
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("檢視拍攝日期與時間資訊")

            Spacer()

            // 右側：圓形毛玻璃更多選單 (`⋯`)
            Menu {
                Button {
                    trigger3DFlip()
                } label: {
                    Label(
                        isShowingBack ? "翻回正面相片" : "3D 翻轉查看背面",
                        systemImage: "rectangle.portrait.rotate"
                    )
                }

                Divider()

                Menu {
                    Button {
                        isShowingBacksidePicker = true
                    } label: {
                        Label(
                            currentItem.hasBothSides ? "替換背面照片" : "從相簿補上背面照片",
                            systemImage: "photo.badge.plus"
                        )
                    }

                    Button {
                        generateSampleBacksideForCurrentItem()
                    } label: {
                        Label("產生測試手寫簽名背面", systemImage: "scribble.variable")
                    }

                    if currentItem.hasBothSides {
                        Button {
                            swapCurrentItemSides()
                        } label: {
                            Label("對調正反面照片", systemImage: "arrow.left.arrow.right")
                        }

                        Button(role: .destructive) {
                            currentItem.backImageData = nil
                            isShowingBack = false
                            withAnimation(flipAnimation) {
                                flipProgress = 0.0
                            }
                            try? modelContext.save()
                        } label: {
                            Label("移除背面照片", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("正反雙面管理", systemImage: "rectangle.portrait.on.rectangle.portrait")
                }

                Menu {
                    Button {
                        currentItem.idolMember = nil
                        try? modelContext.save()
                    } label: {
                        Label("未分類", systemImage: currentItem.idolMember == nil ? "checkmark" : "tray")
                    }

                    Divider()

                    ForEach(idolMembers) { member in
                        Button {
                            currentItem.idolMember = member
                            try? modelContext.save()
                        } label: {
                            let title = member.group != nil
                                ? "\(member.stageName)（\(member.group!.name)）"
                                : member.stageName
                            Label(title, systemImage: currentItem.idolMember?.id == member.id ? "checkmark" : "person")
                        }
                    }
                } label: {
                    Label("指派推角成員", systemImage: "person.crop.circle")
                }

                Button {
                    Task { await syncCurrentItemToSystemPhotos() }
                } label: {
                    Label("寫入系統相簿（含 OCR 時間軸）", systemImage: "photo.on.rectangle.angled")
                }

                Divider()

                Button {
                    showingAdjustmentSheet = true
                } label: {
                    Label("調整邊界與相紙比例", systemImage: "slider.horizontal.3")
                }

                Button {
                    if PhotoLibraryManager.isProLifetimeUnlocked {
                        isShowingModeBSecondAnglePicker = true
                    } else {
                        showToast("Mode B 雙角度去反光合成為 Pro 買斷版專屬功能")
                    }
                } label: {
                    Label(
                        PhotoLibraryManager.isProLifetimeUnlocked
                            ? "Mode B 雙角度去反光合成"
                            : "Mode B 雙角度去反光合成 (Pro)",
                        systemImage: "sparkles.rectangle.stack"
                    )
                }

                if currentItem.canRevertToOriginal(backside: isShowingBack && currentItem.hasBothSides) {
                    Button {
                        Task {
                            await revertCurrentItemToOriginal(backside: isShowingBack && currentItem.hasBothSides)
                        }
                    } label: {
                        Label("復原為原始圖片（取消裁切）", systemImage: "arrow.uturn.backward.circle")
                    }
                }

                Button {
                    showingInfoSheet = true
                } label: {
                    Label("資訊與特典會備忘", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("更多操作選單")
        }
        .padding(.horizontal, 16)
        .padding(.top, isLandscape ? 4 : 8)
        .padding(.bottom, isLandscape ? 2 : 8)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 2. 中央拍立得水平滑動分頁與 3D Y 軸翻轉動畫 (Interactive Horizontal Pager + 3D Flip)

    private func mainCardViewport(fullScreenSize: CGSize, isLandscape: Bool) -> some View {
        // 計算卡片實際可用尺寸：
        // - 全螢幕隱藏工具列 (isChromeHidden == true) 時：0 邊距，100% 填滿全螢幕高度與寬度
        // - 顯示工具列時：橫向緊湊預留上下工具列空間，確保拍立得依然保持最大化尺寸
        let topInset: CGFloat = isChromeHidden ? 0 : (isLandscape ? 42 : 98)
        let bottomInset: CGFloat = isChromeHidden ? 0 : (isLandscape ? 58 : 138)
        let horizontalInset: CGFloat = isChromeHidden ? 0 : (isLandscape ? 20 : 18)

        let availableSize = CGSize(
            width: max(120, fullScreenSize.width - horizontalInset * 2),
            height: max(120, fullScreenSize.height - topInset - bottomInset)
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
                        availableSize: availableSize,
                        isLandscape: isLandscape
                    )
                    .frame(width: fullScreenSize.width, height: availableSize.height)
                    .offset(x: CGFloat(index - activeIndex) * pageStride + horizontalDragOffset)
                }
            }
        }
        .frame(width: fullScreenSize.width, height: fullScreenSize.height)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(width: fullScreenSize.width, height: fullScreenSize.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(cardMagnifyGesture)
        .simultaneousGesture(cardDragAndSwipeGesture(pageStride: pageStride))
    }

    /// 單張卡片頁面：透過 `Cheki3DFlipContainer` (Animatable) 驅動 0° ↔ 180° 連續 3D 翻轉、Z 軸浮起與慢進慢出減速強調
    @ViewBuilder
    private func singleCardPageView(
        for pageItem: ChekiItem,
        isCurrent: Bool,
        availableSize: CGSize,
        isLandscape: Bool
    ) -> some View {
        let effectiveFlipProgress = isCurrent ? flipProgress : 0.0
        let effectiveScale = isCurrent ? (zoomScale * activePinchScale) : 1.0

        Cheki3DFlipContainer(
            flipProgress: effectiveFlipProgress,
            front: {
                frontCardFace(
                    for: pageItem,
                    isCurrent: isCurrent,
                    availableSize: availableSize,
                    isLandscape: isLandscape
                )
            },
            back: {
                backCardFace(
                    for: pageItem,
                    isCurrent: isCurrent,
                    availableSize: availableSize,
                    isLandscape: isLandscape
                )
            }
        )
        .scaleEffect(effectiveScale)
    }

    /// 卡片右上角翻轉按鈕（正面與背面皆固定於各自畫面的右上角 `topTrailing`）
    @ViewBuilder
    private func cardTopRightFlipButton(
        for pageItem: ChekiItem,
        isCurrent: Bool,
        isBackFace: Bool,
        isLandscape: Bool
    ) -> some View {
        // 正面於顯示工具列時呈現；背面則固定顯示於右上角（即使全螢幕模式也能直接從右上角翻回正面）
        if isCurrent && (!isChromeHidden || isBackFace) {
            Button {
                trigger3DFlip()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "rectangle.portrait.rotate")
                        .font(.system(size: isLandscape ? 9 : 10.5, weight: .semibold))
                    Text(isBackFace ? "背面 · 翻面" : (pageItem.hasBothSides ? "正面 · 翻面" : "單面 · 補背面"))
                        .font(.system(size: isLandscape ? 9 : 10.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, isLandscape ? 7 : 9)
                .padding(.vertical, isLandscape ? 3 : 4.5)
                .background(.black.opacity(0.62), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .padding(isLandscape ? 6 : 8)
        }
    }

    /// 卡片本體的單擊（沉浸模式切換）與雙擊（3D 翻轉 / 重置縮放）手勢，綁定在底圖上以避免干擾右上角翻轉按鈕
    private func applyCardTapGestures<V: View>(to view: V) -> some View {
        view
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if zoomScale > 1.05 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        zoomScale = 1.0
                    }
                } else {
                    trigger3DFlip()
                }
            }
            .onTapGesture(count: 1) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isChromeHidden.toggle()
                }
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
        isLandscape: Bool
    ) -> some View {
        let insetScale = CGFloat(1.0 - targetItem.borderInsetRatio * 1.4)
        if let data = targetItem.frontImageData,
           let uiImage = UIImage(data: data) {
            let cardSize = fittedCardSize(for: uiImage.size, in: availableSize)
            applyCardTapGestures(
                to: Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(insetScale)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .overlay {
                        ChekiWatermarkOverlayView(compact: false)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: isChromeHidden ? 6 : 10, style: .continuous))
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
                    title: "尚無正面影像",
                    subtitle: "此拍立得尚未儲存正面照片",
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
           let uiImage = UIImage(data: backData) {
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
                    .clipShape(RoundedRectangle(cornerRadius: isChromeHidden ? 6 : 10, style: .continuous))
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
            // 若此張拍立得尚無背面，提供原生引導卡直接補上背面或產生測試手寫背面
            VStack(spacing: 14) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))

                VStack(spacing: 5) {
                    Text("尚未綁定背面手寫照片")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("可從系統相簿選取背面照片，或一鍵產生測試手寫簽名背面。")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                VStack(spacing: 8) {
                    Button {
                        isShowingBacksidePicker = true
                    } label: {
                        Label("從相簿選取背面照片", systemImage: "photo.badge.plus")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        generateSampleBacksideForCurrentItem()
                    } label: {
                        Label("產生測試手寫簽名背面", systemImage: "scribble.variable")
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
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(
            width: min(availableSize.width, min(availableSize.height * 0.65, 280)),
            height: min(availableSize.height, 420)
        )
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 3. 初次檢視亮點提示 (Spotlight Coach Mark)

    private var detailCoachMarkBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw.fill")
                .font(.caption)
                .foregroundStyle(.yellow)

            Text("雙擊卡片可 **3D 翻轉背面** · 向上滑動可記錄 **特典會備忘**")
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
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 4. 底部縮圖膠卷 (Filmstrip Scrubber) + 5 大標準工具列按鈕

    private func bottomControlsStack(isLandscape: Bool, containerWidth: CGFloat) -> some View {
        VStack(spacing: isLandscape ? 4 : 18) {
            // 底部縮圖膠卷 (Filmstrip Scrubber)
            filmstripScrubberBar(isLandscape: isLandscape, containerWidth: containerWidth)

            // Apple Photos 標準 5 大工具列按鈕（左圓分享、中三合一膠囊、右圓刪除）
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
        let outerPillSpacing: CGFloat = isLandscape ? 18 : 28

        return HStack(alignment: .center, spacing: outerPillSpacing) {
            // 左側獨立圓形膠囊：1. 分享 (Share)
            Button {
                shareCurrentItem()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: iconFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: pillHeight, height: pillHeight)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享拍立得")

            // 中央三合一膠囊：2. 愛心 (Favorite) + 3. 資訊 (Info) + 4. 調整 (Adjust)
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
                .accessibilityLabel(isFavorite ? "取消最愛" : "加入最愛")

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
                .accessibilityLabel("檢視資訊與特典會備忘")

                // 4. 調整 (Adjust Border Inset & Format)
                Button {
                    showingAdjustmentSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: iconFontSize, weight: .medium))
                        .foregroundStyle(abs(currentItem.borderInsetRatio) > 0.001 ? .yellow : .white)
                        .frame(width: centerButtonWidth, height: pillHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("調整拍立得邊界與比例")
            }
            .padding(.horizontal, isLandscape ? 4 : 4)
            .frame(height: pillHeight)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)

            // 右側獨立圓形膠囊：5. 垃圾桶 (Delete)
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: iconFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: pillHeight, height: pillHeight)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刪除拍立得")
        }
    }

    // MARK: - 5. 手勢與互動動作 (Gestures & Actions)

    private var cardMagnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                activePinchScale = max(0.8, min(3.0, value.magnification))
            }
            .onEnded { value in
                let finalScale = max(1.0, min(3.0, zoomScale * value.magnification))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    zoomScale = finalScale
                    activePinchScale = 1.0
                }
            }
    }

    private func cardDragAndSwipeGesture(pageStride: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard zoomScale <= 1.05 else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                if dragAxisLock == nil {
                    if abs(dx) > 8 || abs(dy) > 8 {
                        dragAxisLock = abs(dx) >= abs(dy) ? .horizontal : .vertical
                    }
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
                guard zoomScale <= 1.05 else {
                    horizontalDragOffset = 0
                    return
                }

                let dx = value.translation.width
                let dy = value.translation.height
                let predictedDx = value.predictedEndTranslation.width
                let activeAxis = dragAxisLock ?? (abs(dx) >= abs(dy) ? .horizontal : .vertical)

                if activeAxis == .vertical {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        horizontalDragOffset = 0
                    }
                    // 向上滑動 -> 呼出資訊與備忘面板 (Task 4.6)
                    if dy < -50 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        hasSeenDetailCoachMark = true
                        showingInfoSheet = true
                    } else if dy > 80 {
                        // 向下滑動 -> 返回相簿
                        dismiss()
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
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                            horizontalDragOffset = 0
                        }
                    }
                }
            }
    }

    /// 3D 翻轉曲線：慢進慢出（減速強調 / 減速を強調する），速度較先前放慢約 0.7 倍（時長 0.84 秒）
    private var flipAnimation: Animation {
        .timingCurve(0.24, 0.06, 0.12, 1.0, duration: 0.84)
    }

    private func trigger3DFlip() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        hasSeenDetailCoachMark = true
        let nextBack = !isShowingBack
        isShowingBack = nextBack
        withAnimation(flipAnimation) {
            flipProgress = nextBack ? 1.0 : 0.0
        }
    }

    private func selectFilmstripItem(_ targetItem: ChekiItem) {
        guard targetItem.id != currentItem.id else {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                horizontalDragOffset = 0
            }
            return
        }
        previousItemID = currentItem.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            currentItemID = targetItem.id
            horizontalDragOffset = 0
            isShowingBack = false
            flipProgress = 0.0
            zoomScale = 1.0
        }
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
        showToast(backside ? "已復原背面為原始未裁切圖片" : "已復原為原始未裁切圖片")
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
    }

    /// Task 5.4 & 6.1: 從相簿選取第 2 張不同傾斜角度的照片，與當前照片進行極速 Mode B 雙角度去反光合成
    @MainActor
    private func synthesizeModeBSecondAnglePhoto(from pickerItem: PhotosPickerItem) async {
        guard PhotoLibraryManager.isProLifetimeUnlocked else {
            showToast("Mode B 雙角度去反光合成為 Pro 專屬功能")
            return
        }
        guard let secondData = try? await pickerItem.loadTransferable(type: Data.self) else {
            showToast("無法讀取第二角度照片")
            return
        }

        let editingBack = isShowingBack && currentItem.hasBothSides
        let primarySourceData = editingBack
            ? (currentItem.originalBackImageData ?? currentItem.backImageData)
            : (currentItem.originalFrontImageData ?? currentItem.frontImageData)

        guard let primaryData = primarySourceData else {
            showToast("無法讀取主角度照片")
            return
        }

        let insetRatio = currentItem.borderInsetRatio
        let preferredFmt = currentItem.filmFormat
        showToast("正在合成雙角度去反光⋯")

        let fusedJPEG: Data? = await Task.detached(priority: .userInitiated) {
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
            ) else {
                return nil
            }
            return UIImage(cgImage: result.fusedCGImage).jpegData(compressionQuality: 0.92)
        }.value

        if let fusedJPEG {
            if editingBack {
                if currentItem.originalBackImageData == nil {
                    currentItem.originalBackImageData = currentItem.backImageData
                }
                currentItem.backImageData = fusedJPEG
            } else {
                if currentItem.originalFrontImageData == nil {
                    currentItem.originalFrontImageData = currentItem.frontImageData
                }
                currentItem.frontImageData = fusedJPEG
            }
            try? modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("✨ 已完成 Mode B 雙角度去反光合成")
            await syncCurrentItemToSystemPhotos()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showToast("雙角度對位失敗，請確認兩張皆包含完整拍立得邊框")
        }
    }

    private func generateSampleBacksideForCurrentItem() {
        let memberName = currentItem.idolMember?.stageName ?? "推しメン"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy.MM.dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateString = dateFormatter.string(from: currentItem.displayDate)

        if let sampleBack = PreviewData.makePolaroidImageData(
            width: 360,
            height: 572,
            topRGB: (99, 102, 241),
            bottomRGB: (236, 72, 153),
            isBackside: true,
            signatureText: "\(memberName) 直筆サイン ♡",
            dateText: dateString,
            backMessage: "いつも応援ありがとう！♡\n今日もたくさん話せて嬉しかったよ☆\nまた次のイベントで会おうね！"
        ) {
            currentItem.backImageData = sampleBack
            currentItem.originalBackImageData = sampleBack
            currentItem.backPerspectivePointsJSON = nil
            try? modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            isShowingBack = true
            withAnimation(flipAnimation) {
                flipProgress = 1.0
            }
        }
    }

    @MainActor
    private func syncCurrentItemToSystemPhotos() async {
        guard let frontData = currentItem.frontImageData,
              let frontImage = UIImage(data: frontData) else { return }

        let syncDate = currentItem.displayDate
        let albumName = currentItem.idolMember?.stageName ?? "ChekiLens"
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
                showToast("已原地更新系統相簿裁切圖（\(albumName)）")
            } else {
                showToast("已同步至系統相簿（免費版保留未裁切原圖）")
            }
        } catch {
            showToast("相簿同步需要開啟照片存取權限")
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
            showToast("今日免費高畫質額度已滿（1/1），目前為 SNS 畫質＋浮水印")
        }

        let activityVC = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else { return }
            Task { @MainActor in
                if canUseDailyFreeQuota {
                    StoreKitManager.shared.consumeDailyFreeQuotaIfAvailable()
                    showToast("已使用今日免費高畫質無浮水印輸出（1/1）")
                }
            }
        }

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = scene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func deleteCurrentItem() {
        let items = filmstripItems
        let targetToDelete = currentItem

        var nextID: UUID? = nil
        if let idx = items.firstIndex(where: { $0.id == targetToDelete.id }) {
            if idx + 1 < items.count {
                nextID = items[idx + 1].id
            } else if idx - 1 >= 0 {
                nextID = items[idx - 1].id
            }
        }

        modelContext.delete(targetToDelete)
        try? modelContext.save()

        if let nextID {
            withAnimation(.snappy(duration: 0.25)) {
                currentItemID = nextID
                isShowingBack = false
            }
        } else {
            dismiss()
        }
    }

    // MARK: - 6. 日期藥丸格式化與背景封面手寫日期補齊

    @MainActor
    private func ensureCoverDateAndFormatNormalized(for target: ChekiItem) async {
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
        guard target.ocrDate == nil else { return }
        guard let data = target.frontImageData ?? target.originalFrontImageData,
              let uiImage = UIImage(data: data)?.normalizedImage,
              let cgImage = uiImage.cgImage else { return }

        let visionManager = VisionManager()
        if let ocrResult = await visionManager.recognizeDate(from: cgImage) {
            let mergedDate = ChekiItem.mergeRecognizedDate(ocrResult.date, into: target.capturedAt)
            target.ocrDate = mergedDate
            target.capturedAt = mergedDate
            try? modelContext.save()
        } else if let origData = target.originalFrontImageData,
                  origData != data,
                  let origUI = UIImage(data: origData)?.normalizedImage,
                  let origCG = origUI.cgImage,
                  let fallbackResult = await visionManager.recognizeDate(from: origCG) {
            let mergedDate = ChekiItem.mergeRecognizedDate(fallbackResult.date, into: target.capturedAt)
            target.ocrDate = mergedDate
            target.capturedAt = mergedDate
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
        max(1.0, min(4.5, zoomScale * activePinchScale))
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
                        Text("正在套用四頂點透視裁切...")
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
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("取消裁切")

            Spacer()

            // 中央：若有正反雙面可切換
            if item.hasBothSides {
                HStack(spacing: 2) {
                    Button {
                        editingBackside = false
                    } label: {
                        Text("正面")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(!editingBackside ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(!editingBackside ? Color.yellow : Color.clear, in: Capsule())
                    }
                    Button {
                        editingBackside = true
                    } label: {
                        Text("背面")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(editingBackside ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(editingBackside ? Color.yellow : Color.clear, in: Capsule())
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.14), in: Capsule())

                Spacer()
            }

            // 縮放倍率重置標籤（當雙指放大時顯示）
            if effectiveZoom > 1.02 {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        resetZoomAndPan()
                    }
                } label: {
                    Text(String(format: "%.1fx", effectiveZoom))
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
            }

            // 右側：完成 (✓)
            Button {
                Task {
                    await applyManualQuadCropAndSave()
                }
            } label: {
                Text("完成")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.yellow, in: Capsule())
            }
            .disabled(isProcessingCrop)
            .accessibilityLabel("完成裁切")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - 2. 中央互動畫布（透明灰色切除遮罩 + 四頂點拖曳 + 雙指縮放 + 放大鏡）

    private var cropCanvasArea: some View {
        GeometryReader { geo in
            let viewportSize = geo.size
            if let uiImage = sourceUIImage {
                let baseRect = Self.aspectFitRect(imageSize: uiImage.size, in: viewportSize, padding: 26)
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
                    // 底層：原始圖片（支援雙指縮放與平移）
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: transformedRect.width, height: transformedRect.height)
                        .position(x: transformedRect.midX, y: transformedRect.midY)

                    // 切除的部分用透明灰色 (Even-Odd Fill：圖片外框減去四頂點多邊形內部)
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
                    .allowsHitTesting(false)

                    // 雙指縮放與單指空白處拖曳平移手勢層
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(canvasPanAndPinchGesture(baseRect: baseRect, viewportSize: viewportSize))
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                if effectiveZoom > 1.05 {
                                    resetZoomAndPan()
                                } else {
                                    zoomScale = 2.2
                                }
                            }
                        }

                    // 四邊形白色邊框 + 3x3 透視九宮格輔助線
                    if screenCorners.count == 4 {
                        quadGridAndBorderOverlay(screenCorners: screenCorners)
                            .allowsHitTesting(false)
                    }

                    // 四個可獨立移動的頂點控制柄 (TL, TR, BR, BL)
                    ForEach(0..<min(4, screenCorners.count), id: \.self) { index in
                        vertexHandle(
                            index: index,
                            screenPoint: screenCorners[index],
                            transformedRect: transformedRect
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
                                    .foregroundStyle(.yellow)
                                Text("拖曳四個頂點調整裁切範圍・雙指可縮放畫面")
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
                ContentUnavailableView("無法載入拍立得影像", systemImage: "photo.badge.exclamationmark")
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

    // MARK: - 單一頂點控制柄 (Apple Photos L 型角標 + 圓形精準錨點)

    private func vertexHandle(
        index: Int,
        screenPoint: CGPoint,
        transformedRect: CGRect
    ) -> some View {
        let isDragging = (activeDraggingCornerIndex == index)

        return ZStack {
            // 外圈觸控光暈
            Circle()
                .fill(isDragging ? Color.yellow.opacity(0.28) : Color.black.opacity(0.28))
                .frame(width: isDragging ? 42 : 30, height: isDragging ? 42 : 30)

            // 白色/黃色粗框圓環 + 中心準星
            Circle()
                .strokeBorder(isDragging ? Color.yellow : Color.white, lineWidth: 3.0)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.55), radius: 3, y: 1)

            Circle()
                .fill(isDragging ? Color.yellow : Color.white)
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
                    let nx = (value.location.x - transformedRect.minX) / transformedRect.width
                    let ny = (value.location.y - transformedRect.minY) / transformedRect.height
                    let clamped = CGPoint(
                        x: min(max(nx, 0.01), 0.99),
                        y: min(max(ny, 0.01), 0.99)
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
                    .frame(width: displayedW, height: displayedH)
                    .offset(x: offsetX, y: offsetY)
                    .frame(width: loupeDiameter, height: loupeDiameter)
                    .background(Color.black)
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
                            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

                            // 中心精準定位小圓環
                            Circle()
                                .strokeBorder(Color.black.opacity(0.75), lineWidth: 2.2)
                                .frame(width: 7, height: 7)

                            Circle()
                                .strokeBorder(Color.yellow, lineWidth: 1.2)
                                .frame(width: 7, height: 7)
                        }
                        .frame(width: loupeDiameter, height: loupeDiameter)
                        .clipShape(Circle())
                    }
                    .overlay(
                        Circle()
                            .strokeBorder(Color.yellow, lineWidth: 2.5)
                    )
                    .overlay(alignment: .bottom) {
                        Text(cornerNames[cornerIndex])
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.yellow, in: Capsule())
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
                            .foregroundStyle(isSelected ? .black : .white.opacity(0.85))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.yellow : Color.white.opacity(0.12),
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
                        Text("自動吸附")
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
                        Text("旋轉 90°")
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
                        Text("展開四點")
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
                        Text(abs(defaultBorderInsetPercentage) > 0.05 ? String(format: "邊界 %+.1f%%", defaultBorderInsetPercentage) : "邊界設定")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(abs(defaultBorderInsetPercentage) > 0.05 ? .yellow : .white)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    onRequestBacksidePicker()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                        Text(item.hasBothSides ? "換背面圖" : "補背面圖")
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
                zoomScale = max(1.0, min(4.5, zoomScale * value.magnification))
                activePinchScale = 1.0
                if zoomScale <= 1.02 {
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
                guard effectiveZoom > 1.01 else { return }
                activePanDelta = value.translation
            }
            .onEnded { value in
                guard effectiveZoom > 1.01 else {
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

        if let detection = try? await visionManager.detectQuad(in: cgImage, imageSize: imgSize),
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
                        x: min(max(pt.x / max(1, imgSize.width), 0.01), 0.99),
                        y: min(max(pt.y / max(1, imgSize.height), 0.01), 0.99)
                    )
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if abs(defaultBorderInsetPercentage) > 0.05 {
                showBanner(String(format: "已自動吸附頂點（套用邊界微調 %+.1f%%）", defaultBorderInsetPercentage))
            } else {
                showBanner("已自動吸附拍立得四個頂點")
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
                        x: min(max(pt.x / max(1, imgSize.width), 0.01), 0.99),
                        y: min(max(pt.y / max(1, imgSize.height), 0.01), 0.99)
                    )
                }
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showBanner("已重設為標準拍立得四頂點範圍")
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
        onAppliedToast(editingBackside ? "已復原背面為原始未裁切圖片" : "已復原為原始未裁切圖片")
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
                       let ocrRes = await visionManager.recognizeDate(from: cropResult.cgImage) {
                        let mergedDate = ChekiItem.mergeRecognizedDate(ocrRes.date, into: item.capturedAt)
                        item.ocrDate = mergedDate
                        item.capturedAt = mergedDate
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
                    let albumName = item.idolMember?.stageName ?? "ChekiLens"
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
                if PhotoLibraryManager.isProLifetimeUnlocked {
                    onAppliedToast("已原地修改裁切並保留原始圖片")
                } else {
                    onAppliedToast("已更新 App 內裁切預覽（免費版原生相簿保留原圖）")
                }
                dismiss()
            }
        } else {
            showBanner("裁切範圍無效，請確認四個頂點未交錯")
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


// MARK: - 3D 拍立得正反翻轉與 Z 軸浮起容器 (Animatable 3D Flip + Z-Axis Lift)

/// 透過 `Animatable` 連續插值 `flipProgress (0.0 ... 1.0)`：
/// 1. 保持正反兩面同時駐留於 `ZStack`，於 `90°` 垂直切面瞬間無縫切換正反面可見度，根除視圖重建造成的無動畫問題。
/// 2. 結合 `sin(flipProgress * .pi)` 在翻轉中段將拍立得沿 Z 軸向觀察者微微浮起 (`scale` 放大) 並向上微移 (`offset.y` 上提)，落定時平滑復原。
private struct Cheki3DFlipContainer<Front: View, Back: View>: View, Animatable {
    var flipProgress: Double
    let front: () -> Front
    let back: () -> Back

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
            front()
                .opacity(isBackVisible ? 0.0 : 1.0)
                .allowsHitTesting(!isBackVisible)

            back()
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

// MARK: - Preview

#Preview("05. 單張全螢幕檢視 (Apple Photos Detail)") {
    let container = try! ModelContainerProvider.preview(withSampleData: true)
    let firstItem = (try? container.mainContext.fetch(FetchDescriptor<ChekiItem>()).first) ?? ChekiItem()
    return NavigationStack {
        ChekiDetailView(item: firstItem)
    }
    .modelContainer(container)
}
