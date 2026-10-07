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
    /// 是否翻轉至背面（true = 顯示背面手寫簽名，false = 顯示正面照片）
    @State private var isShowingBack: Bool = false
    /// 點擊單下隱藏/顯示上下工具列（沉浸式全螢幕檢視）
    @State private var isChromeHidden: Bool = false

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

    /// 目前選中的 `ChekiItem`
    private var currentItem: ChekiItem {
        if let id = currentItemID,
           let matched = filmstripItems.first(where: { $0.id == id }) {
            return matched
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
            // 全黑沉浸式背景（符合 Apple Photos 單張檢視暗色模式）
            Color.black
                .ignoresSafeArea()

            // 主拍立得卡片檢視區（支援 3D Y 軸翻轉、雙指縮放、上滑呼出 Info、左右滑動切換）
            mainCardViewport

            // 頂部與底部懸浮控制介面（點擊畫面可隱藏進入全螢幕沉浸模式）
            if !isChromeHidden {
                VStack(spacing: 0) {
                    topOverlayNavigationBar
                        .transition(.move(edge: .top).combined(with: .opacity))

                    Spacer()

                    if !hasSeenDetailCoachMark {
                        detailCoachMarkBanner
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }

                    bottomControlsStack
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                        .padding(.bottom, 145)
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
            matching: .images
        )
        .onChange(of: backsidePickerItem) { _, newPickerItem in
            guard let newPickerItem else { return }
            backsidePickerItem = nil
            Task { await attachBacksidePhoto(from: newPickerItem) }
        }
        .sheet(isPresented: $showingInfoSheet) {
            NavigationStack {
                ChekiInfoView(item: currentItem)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") {
                                showingInfoSheet = false
                            }
                            .fontWeight(.semibold)
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAdjustmentSheet) {
            ChekiAdjustmentSheet(
                item: currentItem,
                onRequestBacksidePicker: {
                    showingAdjustmentSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isShowingBacksidePicker = true
                    }
                }
            )
            .presentationDetents([.fraction(0.48), .medium])
            .presentationDragIndicator(.visible)
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

    private var topOverlayNavigationBar: some View {
        HStack(alignment: .center, spacing: 12) {
            // 左側：圓形毛玻璃返回按鈕
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("返回相簿")

            Spacer()

            // 中央：半透明日期時間藥丸 (如：9月17日 / 16:26 · 河田陽菜)
            Button {
                showingInfoSheet = true
            } label: {
                VStack(spacing: 1) {
                    Text(Self.datePillPrimaryString(from: currentItem.displayDate))
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 4) {
                        Text(Self.datePillTimeString(from: currentItem.displayDate))
                        if let memberName = currentItem.idolMember?.stageName {
                            Text("·")
                            Image(systemName: "person.fill")
                                .font(.system(size: 9))
                            Text(memberName)
                                .lineLimit(1)
                        } else if currentItem.ocrDate != nil {
                            Text("· OCR")
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
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
                    showingInfoSheet = true
                } label: {
                    Label("資訊與特典會備忘", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("更多操作選單")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 2. 中央拍立得檢視與 3D Y 軸翻轉動畫 (3D Y-Axis Flip Viewport)

    private var mainCardViewport: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isChromeHidden.toggle()
                        }
                    }

                VStack(spacing: 14) {
                    // 3D 翻轉容器
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if !isShowingBack {
                                frontCardFace(maxSize: geo.size)
                            } else {
                                backCardFace(maxSize: geo.size)
                                    // 背面翻轉 180 度後需鏡像回正，確保手寫文字與圖片方向正確不顛倒
                                    .rotation3DEffect(
                                        .degrees(180),
                                        axis: (x: 0, y: 1, z: 0)
                                    )
                            }
                        }
                        .rotation3DEffect(
                            .degrees(isShowingBack ? 180 : 0),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.42
                        )

                        // 右上角浮動正反面 3D 翻轉徽章 (仿照 iOS 18 照片右上角 Live / 空間相片膠囊)
                        if !isChromeHidden {
                            Button {
                                trigger3DFlip()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "rectangle.portrait.rotate")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(isShowingBack ? "背面 · 手寫" : (currentItem.hasBothSides ? "正面 · 翻面" : "單面 · 補背面"))
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.62), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(12)
                        }
                    }
                    .scaleEffect(zoomScale * activePinchScale)
                    .shadow(color: .black.opacity(0.75), radius: 28, x: 0, y: 14)
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
                    .gesture(cardMagnifyGesture)
                    .gesture(cardDragAndSwipeGesture)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, isChromeHidden ? 16 : 64)
                .padding(.bottom, isChromeHidden ? 16 : 148)
            }
        }
    }

    @ViewBuilder
    private func frontCardFace(maxSize: CGSize) -> some View {
        let insetScale = CGFloat(1.0 - currentItem.borderInsetRatio * 1.4)
        if let data = currentItem.frontImageData,
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .scaleEffect(insetScale)
                .frame(
                    maxWidth: min(maxSize.width - 36, 360),
                    maxHeight: min(maxSize.height - 220, 560)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            placeholderCardFace(
                title: "尚無正面影像",
                subtitle: "此拍立得尚未儲存正面照片",
                maxSize: maxSize
            )
        }
    }

    @ViewBuilder
    private func backCardFace(maxSize: CGSize) -> some View {
        if let backData = currentItem.backImageData,
           let uiImage = UIImage(data: backData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(
                    maxWidth: min(maxSize.width - 36, 360),
                    maxHeight: min(maxSize.height - 220, 560)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            // 若此張拍立得尚無背面，提供原生引導卡直接補上背面或產生測試手寫背面
            VStack(spacing: 16) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))

                VStack(spacing: 6) {
                    Text("尚未綁定背面手寫照片")
                        .font(.headline)
                        .foregroundStyle(.white)

                    Text("可從系統相簿選取此張拍立得的背面照片，或一鍵產生測試手寫簽名背面體驗 3D 翻轉。")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                VStack(spacing: 10) {
                    Button {
                        isShowingBacksidePicker = true
                    } label: {
                        Label("從相簿選取背面照片", systemImage: "photo.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        generateSampleBacksideForCurrentItem()
                    } label: {
                        Label("產生測試手寫簽名背面", systemImage: "scribble.variable")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.horizontal, 28)
            }
            .frame(
                width: min(maxSize.width - 48, 310),
                height: min(maxSize.height - 250, 470)
            )
            .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private func placeholderCardFace(title: String, subtitle: String, maxSize: CGSize) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(
            width: min(maxSize.width - 48, 300),
            height: min(maxSize.height - 250, 460)
        )
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var bottomControlsStack: some View {
        VStack(spacing: 10) {
            // 底部縮圖膠卷 (Filmstrip Scrubber)
            filmstripScrubberBar

            // Apple Photos 標準 5 大工具列按鈕（分享、愛心、ℹ️、調整、垃圾桶）
            standardFiveIconToolbar
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [
                    .black.opacity(0.0),
                    .black.opacity(0.75),
                    .black.opacity(0.94)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
        .environment(\.colorScheme, .dark)
    }

    private var filmstripScrubberBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 5) {
                    ForEach(filmstripItems) { stripItem in
                        let isCurrent = (stripItem.id == currentItem.id)
                        Button {
                            guard stripItem.id != currentItem.id else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.snappy(duration: 0.24)) {
                                currentItemID = stripItem.id
                                isShowingBack = false
                                zoomScale = 1.0
                            }
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                if let data = stripItem.frontImageData,
                                   let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(
                                            width: isCurrent ? 34 : 25,
                                            height: isCurrent ? 46 : 36
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: isCurrent ? 4 : 3, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color(white: 0.25))
                                        .frame(
                                            width: isCurrent ? 34 : 25,
                                            height: isCurrent ? 46 : 36
                                        )
                                }

                                if stripItem.hasBothSides && isCurrent {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 6, height: 6)
                                        .padding(2)
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: isCurrent ? 4 : 3, style: .continuous)
                                    .strokeBorder(.white, lineWidth: isCurrent ? 2.0 : 0.0)
                            )
                            .opacity(isCurrent ? 1.0 : 0.58)
                            .shadow(
                                color: isCurrent ? .white.opacity(0.28) : .clear,
                                radius: 6,
                                x: 0,
                                y: 0
                            )
                        }
                        .buttonStyle(.plain)
                        .id(stripItem.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .onAppear {
                proxy.scrollTo(currentItem.id, anchor: .center)
            }
            .onChange(of: currentItemID) { _, newID in
                guard let newID else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var standardFiveIconToolbar: some View {
        HStack(spacing: 0) {
            // 1. 分享 (Share)
            Button {
                shareCurrentItem()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("分享拍立得")

            // 2. 愛心 / 最愛 (Favorite)
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isFavorite ? .pink : .white)
                    .symbolEffect(.bounce, value: isFavorite)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel(isFavorite ? "取消最愛" : "加入最愛")

            // 3. ℹ️ 資訊與特典會備忘 (Info & Memo Sheet)
            Button {
                hasSeenDetailCoachMark = true
                showingInfoSheet = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: showingInfoSheet ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 20, weight: .medium))

                    if let note = currentItem.memo?.noteText, !note.isEmpty {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("檢視資訊與特典會備忘")

            // 4. 調整 (Adjust Border Inset & Format)
            Button {
                showingAdjustmentSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(abs(currentItem.borderInsetRatio) > 0.001 ? .yellow : .white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("調整拍立得邊界與比例")

            // 5. 垃圾桶 (Delete)
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("刪除拍立得")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
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

    private var cardDragAndSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                guard zoomScale <= 1.05 else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                if abs(dy) > abs(dx) {
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
                    // 左右滑動 -> 切換膠卷中的上一張 / 下一張拍立得
                    if dx < -50 {
                        navigateFilmstrip(offset: 1)
                    } else if dx > 50 {
                        navigateFilmstrip(offset: -1)
                    }
                }
            }
    }

    private func trigger3DFlip() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        hasSeenDetailCoachMark = true
        withAnimation(.spring(response: 0.52, dampingFraction: 0.78)) {
            isShowingBack.toggle()
        }
    }

    private func navigateFilmstrip(offset: Int) {
        let items = filmstripItems
        guard let currentIndex = items.firstIndex(where: { $0.id == currentItem.id }) else { return }
        let targetIndex = currentIndex + offset
        guard items.indices.contains(targetIndex) else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.25)) {
            currentItemID = items[targetIndex].id
            isShowingBack = false
            zoomScale = 1.0
        }
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
        currentItem.frontImageData = backData
        currentItem.backImageData = frontData
        try? modelContext.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    private func attachBacksidePhoto(from pickerItem: PhotosPickerItem) async {
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let rawImage = UIImage(data: data) else { return }

        let normalized = rawImage.normalizedImage
        var finalData = normalized.jpegData(compressionQuality: 0.92) ?? data

        if let cgImage = normalized.cgImage {
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let visionManager = VisionManager()
            if let detection = try? await visionManager.detectQuad(in: cgImage, imageSize: size),
               let cropResult = try? await visionManager.perspectiveCorrect(
                   image: cgImage,
                   corners: detection.corners,
                   detection: detection,
                   format: .auto
               ),
               let croppedJPEG = UIImage(cgImage: cropResult.cgImage).jpegData(compressionQuality: 0.92) {
                finalData = croppedJPEG
            }
        }

        currentItem.backImageData = finalData
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.52, dampingFraction: 0.78)) {
            isShowingBack = true
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
            try? modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.52, dampingFraction: 0.78)) {
                isShowingBack = true
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
            _ = try await PhotoLibraryManager.shared.saveImage(
                frontImage,
                creationDate: syncDate,
                to: album
            )
            if let backData = currentItem.backImageData,
               let backImage = UIImage(data: backData) {
                _ = try await PhotoLibraryManager.shared.saveImage(
                    backImage,
                    creationDate: syncDate,
                    to: album
                )
            }
            currentItem.isSyncedToPhotoLibrary = true
            currentItem.isDateWrittenToAlbum = (currentItem.ocrDate != nil)
            try? modelContext.save()
            showToast("已同秒寫入系統相簿（\(albumName)）")
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
        var shareItems: [Any] = []
        if let frontData = currentItem.frontImageData,
           let frontUI = UIImage(data: frontData) {
            shareItems.append(frontUI)
        }
        if let backData = currentItem.backImageData,
           let backUI = UIImage(data: backData) {
            shareItems.append(backUI)
        }
        guard !shareItems.isEmpty else { return }

        let activityVC = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
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

    // MARK: - 6. 日期藥丸格式化工具 (Apple Photos Pill Formatter)

    static func datePillPrimaryString(from date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "M月d日"
        } else {
            formatter.dateFormat = "yyyy年M月d日"
        }
        return formatter.string(from: date)
    }

    static func datePillTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - ChekiAdjustmentSheet (第 4 顆工具列按鈕「調整」：邊界偏移微調與相紙比例鎖定面板)

private struct ChekiAdjustmentSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let item: ChekiItem
    let onRequestBacksidePicker: () -> Void

    @State private var borderInsetPercentage: Double = 0.0
    @State private var selectedFormat: FilmFormat = .mini

    init(item: ChekiItem, onRequestBacksidePicker: @escaping () -> Void) {
        self.item = item
        self.onRequestBacksidePicker = onRequestBacksidePicker
        _borderInsetPercentage = State(initialValue: item.borderInsetRatio * 100.0)
        _selectedFormat = State(initialValue: item.filmFormat)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("邊界微調偏移 (Inset / Outset)", systemImage: "crop")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(String(format: "%+.1f%%", borderInsetPercentage))
                                .font(.subheadline.monospacedDigit().weight(.bold))
                                .foregroundStyle(abs(borderInsetPercentage) > 0.05 ? .blue : .secondary)
                        }

                        Slider(value: $borderInsetPercentage, in: -3.0...3.0, step: 0.5)
                            .onChange(of: borderInsetPercentage) { _, newValue in
                                item.borderInsetRatio = newValue / 100.0
                                try? modelContext.save()
                            }

                        HStack(spacing: 8) {
                            Button("-2% 去陰影") {
                                borderInsetPercentage = -2.0
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("0% 標準外框") {
                                borderInsetPercentage = 0.0
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("+2% 完整留白") {
                                borderInsetPercentage = 2.0
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("裁切邊界微調")
                } footer: {
                    Text("負值（Inset）可向內收縮去除桌面黑邊陰影；正值（Outset）可向外保留完整相紙邊緣。")
                }

                Section("相紙規格比例鎖定") {
                    Picker("相紙規格", selection: $selectedFormat) {
                        ForEach(FilmFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .onChange(of: selectedFormat) { _, newFormat in
                        item.filmFormat = newFormat
                        if newFormat != .auto {
                            item.detectedAspectRatio = newFormat.aspectRatio
                        }
                        try? modelContext.save()
                    }
                }

                Section("正反雙面管理") {
                    Button {
                        onRequestBacksidePicker()
                    } label: {
                        Label(
                            item.hasBothSides ? "從相簿替換背面照片" : "從相簿補上背面照片",
                            systemImage: "photo.badge.plus"
                        )
                    }
                }
            }
            .navigationTitle("調整拍立得")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
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
