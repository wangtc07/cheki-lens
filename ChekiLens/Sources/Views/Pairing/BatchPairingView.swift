import SwiftUI
import SwiftData
import PhotosUI
import Vision
import UIKit

// MARK: - BatchPairingMode (三段配對模式)

enum BatchPairingMode: String, CaseIterable, Identifiable {
    case singleOnly = "直接執行"
    case autoPair   = "自動配對"
    case manualPair = "手動配對"

    var id: String { rawValue }
}

// MARK: - DetectedPhotoSide (Vision 正反面特徵分類)

enum DetectedPhotoSide: String, Sendable {
    case analyzing   = "分析中"
    case likelyFront = "正面"
    case likelyBack  = "背面"
}

// MARK: - StagingChekiPhoto (工作台單張相片暫存項目)

struct StagingChekiPhoto: Identifiable, Equatable {
    let id: UUID
    /// 原始匯入順序編號（從 1 開始）
    var sequenceNumber: Int
    var title: String
    var imageData: Data
    var uiImage: UIImage
    var detectedSide: DetectedPhotoSide
    var detectionNote: String

    static func == (lhs: StagingChekiPhoto, rhs: StagingChekiPhoto) -> Bool {
        lhs.id == rhs.id &&
        lhs.sequenceNumber == rhs.sequenceNumber &&
        lhs.title == rhs.title &&
        lhs.detectedSide == rhs.detectedSide &&
        lhs.detectionNote == rhs.detectionNote
    }
}

// MARK: - ChekiPairingSlot (配對工作台中的一筆輸出單元：可為正反雙面或單面)

struct ChekiPairingSlot: Identifiable, Equatable {
    let id: UUID
    var frontPhoto: StagingChekiPhoto
    var backPhoto: StagingChekiPhoto?

    var isPaired: Bool {
        backPhoto != nil
    }

    /// Vision 雙正面防呆警示：當正反兩張都被 AI 判定為「正面」時觸發警告
    var isDoubleFrontWarning: Bool {
        guard let back = backPhoto else { return false }
        return frontPhoto.detectedSide == .likelyFront && back.detectedSide == .likelyFront
    }

    /// 正反順序顛倒提示：當第一張為背面、第二張為正面時提示可一鍵對調
    var isReversedOrderWarning: Bool {
        guard let back = backPhoto else { return false }
        return frontPhoto.detectedSide == .likelyBack && back.detectedSide == .likelyFront
    }
}

// MARK: - BatchPairingView (Task 4.4: 批次配對工作台 — 嚴格遵循 Apple iOS 17/18 原生 HIG)

/// 批次相簿匯入與正反面配對工作台
/// - 嚴格遵循 Apple iOS 18 原生相簿（如「重複項目合併」與原生 Inset Grouped Sheet）設計規範
/// - 支援 `PhotosPicker` 無上限多選匯入 (`maxSelectionCount: nil`)
/// - 頂部三段 Segmented Control：`直接執行` / `自動配對` / `手動配對`
/// - 內建 8 張擬真測試照片組（含正常正反配對、⚠️ Vision 雙正面防呆警示、⚠️ 正反顛倒與手動配對情境）
struct BatchPairingView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]
    @AppStorage("hasSeenBatchPairingCoachMark") private var hasSeenCoachMark: Bool = false
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = false

    let initialPickerItems: [PhotosPickerItem]
    let defaultMember: IdolMember?

    @State private var pairingMode: BatchPairingMode = .autoPair
    @State private var allPhotos: [StagingChekiPhoto] = []
    @State private var slots: [ChekiPairingSlot] = []

    // 手動配對模式下，使用者點選的第一張「待配對正面」Slot ID
    @State private var selectedFirstSlotID: UUID? = nil

    // 工作台內追加選取照片（不設張數上限 maxSelectionCount: nil）
    @State private var additionalPickerItems: [PhotosPickerItem] = []

    // 目標成員與規格設定
    @State private var selectedMember: IdolMember? = nil
    @State private var selectedFilmFormat: FilmFormat = .auto

    // 載入與處理狀態
    @State private var isLoadingPhotos: Bool = false
    @State private var isAnalyzingSides: Bool = false
    @State private var isProcessingBatch: Bool = false
    @State private var processedCount: Int = 0
    @State private var totalToProcess: Int = 0
    @State private var hasInitialized: Bool = false

    init(
        initialPickerItems: [PhotosPickerItem] = [],
        defaultMember: IdolMember? = nil
    ) {
        self.initialPickerItems = initialPickerItems
        self.defaultMember = defaultMember
        _selectedMember = State(initialValue: defaultMember)
    }

    private var pairedCount: Int {
        slots.filter(\.isPaired).count
    }

    private var singleCount: Int {
        slots.filter { !$0.isPaired }.count
    }

    private var doubleFrontWarningCount: Int {
        slots.filter(\.isDoubleFrontWarning).count
    }

    private var reversedWarningCount: Int {
        slots.filter(\.isReversedOrderWarning).count
    }

    private var totalWarningCount: Int {
        doubleFrontWarningCount + reversedWarningCount
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 頂部原生 Segmented Control 三段模式切換
                VStack(spacing: 8) {
                    Picker("配對模式", selection: $pairingMode) {
                        ForEach(BatchPairingMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

                if isLoadingPhotos && allPhotos.isEmpty {
                    loadingPlaceholderView
                } else if allPhotos.isEmpty {
                    emptyWorkbenchView
                } else {
                    slotListView
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("批次匯入與配對")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isProcessingBatch)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        PhotosPicker(
                            selection: $additionalPickerItems,
                            maxSelectionCount: nil,
                            matching: .images,
                            preferredItemEncoding: .automatic
                        ) {
                            Image(systemName: "plus")
                        }
                        .disabled(isProcessingBatch)
                        .accessibilityLabel("從相簿追加照片（不限張數）")

                        Menu {
                            Button {
                                loadSimulatedBatchSample()
                            } label: {
                                Label("載入 8 張測試照片組（含雙正面警示）", systemImage: "sparkles.rectangle.stack")
                            }

                            if totalWarningCount > 0 {
                                Button {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        resolveAllWarningsAutomatically()
                                    }
                                } label: {
                                    Label("一鍵修正所有警示項目", systemImage: "wand.and.stars")
                                }
                            }

                            if !allPhotos.isEmpty {
                                Divider()
                                Button(role: .destructive) {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        allPhotos.removeAll()
                                        slots.removeAll()
                                        selectedFirstSlotID = nil
                                    }
                                } label: {
                                    Label("清空工作台", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(isProcessingBatch)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !slots.isEmpty {
                    bottomActionToolbar
                }
            }
            .overlay {
                if isProcessingBatch {
                    batchProgressOverlay
                }
            }
            .task {
                guard !hasInitialized else { return }
                hasInitialized = true
                if selectedMember == nil {
                    selectedMember = defaultMember ?? idolMembers.first
                }
                if !initialPickerItems.isEmpty {
                    await appendPickerItems(initialPickerItems)
                } else {
                    // 若未帶入系統相簿照片，預設載入 8 張豐富測試資料（涵蓋正反配對、雙正面防呆警示、順序顛倒）
                    loadSimulatedBatchSample()
                }
            }
            .onChange(of: additionalPickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let itemsToLoad = newItems
                additionalPickerItems = []
                Task { await appendPickerItems(itemsToLoad) }
            }
            .onChange(of: pairingMode) { _, newMode in
                withAnimation(.snappy(duration: 0.25)) {
                    applyPairingMode(newMode)
                }
            }
        }
    }

    // MARK: - 1. 原生 Inset Grouped 列表

    private var slotListView: some View {
        List {
            // 首次開啟時的原境漸進式提示 (Contextual Coach Mark)
            if !hasSeenCoachMark {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("智慧正反面配對與雙正面防呆")
                                .font(.subheadline.weight(.semibold))
                            Text("「自動配對」會依序將兩張照片綁定為正反面，並以 Apple Vision 檢驗特徵。若偵測到連續兩張皆為正面，會標示橙色警示，您可隨時點選「解除」或向左滑動拆開。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 4)

                        Button {
                            withAnimation {
                                hasSeenCoachMark = true
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            // 歸檔成員與相紙規格設定 (Native iOS Form Picker Style)
            Section {
                HStack {
                    Label("歸檔成員", systemImage: "person.crop.circle")
                    Spacer()
                    Menu {
                        Button {
                            selectedMember = nil
                        } label: {
                            Label("未分類", systemImage: selectedMember == nil ? "checkmark" : "tray")
                        }
                        Divider()
                        ForEach(idolMembers) { member in
                            Button {
                                selectedMember = member
                            } label: {
                                let title = member.group != nil
                                    ? "\(member.stageName)（\(member.group!.name)）"
                                    : member.stageName
                                Label(title, systemImage: selectedMember?.id == member.id ? "checkmark" : "person")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let member = selectedMember {
                                Text(member.group != nil ? "\(member.group!.name) · \(member.stageName)" : member.stageName)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("未分類")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                    }
                }

                Picker(selection: $selectedFilmFormat) {
                    ForEach(FilmFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                } label: {
                    Label("相紙規格", systemImage: "aspectratio")
                }
            } header: {
                Text("匯入設定")
            }

            // Vision 防呆警示摘要列（僅在有雙正面或正反顛倒時出現）
            if totalWarningCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vision 偵測到 \(totalWarningCount) 組配對異常")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            if doubleFrontWarningCount > 0 && reversedWarningCount > 0 {
                                Text("含 \(doubleFrontWarningCount) 組疑似雙正面、\(reversedWarningCount) 組正反順序顛倒")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if doubleFrontWarningCount > 0 {
                                Text("有 \(doubleFrontWarningCount) 組連續兩張皆被識別為正面照片，可能導致錯配")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("有 \(reversedWarningCount) 組第一張為背面、第二張為正面")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button("自動修正") {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(.snappy(duration: 0.25)) {
                                resolveAllWarningsAutomatically()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }

            // 手動配對模式專屬操作指引列
            if pairingMode == .manualPair {
                Section {
                    manualPairingInstructionRow
                }
            }

            // 待處理拍立得配對清單
            Section {
                ForEach(slots) { slot in
                    slotRowView(for: slot)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if slot.isPaired {
                                Button {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        unpairSlot(id: slot.id)
                                    }
                                } label: {
                                    Label("解除配對", systemImage: "rectangle.on.rectangle.slash")
                                }
                                .tint(.orange)

                                Button {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        swapSlotSides(id: slot.id)
                                    }
                                } label: {
                                    Label("對調正反", systemImage: "arrow.left.arrow.right")
                                }
                                .tint(.indigo)
                            } else {
                                Button(role: .destructive) {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        removeSlot(id: slot.id)
                                    }
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if slot.isPaired {
                                Button {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        swapSlotSides(id: slot.id)
                                    }
                                } label: {
                                    Label("對調正反面順序", systemImage: "arrow.left.arrow.right")
                                }

                                Button {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        unpairSlot(id: slot.id)
                                    }
                                } label: {
                                    Label("解除配對（拆分為 2 張單面）", systemImage: "rectangle.on.rectangle.slash")
                                }
                            } else {
                                Button {
                                    handleManualTap(on: slot)
                                } label: {
                                    Label(
                                        selectedFirstSlotID == slot.id ? "取消選為正面" : "選為正面並與下一張配對",
                                        systemImage: "link.badge.plus"
                                    )
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                withAnimation(.snappy(duration: 0.22)) {
                                    removeSlot(id: slot.id)
                                }
                            } label: {
                                Label("從本次匯入移除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("已選取 \(allPhotos.count) 張照片 · 將輸出 \(slots.count) 張拍立得")
                    Spacer()
                    if isAnalyzingSides {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Vision 分析中")
                        }
                        .font(.caption2)
                    }
                }
            } footer: {
                Text("向左滑動已配對項目可快速「解除配對」或「對調正反」；在手動配對模式下，依序點選兩張單面照片即可綁定為正反雙面。")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 2. 手動配對指引列

    private var manualPairingInstructionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedFirstSlotID == nil ? "hand.tap" : "2.circle.fill")
                .font(.headline)
                .foregroundStyle(.tint)

            if let firstID = selectedFirstSlotID,
               let firstSlot = slots.first(where: { $0.id == firstID }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已選取「#\(firstSlot.frontPhoto.sequenceNumber) \(firstSlot.frontPhoto.title)」作為正面")
                        .font(.subheadline.weight(.semibold))
                    Text("請點選下方任一張單面照片作為【背面】完成配對")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("取消") {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedFirstSlotID = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("手動點選配對")
                        .font(.subheadline.weight(.semibold))
                    Text("依序點選兩張單面照片：第 1 下設為【正面】，第 2 下設為【背面】")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 3. 單列配對項目 (Native Apple Photos Duplicate/Merge Row Style)

    @ViewBuilder
    private func slotRowView(for slot: ChekiPairingSlot) -> some View {
        let isSelectedFirst = (selectedFirstSlotID == slot.id)

        HStack(spacing: 12) {
            // 左側：真實比例圓角縮圖（單張或正反並列）
            HStack(spacing: 6) {
                photoThumbnailView(
                    photo: slot.frontPhoto,
                    badge: "正面",
                    isSelected: isSelectedFirst,
                    isWarning: false
                )

                if let backPhoto = slot.backPhoto {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.snappy(duration: 0.22)) {
                            swapSlotSides(id: slot.id)
                        }
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(slot.isDoubleFrontWarning || slot.isReversedOrderWarning ? .orange : .secondary)
                            .frame(width: 22, height: 22)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("對調正反面順序")

                    photoThumbnailView(
                        photo: backPhoto,
                        badge: slot.isDoubleFrontWarning ? "正面?" : "背面",
                        isSelected: false,
                        isWarning: slot.isDoubleFrontWarning
                    )
                }
            }

            // 中間：標題與 Vision 狀態描述
            VStack(alignment: .leading, spacing: 4) {
                if slot.isPaired, let backPhoto = slot.backPhoto {
                    if slot.isDoubleFrontWarning {
                        Label("疑似兩張皆為正面", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("#\(slot.frontPhoto.sequenceNumber) 與 #\(backPhoto.sequenceNumber) 均偵測到正面特徵，建議解除配對")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if slot.isReversedOrderWarning {
                        Label("正反順序可能顛倒", systemImage: "arrow.left.arrow.right.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("#\(slot.frontPhoto.sequenceNumber) 偵測到背面字樣，點選「對調」可修正")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                            Text("正反雙面拍立得")
                                .font(.subheadline.weight(.semibold))
                        }

                        Text("#\(slot.frontPhoto.sequenceNumber) \(slot.frontPhoto.title) ＋ #\(backPhoto.sequenceNumber) \(backPhoto.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text("#\(slot.frontPhoto.sequenceNumber) \(slot.frontPhoto.title)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isSelectedFirst ? .blue : .primary)
                            .lineLimit(1)

                        Text(slot.frontPhoto.detectedSide.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(slot.frontPhoto.detectedSide == .likelyBack ? .purple : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }

                    Text(isSelectedFirst ? "已選為正面，請點選另一張單面照片作為背面" : slot.frontPhoto.detectionNote)
                        .font(.caption)
                        .foregroundStyle(isSelectedFirst ? .blue : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            // 右側：原生 iOS 按鈕（解除 / 對調 / 配對）
            if slot.isPaired {
                if slot.isReversedOrderWarning {
                    Button("對調") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.snappy(duration: 0.22)) {
                            swapSlotSides(id: slot.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                } else {
                    Button("解除") {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.snappy(duration: 0.22)) {
                            unpairSlot(id: slot.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(slot.isDoubleFrontWarning ? .orange : .secondary)
                    .controlSize(.small)
                }
            } else {
                Button(isSelectedFirst ? "已選" : "配對") {
                    handleManualTap(on: slot)
                }
                .buttonStyle(.bordered)
                .tint(isSelectedFirst ? .blue : .accentColor)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !slot.isPaired {
                handleManualTap(on: slot)
            }
        }
    }

    private func photoThumbnailView(
        photo: StagingChekiPhoto,
        badge: String,
        isSelected: Bool,
        isWarning: Bool
    ) -> some View {
        ZStack(alignment: .bottom) {
            Image(uiImage: photo.uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isWarning ? Color.orange : (isSelected ? Color.blue : Color.primary.opacity(0.12)),
                            lineWidth: isWarning || isSelected ? 2.0 : 0.5
                        )
                )

            Text(badge)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    isWarning ? Color.orange.opacity(0.9) : Color.black.opacity(0.55),
                    in: Capsule()
                )
                .padding(.bottom, 4)
        }
    }

    // MARK: - 4. 空白與載入狀態視圖

    private var loadingPlaceholderView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("正在載入照片並分析正反面特徵…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyWorkbenchView: some View {
        ContentUnavailableView {
            Label("尚未選取拍立得照片", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("從系統相簿多選匯入拍立得照片（不限張數），或載入 8 張測試照片體驗正反自動配對與雙正面防呆警示。")
        } actions: {
            VStack(spacing: 12) {
                PhotosPicker(
                    selection: $additionalPickerItems,
                    maxSelectionCount: nil,
                    matching: .images,
                    preferredItemEncoding: .automatic
                ) {
                    Label("從相簿選取照片（無張數上限）", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    loadSimulatedBatchSample()
                } label: {
                    Label("載入 8 張測試照片組", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 5. 底部原生行動列 & 進度遮罩

    private var bottomActionToolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Label(
                    "雙面 \(pairedCount) 組 · 單面 \(singleCount) 張",
                    systemImage: "rectangle.portrait.on.rectangle.portrait"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                Spacer()

                if totalWarningCount > 0 {
                    Label("\(totalWarningCount) 項待確認", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Button {
                Task { await executeBatchProcessing() }
            } label: {
                Text("開始處理並歸檔（共 \(slots.count) 張拍立得）")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(slots.isEmpty || isProcessingBatch)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var batchProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView(
                    value: Double(processedCount),
                    total: Double(max(1, totalToProcess))
                )
                .progressViewStyle(.linear)
                .frame(width: 210)

                Text("正在執行透視校正與手寫日期辨識…")
                    .font(.subheadline.weight(.semibold))

                Text("已完成 \(processedCount) / \(totalToProcess) 張拍立得")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - 6. 配對邏輯與防呆修正 (Pairing & Unpairing Operations)

    private func applyPairingMode(_ mode: BatchPairingMode) {
        selectedFirstSlotID = nil
        let orderedPhotos = collectAllPhotosInOrder()
        guard !orderedPhotos.isEmpty else {
            slots = []
            return
        }

        switch mode {
        case .singleOnly:
            slots = orderedPhotos.map { photo in
                ChekiPairingSlot(id: UUID(), frontPhoto: photo, backPhoto: nil)
            }

        case .autoPair:
            var newSlots: [ChekiPairingSlot] = []
            var idx = 0
            while idx < orderedPhotos.count {
                let first = orderedPhotos[idx]
                if idx + 1 < orderedPhotos.count {
                    let second = orderedPhotos[idx + 1]
                    newSlots.append(ChekiPairingSlot(id: UUID(), frontPhoto: first, backPhoto: second))
                    idx += 2
                } else {
                    newSlots.append(ChekiPairingSlot(id: UUID(), frontPhoto: first, backPhoto: nil))
                    idx += 1
                }
            }
            slots = newSlots

        case .manualPair:
            if slots.isEmpty {
                slots = orderedPhotos.map { photo in
                    ChekiPairingSlot(id: UUID(), frontPhoto: photo, backPhoto: nil)
                }
            }
        }
    }

    /// 一鍵自動處理所有異常：雙正面自動拆為 2 張獨立單面；正反顛倒自動對調
    private func resolveAllWarningsAutomatically() {
        var resolved: [ChekiPairingSlot] = []
        for slot in slots {
            if slot.isDoubleFrontWarning, let backPhoto = slot.backPhoto {
                resolved.append(ChekiPairingSlot(id: UUID(), frontPhoto: slot.frontPhoto, backPhoto: nil))
                resolved.append(ChekiPairingSlot(id: UUID(), frontPhoto: backPhoto, backPhoto: nil))
            } else if slot.isReversedOrderWarning, let backPhoto = slot.backPhoto {
                resolved.append(ChekiPairingSlot(id: slot.id, frontPhoto: backPhoto, backPhoto: slot.frontPhoto))
            } else {
                resolved.append(slot)
            }
        }
        slots = resolved
    }

    /// 解除指定 Slot 的正反面綁定，拆回兩張獨立單面拍立得
    private func unpairSlot(id: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == id }),
              let backPhoto = slots[index].backPhoto else { return }

        let frontPhoto = slots[index].frontPhoto
        let slotA = ChekiPairingSlot(id: UUID(), frontPhoto: frontPhoto, backPhoto: nil)
        let slotB = ChekiPairingSlot(id: UUID(), frontPhoto: backPhoto, backPhoto: nil)

        slots.replaceSubrange(index...index, with: [slotA, slotB])
    }

    /// 對調指定 Slot 的正反面順序
    private func swapSlotSides(id: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == id }),
              let backPhoto = slots[index].backPhoto else { return }

        let oldFront = slots[index].frontPhoto
        slots[index].frontPhoto = backPhoto
        slots[index].backPhoto = oldFront
    }

    /// 移除指定 Slot
    private func removeSlot(id: UUID) {
        if selectedFirstSlotID == id {
            selectedFirstSlotID = nil
        }
        slots.removeAll { $0.id == id }
        allPhotos = collectAllPhotosInOrder()
    }

    /// 手動點擊兩張單面相片進行配對（第 1 下指定正面，第 2 下指定背面）
    private func handleManualTap(on tappedSlot: ChekiPairingSlot) {
        guard !tappedSlot.isPaired else { return }

        if pairingMode != .manualPair {
            pairingMode = .manualPair
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if let firstID = selectedFirstSlotID {
            if firstID == tappedSlot.id {
                withAnimation(.snappy(duration: 0.2)) {
                    selectedFirstSlotID = nil
                }
                return
            }

            guard let firstIndex = slots.firstIndex(where: { $0.id == firstID }),
                  let secondIndex = slots.firstIndex(where: { $0.id == tappedSlot.id }) else {
                selectedFirstSlotID = nil
                return
            }

            let frontPhoto = slots[firstIndex].frontPhoto
            let backPhoto = slots[secondIndex].frontPhoto
            let combinedSlot = ChekiPairingSlot(id: UUID(), frontPhoto: frontPhoto, backPhoto: backPhoto)

            withAnimation(.snappy(duration: 0.25)) {
                let minIdx = min(firstIndex, secondIndex)
                let maxIdx = max(firstIndex, secondIndex)
                slots.remove(at: maxIdx)
                slots[minIdx] = combinedSlot
                selectedFirstSlotID = nil
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            withAnimation(.snappy(duration: 0.2)) {
                selectedFirstSlotID = tappedSlot.id
            }
        }
    }

    private func collectAllPhotosInOrder() -> [StagingChekiPhoto] {
        var collected: [StagingChekiPhoto] = []
        for slot in slots {
            collected.append(slot.frontPhoto)
            if let back = slot.backPhoto {
                collected.append(back)
            }
        }
        if collected.isEmpty {
            return allPhotos.sorted { $0.sequenceNumber < $1.sequenceNumber }
        }
        return collected.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    // MARK: - 7. 載入 PhotosPicker 相片與 Apple Vision 正反面特徵分析

    @MainActor
    private func appendPickerItems(_ pickerItems: [PhotosPickerItem]) async {
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }

        var newlyLoaded: [StagingChekiPhoto] = []
        var nextSequence = (allPhotos.map(\.sequenceNumber).max() ?? 0) + 1

        for item in pickerItems {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let rawImage = UIImage(data: data) else { continue }

            let normalized = rawImage.normalizedImage
            let normalizedData = normalized.jpegData(compressionQuality: 0.92) ?? data

            let staging = StagingChekiPhoto(
                id: UUID(),
                sequenceNumber: nextSequence,
                title: "匯入相片 \(nextSequence)",
                imageData: normalizedData,
                uiImage: normalized,
                detectedSide: .analyzing,
                detectionNote: "Vision 分析中…"
            )
            newlyLoaded.append(staging)
            nextSequence += 1
        }

        guard !newlyLoaded.isEmpty else { return }
        allPhotos.append(contentsOf: newlyLoaded)
        applyPairingMode(pairingMode)

        await analyzePhotoSides(for: newlyLoaded.map(\.id))
    }

    @MainActor
    private func analyzePhotoSides(for targetIDs: [UUID]) async {
        isAnalyzingSides = true
        defer { isAnalyzingSides = false }

        for photoID in targetIDs {
            guard let photo = findPhoto(by: photoID),
                  let cgImage = photo.uiImage.cgImage else { continue }

            let (side, note) = await Self.classifyPhotoSide(cgImage: cgImage)
            updatePhotoSide(id: photoID, side: side, note: note)
        }
    }

    private func findPhoto(by id: UUID) -> StagingChekiPhoto? {
        for slot in slots {
            if slot.frontPhoto.id == id { return slot.frontPhoto }
            if let back = slot.backPhoto, back.id == id { return back }
        }
        return allPhotos.first { $0.id == id }
    }

    private func updatePhotoSide(id: UUID, side: DetectedPhotoSide, note: String) {
        if let idx = allPhotos.firstIndex(where: { $0.id == id }) {
            allPhotos[idx].detectedSide = side
            allPhotos[idx].detectionNote = note
        }
        for i in slots.indices {
            if slots[i].frontPhoto.id == id {
                slots[i].frontPhoto.detectedSide = side
                slots[i].frontPhoto.detectionNote = note
            }
            if slots[i].backPhoto?.id == id {
                slots[i].backPhoto?.detectedSide = side
                slots[i].backPhoto?.detectionNote = note
            }
        }
    }

    /// 使用 Apple Vision (`BacksideDetector` + `VNDetectFaceRectanglesRequest`) 判定相片屬於正面或背面
    nonisolated private static func classifyPhotoSide(cgImage: CGImage) async -> (DetectedPhotoSide, String) {
        let size = CGSize(width: cgImage.width, height: cgImage.height)

        if let backRes = try? await BacksideDetector.detect(in: cgImage, imageSize: size),
           backRes.isBackside {
            return (.likelyBack, "Vision 偵測到 instax 背面標記與手寫區")
        }

        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([faceRequest])
        if let faces = faceRequest.results, !faces.isEmpty {
            return (.likelyFront, "Vision 偵測到正面人物主體")
        }

        let centerPt = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        let centerLum = FrameExtrapolator.sampleLuminance(in: cgImage, at: centerPt)
        if centerLum < 70 {
            return (.likelyBack, "Vision 偵測為深色背面特徵")
        }

        return (.likelyFront, "Vision 偵測為拍立得正面影像窗")
    }

    // MARK: - 8. 豐富擬真測試資料集（8 張涵蓋正反配對、⚠️ 雙正面防呆警示、⚠️ 正反顛倒與單面測試案例）

    private func loadSimulatedBatchSample() {
        let sampleSpecs: [(seq: Int, title: String, side: DetectedPhotoSide, note: String, colors: [UIColor], isBackLook: Bool, dateText: String)] = [
            // Pair 1: 正常正反配對 (#1 正面 + #2 背面)
            (1, "夏巡舞台服特寫", .likelyFront, "Vision 偵測到正面人物主體", [.systemIndigo, .systemPink], false, "2026.09.24"),
            (2, "夏巡簽名背面",   .likelyBack,  "Vision 偵測到 instax 背面標記", [.darkGray, .black], true, "2026.09.24"),
            // Pair 2: ⚠️ 雙正面防呆警示案例 (#3 正面 + #4 正面)
            (3, "浴衣造型正面",   .likelyFront, "Vision 偵測到正面人物主體", [.systemTeal, .systemBlue], false, "2026.09.28"),
            (4, "生誕祭私服正面", .likelyFront, "Vision 偵測到正面人物主體", [.systemOrange, .systemPink], false, "2026.09.29"),
            // Pair 3: ⚠️ 正反順序顛倒警示案例 (#5 背面 + #6 正面)
            (5, "握手會背面留言", .likelyBack,  "Vision 偵測到 instax 背面標記", [.systemGray, .darkGray], true, "2026.10.02"),
            (6, "握手會比愛心正面", .likelyFront, "Vision 偵測到正面人物主體", [.systemPurple, .systemIndigo], false, "2026.10.02"),
            // Pair 4: 正常正反配對 (#7 正面 + #8 背面)
            (7, "五週年紀念服正面", .likelyFront, "Vision 偵測到正面人物主體", [.systemPink, .systemRed], false, "2026.10.05"),
            (8, "五週年感謝留言背面", .likelyBack, "Vision 偵測到 instax 背面標記", [.darkGray, .systemIndigo], true, "2026.10.05")
        ]

        var generated: [StagingChekiPhoto] = []
        for spec in sampleSpecs {
            let img = Self.renderSampleChekiImage(
                sequence: spec.seq,
                title: spec.title,
                colors: spec.colors,
                isBackside: spec.isBackLook,
                dateText: spec.dateText
            )
            let data = img.jpegData(compressionQuality: 0.9) ?? Data()
            generated.append(
                StagingChekiPhoto(
                    id: UUID(),
                    sequenceNumber: spec.seq,
                    title: spec.title,
                    imageData: data,
                    uiImage: img,
                    detectedSide: spec.side,
                    detectionNote: spec.note
                )
            )
        }

        withAnimation(.snappy(duration: 0.25)) {
            allPhotos = generated
            pairingMode = .autoPair
            applyPairingMode(.autoPair)
        }
    }

    private static func renderSampleChekiImage(
        sequence: Int,
        title: String,
        colors: [UIColor],
        isBackside: Bool,
        dateText: String
    ) -> UIImage {
        let size = CGSize(width: 540, height: 860)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // 拍立得相紙外框
            cg.setFillColor(UIColor(white: isBackside ? 0.93 : 0.98, alpha: 1.0).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            let innerRect = CGRect(x: 40, y: 52, width: 460, height: 616)
            cg.saveGState()
            cg.addRect(innerRect)
            cg.clip()

            let cgColors = colors.map {
                isBackside ? $0.withAlphaComponent(0.24).cgColor : $0.cgColor
            } as CFArray

            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: cgColors,
                locations: [0.0, 1.0]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: innerRect.minX, y: innerRect.minY),
                    end: CGPoint(x: innerRect.maxX, y: innerRect.maxY),
                    options: []
                )
            }

            if !isBackside {
                // 模擬正面人物剪影與柔光光斑
                cg.setFillColor(UIColor.white.withAlphaComponent(0.28).cgColor)
                cg.fillEllipse(in: CGRect(x: 195, y: 170, width: 150, height: 150))
                cg.fillEllipse(in: CGRect(x: 120, y: 340, width: 300, height: 280))
            } else {
                // 模擬背面手寫留言筆跡與 instax 標識
                let backAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
                    .foregroundColor: UIColor.darkGray
                ]
                NSAttributedString(string: "いつもありがとう！♡\nまた来週のライブでね", attributes: backAttrs)
                    .draw(in: CGRect(x: 80, y: 240, width: 380, height: 140))

                let instaxAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: UIColor.gray
                ]
                NSAttributedString(string: "FUJIFILM instax", attributes: instaxAttrs)
                    .draw(at: CGPoint(x: 165, y: 590))
            }
            cg.restoreGState()

            // 下巴區域手寫日期（供 Vision OCR 辨識）
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .bold),
                .foregroundColor: UIColor(white: 0.22, alpha: 1.0)
            ]
            NSAttributedString(string: dateText, attributes: dateAttrs)
                .draw(at: CGPoint(x: 56, y: 720))

            let seqAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
            NSAttributedString(string: "#\(sequence) \(title)", attributes: seqAttrs)
                .draw(at: CGPoint(x: 56, y: 765))
        }
    }

    // MARK: - 9. 執行批次 Vision 透視拉直、OCR 日期辨識與 SwiftData 儲存

    @MainActor
    private func executeBatchProcessing() async {
        guard !slots.isEmpty else { return }
        isProcessingBatch = true
        processedCount = 0
        totalToProcess = slots.count
        defer { isProcessingBatch = false }

        let visionManager = VisionManager()
        let baseTimestamp = Date()

        for (index, slot) in slots.enumerated() {
            // 同一組拍立得的正反面賦予完全相同的秒數 (Task 3.3)
            let itemTimestamp = baseTimestamp.addingTimeInterval(TimeInterval(-index))

            let newItem = ChekiItem(
                frontImageData: slot.frontPhoto.imageData,
                backImageData: slot.backPhoto?.imageData,
                capturedAt: itemTimestamp,
                filmFormat: selectedFilmFormat,
                detectedAspectRatio: selectedFilmFormat == .auto ? FilmFormat.mini.aspectRatio : selectedFilmFormat.aspectRatio,
                processingState: .detecting,
                idolMember: selectedMember
            )
            modelContext.insert(newItem)

            // 1. 正面透視校正 + 手寫日期 OCR
            var finalFrontUIImage = slot.frontPhoto.uiImage
            if let frontCG = slot.frontPhoto.uiImage.cgImage {
                let imgSize = CGSize(width: frontCG.width, height: frontCG.height)
                if let detection = try? await visionManager.detectQuad(in: frontCG, imageSize: imgSize),
                   let cropRes = try? await visionManager.perspectiveCorrect(
                       image: frontCG,
                       corners: detection.corners,
                       detection: detection,
                       format: .auto
                   ) {
                    let croppedUI = UIImage(cgImage: cropRes.cgImage)
                    finalFrontUIImage = croppedUI
                    if let jpeg = croppedUI.jpegData(compressionQuality: 0.92) {
                        newItem.frontImageData = jpeg
                    }
                    newItem.detectionMethod = .visionNative
                    if let ocrRes = await visionManager.recognizeDate(from: cropRes.cgImage) {
                        newItem.ocrDate = ocrRes.date
                    }
                } else {
                    // 若為已裁切模擬圖，直接對下巴做 OCR 日期辨識
                    if let ocrRes = await visionManager.recognizeDate(from: frontCG) {
                        newItem.ocrDate = ocrRes.date
                    }
                }
            }

            // 2. 背面透視校正（若有配對背面）
            var finalBackUIImage: UIImage? = slot.backPhoto?.uiImage
            if let backPhoto = slot.backPhoto,
               let backCG = backPhoto.uiImage.cgImage {
                let backSize = CGSize(width: backCG.width, height: backCG.height)
                if let backDetection = try? await visionManager.detectQuad(in: backCG, imageSize: backSize),
                   let backCrop = try? await visionManager.perspectiveCorrect(
                       image: backCG,
                       corners: backDetection.corners,
                       detection: backDetection,
                       format: .auto
                   ) {
                    let croppedBackUI = UIImage(cgImage: backCrop.cgImage)
                    finalBackUIImage = croppedBackUI
                    if let jpeg = croppedBackUI.jpegData(compressionQuality: 0.92) {
                        newItem.backImageData = jpeg
                    }
                }
            }

            let memo = ChekiMemo(
                eventName: "批次配對匯入",
                noteText: slot.isPaired
                    ? "透過批次配對工作台合成正反雙面（\(slot.frontPhoto.title)）"
                    : "透過批次工作台單面匯入（\(slot.frontPhoto.title)）",
                hashtags: slot.isPaired ? ["#雙面配對", "#批次匯入"] : ["#單面匯入"],
                chekiItem: newItem
            )
            newItem.memo = memo
            newItem.processingState = .completed

            // 3. 若開啟系統相簿同步，將正反面以同一秒 creationDate 寫入對應相簿 (Task 3.3 & 3.4)
            if autoSyncToPhotos {
                let syncDate = newItem.displayDate
                let albumName = selectedMember?.stageName ?? "ChekiLens"
                let folderName = selectedMember?.group?.name
                if let album = try? await PhotoLibraryManager.shared.getOrCreateAlbum(
                    albumName: albumName,
                    inFolder: folderName
                ) {
                    _ = try? await PhotoLibraryManager.shared.saveImage(
                        finalFrontUIImage,
                        creationDate: syncDate,
                        to: album
                    )
                    if let backImg = finalBackUIImage {
                        _ = try? await PhotoLibraryManager.shared.saveImage(
                            backImg,
                            creationDate: syncDate,
                            to: album
                        )
                    }
                    newItem.isSyncedToPhotoLibrary = true
                    newItem.isDateWrittenToAlbum = (newItem.ocrDate != nil)
                }
            }

            processedCount = index + 1
        }

        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// MARK: - Preview

#Preview("04. 批次配對工作台 (Apple HIG Native)") {
    BatchPairingView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}
