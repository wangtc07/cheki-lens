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

// MARK: - ChekiPairingSlot (配對工作台中的一筆輸出單元：支援個別指派成員、正反雙面撲克牌展開或單面)

struct ChekiPairingSlot: Identifiable, Equatable {
    let id: UUID
    var frontPhoto: StagingChekiPhoto
    var backPhoto: StagingChekiPhoto?
    /// 每張（或每組）拍立得可獨立指派歸檔成員（支援同一批上傳多位不同成員）
    var assignedMember: IdolMember?

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

    static func == (lhs: ChekiPairingSlot, rhs: ChekiPairingSlot) -> Bool {
        lhs.id == rhs.id &&
        lhs.frontPhoto == rhs.frontPhoto &&
        lhs.backPhoto == rhs.backPhoto &&
        lhs.assignedMember?.id == rhs.assignedMember?.id
    }
}

// MARK: - BatchPairingView (Task 4.4: 批次配對工作台 — 格狀相簿檢視 + 撲克牌正反展開 + 多人歸檔設定)

/// 批次相簿匯入與正反面配對工作台
/// - 採用與相簿一覽相同的 **格狀檢視 (`LazyVGrid`)**
/// - 正反雙面配對項目採用 **撲克牌兩張扇形展開樣式 (`Playing-Card Fan`)**，直覺呈現正反疊合關係
/// - 支援 **多人歸檔設定**：每組拍立得卡片下方皆可獨立指派所屬成員，亦支援頂部「快速指派成員筆刷」與「批次套用」
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

    /// 記錄每張相片已指派的成員（切換配對模式或拆開/重組時保留各自的成員設定）
    @State private var photoMemberAssignment: [UUID: IdolMember] = [:]

    /// 快速指派成員筆刷（若開啟，點選任一成員標籤後點擊卡片即可快速指派該成員；nil 代表一般配對點擊）
    @State private var activeBrushMember: IdolMember? = nil
    @State private var isMemberBrushMode: Bool = false

    // 手動配對模式下，使用者點選的第一張「待配對正面」Slot ID
    @State private var selectedFirstSlotID: UUID? = nil

    // 工作台內追加選取照片（不設張數上限 maxSelectionCount: nil）
    @State private var additionalPickerItems: [PhotosPickerItem] = []

    // 預設成員（供新匯入相片預設帶入）與相紙規格設定
    @State private var defaultFallbackMember: IdolMember? = nil
    @State private var selectedFilmFormat: FilmFormat = .auto
    @State private var showingQuickCreateMemberSheet: Bool = false

    // 載入與處理狀態
    @State private var isLoadingPhotos: Bool = false
    @State private var isAnalyzingSides: Bool = false
    @State private var isProcessingBatch: Bool = false
    @State private var processedCount: Int = 0
    @State private var totalToProcess: Int = 0
    @State private var hasInitialized: Bool = false
    @State private var isUsingSimulatedSample: Bool = false
    @State private var systemPhotoSeedAlertMessage: String? = nil

    init(
        initialPickerItems: [PhotosPickerItem] = [],
        defaultMember: IdolMember? = nil
    ) {
        self.initialPickerItems = initialPickerItems
        self.defaultMember = defaultMember
        _defaultFallbackMember = State(initialValue: defaultMember)
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

    /// 目前所有卡片涵蓋的不同成員摘要（例如：「遠藤さくら、河田陽菜 等 3 人」）
    private var assignedMembersSummary: String {
        var uniqueNames: [String] = []
        var hasUncategorized = false
        for slot in slots {
            if let name = slot.assignedMember?.stageName {
                if !uniqueNames.contains(name) {
                    uniqueNames.append(name)
                }
            } else {
                hasUncategorized = true
            }
        }
        if uniqueNames.isEmpty {
            return "未分類"
        } else if uniqueNames.count == 1 && !hasUncategorized {
            return uniqueNames[0]
        } else if uniqueNames.count == 1 && hasUncategorized {
            return "\(uniqueNames[0]) ＋ 未分類"
        } else if uniqueNames.count == 2 && !hasUncategorized {
            return "\(uniqueNames[0])、\(uniqueNames[1])"
        } else {
            return "\(uniqueNames[0])、\(uniqueNames[1]) 等 \(uniqueNames.count) 人"
        }
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
                    slotGridWorkbenchView
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
                                Task {
                                    do {
                                        let count = try await PhotoLibraryManager.shared.seedTestChekiPhotosToSystemLibrary(force: true)
                                        systemPhotoSeedAlertMessage = "已成功將 \(count) 張測試拍立得（含正常正反面、雙正面防呆案例、正反顛倒案例）寫入 iOS 系統相簿 (Photos.app)。\n\n現在可點選上方「＋」直接從系統相簿勾選這 8 張相片進行匯入測試！"
                                    } catch {
                                        systemPhotoSeedAlertMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Label("寫入 8 張測試相片至系統相簿 (Photos.app)", systemImage: "photo.badge.plus")
                            }

                            Button {
                                loadSimulatedBatchSample()
                            } label: {
                                Label("載入 8 張內建測試組（多人＋雙正面警示）", systemImage: "sparkles.rectangle.stack")
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
                                        photoMemberAssignment.removeAll()
                                        selectedFirstSlotID = nil
                                        isUsingSimulatedSample = false
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
            .sheet(isPresented: $showingQuickCreateMemberSheet) {
                QuickCreateIdolSheet()
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
                guard !hasInitialized else { return }
                hasInitialized = true
                if defaultFallbackMember == nil {
                    defaultFallbackMember = defaultMember ?? idolMembers.first
                }
                if !initialPickerItems.isEmpty {
                    isUsingSimulatedSample = false
                    await appendPickerItems(initialPickerItems)
                } else {
                    loadSimulatedBatchSample()
                }
            }
            .onChange(of: additionalPickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let itemsToLoad = newItems
                additionalPickerItems = []
                Task {
                    if isUsingSimulatedSample {
                        allPhotos.removeAll()
                        slots.removeAll()
                        photoMemberAssignment.removeAll()
                        isUsingSimulatedSample = false
                    }
                    await appendPickerItems(itemsToLoad)
                }
            }
            .onChange(of: pairingMode) { _, newMode in
                withAnimation(.snappy(duration: 0.25)) {
                    applyPairingMode(newMode)
                }
            }
        }
    }

    // MARK: - 1. 格狀配對工作台主視圖 (Album-Style Grid + Playing-Card Fan)

    private var slotGridWorkbenchView: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let columnCount = isLandscape ? 3 : 2
            let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columnCount)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 1. 多人歸檔成員與相紙規格設定卡
                    multiMemberAndFormatHeaderCard

                    // 2. Vision 防呆警示橫幅（若有雙正面或正反顛倒）
                    if totalWarningCount > 0 {
                        warningBannerCard
                    }

                    // 3. 手動配對或快速指派成員指引列
                    if isMemberBrushMode {
                        memberBrushInstructionBanner
                    } else if pairingMode == .manualPair || selectedFirstSlotID != nil {
                        manualPairingInstructionBanner
                    }

                    // 4. 格狀標題列
                    HStack {
                        Text("已選取 \(allPhotos.count) 張照片 · 將輸出 \(slots.count) 張拍立得")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if isAnalyzingSides {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Vision 分析中")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(pairingMode == .singleOnly ? "單張獨立模式" : "正反撲克牌展開")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 4)

                    // 5. 格狀拍立得卡片一覽 (LazyVGrid)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(slots) { slot in
                            slotGridCell(for: slot)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - 2. 多人歸檔成員與規格設定卡 (Multi-Member Assignment & Format Header)

    private var multiMemberAndFormatHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 第一列：歸檔成員摘要 + 批次套用選單
            HStack {
                Label("歸檔成員", systemImage: "person.2.crop.square.stack")
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(assignedMembersSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Menu {
                    Section("將全部拍立得統一設為") {
                        Button {
                            assignMemberToAllSlots(nil)
                        } label: {
                            Label("全部設為「未分類」", systemImage: "tray")
                        }

                        ForEach(idolMembers) { member in
                            Button {
                                assignMemberToAllSlots(member)
                            } label: {
                                let title = member.group != nil
                                    ? "\(member.stageName)（\(member.group!.name)）"
                                    : member.stageName
                                Label("全部設為 \(title)", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                    }

                    Divider()

                    Button {
                        showingQuickCreateMemberSheet = true
                    } label: {
                        Label("新增團體 / 成員…", systemImage: "person.badge.plus")
                    }
                } label: {
                    Text("全部套用")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }

            // 第二列：多人快速指派成員晶片列（支援點選成員晶片後，直接點擊下方卡片快速指派不同成員）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 快速指派筆刷開關提示
                    ForEach(idolMembers) { member in
                        let isBrushSelected = isMemberBrushMode && activeBrushMember?.id == member.id
                        let countForMember = slots.filter { $0.assignedMember?.id == member.id }.count

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.snappy(duration: 0.2)) {
                                if isBrushSelected {
                                    isMemberBrushMode = false
                                    activeBrushMember = nil
                                } else {
                                    isMemberBrushMode = true
                                    activeBrushMember = member
                                    selectedFirstSlotID = nil
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Self.groupColor(for: member))
                                    .frame(width: 7, height: 7)

                                Text(member.stageName)
                                    .font(.caption.weight(.semibold))

                                if countForMember > 0 {
                                    Text("\(countForMember)")
                                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                                        .foregroundStyle(isBrushSelected ? Color.accentColor : .white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            isBrushSelected ? Color.white : Color.secondary.opacity(0.45),
                                            in: Capsule()
                                        )
                                }
                            }
                            .foregroundStyle(isBrushSelected ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isBrushSelected ? Color.accentColor : Color(.tertiarySystemFill),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // 新增成員按鈕
                    Button {
                        showingQuickCreateMemberSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.caption2.weight(.bold))
                            Text("新增成員")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // 第三列：相紙規格選擇
            HStack {
                Label("相紙規格", systemImage: "aspectratio")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("相紙規格", selection: $selectedFilmFormat) {
                    ForEach(FilmFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 3. 格狀卡片單元：撲克牌兩張展開樣式 (Playing-Card Fan) & 單張直立樣式

    @ViewBuilder
    private func slotGridCell(for slot: ChekiPairingSlot) -> some View {
        let isSelectedFirst = (selectedFirstSlotID == slot.id)
        let hasWarning = slot.isDoubleFrontWarning || slot.isReversedOrderWarning

        VStack(spacing: 8) {
            // 上方視覺舞台：若為正反雙面則呈現「撲克牌兩張扇形展開」，若為單面則呈現單張拍立得
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isSelectedFirst
                                    ? Color.blue
                                    : (hasWarning ? Color.orange.opacity(0.85) : Color.primary.opacity(0.06)),
                                lineWidth: isSelectedFirst || hasWarning ? 2.0 : 1.0
                            )
                    )

                if slot.isPaired, let backPhoto = slot.backPhoto {
                    playingCardFanView(slot: slot, frontPhoto: slot.frontPhoto, backPhoto: backPhoto)
                } else {
                    singleCardStageView(slot: slot, photo: slot.frontPhoto, isSelectedFirst: isSelectedFirst)
                }
            }
            .frame(height: 192)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture {
                handleCellTap(on: slot)
            }
            .contextMenu {
                slotContextMenu(for: slot)
            }

            // 下方：每張（或每組）拍立得獨立的「歸檔成員選擇膠囊」(支援一次上傳不同人的拍立得)
            perSlotMemberSelectorPill(for: slot)
        }
    }

    /// 撲克牌兩張展開樣式 (Playing-Card Fan)：左前為「正面」、右後扇形展開為「背面」
    private func playingCardFanView(
        slot: ChekiPairingSlot,
        frontPhoto: StagingChekiPhoto,
        backPhoto: StagingChekiPhoto
    ) -> some View {
        ZStack {
            // 1. 右後扇形展開：背面卡片 (Back Card — 向右旋轉展開如撲克牌)
            ZStack(alignment: .topTrailing) {
                Image(uiImage: backPhoto.uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 90, height: 136)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                slot.isDoubleFrontWarning ? Color.orange : Color.white.opacity(0.65),
                                lineWidth: slot.isDoubleFrontWarning ? 2.0 : 1.0
                            )
                    )
                    .shadow(color: .black.opacity(0.18), radius: 6, x: 2, y: 3)

                Text(slot.isDoubleFrontWarning ? "正面?" : "背面")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        slot.isDoubleFrontWarning ? Color.orange : Color.black.opacity(0.68),
                        in: Capsule()
                    )
                    .padding(5)
            }
            .rotationEffect(.degrees(11), anchor: .bottom)
            .offset(x: 20, y: 2)

            // 2. 左前扇形展開：正面卡片 (Front Card — 向左微傾疊於前側)
            ZStack(alignment: .topLeading) {
                Image(uiImage: frontPhoto.uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2)
                    )
                    .shadow(color: .black.opacity(0.32), radius: 9, x: 4, y: 4)

                Text("正面")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.88), in: Capsule())
                    .padding(5)
            }
            .rotationEffect(.degrees(-8), anchor: .bottom)
            .offset(x: -16, y: 0)

            // 3. 頂部左右控制角標：左側序號 (#1+#2)，右側一鍵「拆開」按鈕
            VStack {
                HStack {
                    Text("#\(frontPhoto.sequenceNumber)+#\(backPhoto.sequenceNumber)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())

                    Spacer()

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.snappy(duration: 0.24)) {
                            unpairSlot(id: slot.id)
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "rectangle.on.rectangle.slash")
                                .font(.system(size: 9, weight: .bold))
                            Text("拆開")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(slot.isDoubleFrontWarning ? .white : .primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(
                            slot.isDoubleFrontWarning
                                ? AnyShapeStyle(Color.orange)
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("解除正反面配對")
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Spacer()

                // 4. 底部中央：撲克牌交疊處的「⇄ 對調正反」或異常提示膠囊
                HStack {
                    if slot.isDoubleFrontWarning {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(.snappy(duration: 0.24)) {
                                unpairSlot(id: slot.id)
                            }
                        } label: {
                            Label("疑似雙正面 · 點此拆開", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else if slot.isReversedOrderWarning {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(.snappy(duration: 0.24)) {
                                swapSlotSides(id: slot.id)
                            }
                        } label: {
                            Label("順序顛倒 · 點此對調", systemImage: "arrow.left.arrow.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.snappy(duration: 0.24)) {
                                swapSlotSides(id: slot.id)
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 9.5, weight: .bold))
                                Text("對調正反")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("對調正反面順序")
                    }
                }
                .padding(.bottom, 7)
            }
        }
    }

    /// 單張直立拍立得樣式 (Single Card Stage)
    private func singleCardStageView(
        slot: ChekiPairingSlot,
        photo: StagingChekiPhoto,
        isSelectedFirst: Bool
    ) -> some View {
        ZStack {
            Image(uiImage: photo.uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelectedFirst ? Color.blue : Color.white.opacity(0.75),
                            lineWidth: isSelectedFirst ? 2.2 : 1.0
                        )
                )
                .shadow(color: .black.opacity(0.22), radius: 7, x: 0, y: 3)

            VStack {
                HStack {
                    Text("#\(photo.sequenceNumber)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())

                    Spacer()

                    Text(photo.detectedSide.rawValue)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            photo.detectedSide == .likelyBack ? Color.purple.opacity(0.85) : Color.black.opacity(0.58),
                            in: Capsule()
                        )
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Spacer()

                if pairingMode != .singleOnly {
                    Button {
                        handleManualTap(on: slot)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isSelectedFirst ? "checkmark.circle.fill" : "link.badge.plus")
                                .font(.system(size: 10, weight: .bold))
                            Text(isSelectedFirst ? "已選為正面 · 點另一張配對" : "點選配對背面")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(isSelectedFirst ? .white : .primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            isSelectedFirst
                                ? AnyShapeStyle(Color.blue)
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 7)
                }
            }
        }
    }

    /// 每組拍立得卡片正下方的「個別成員選擇膠囊」(支援同一批設定多位不同成員)
    private func perSlotMemberSelectorPill(for slot: ChekiPairingSlot) -> some View {
        Menu {
            Section("指派此張拍立得的歸檔成員") {
                Button {
                    setMember(nil, forSlotID: slot.id)
                } label: {
                    Label("未分類", systemImage: slot.assignedMember == nil ? "checkmark" : "tray")
                }

                ForEach(idolMembers) { member in
                    Button {
                        setMember(member, forSlotID: slot.id)
                    } label: {
                        let title = member.group != nil
                            ? "\(member.stageName)（\(member.group!.name)）"
                            : member.stageName
                        Label(title, systemImage: slot.assignedMember?.id == member.id ? "checkmark" : "person")
                    }
                }
            }

            Divider()

            Button {
                showingQuickCreateMemberSheet = true
            } label: {
                Label("新增團體 / 成員…", systemImage: "person.badge.plus")
            }
        } label: {
            HStack(spacing: 6) {
                if let member = slot.assignedMember {
                    Circle()
                        .fill(Self.groupColor(for: member))
                        .frame(width: 8, height: 8)

                    Text(member.stageName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let groupName = member.group?.name {
                        Text(groupName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("未分類 · 選擇成員")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static func groupColor(for member: IdolMember?) -> Color {
        guard let rawHex = member?.group?.colorHex else { return .pink }
        let hex = rawHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            return .pink
        }
        return Color(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: 1.0
        )
    }

    @ViewBuilder
    private func slotContextMenu(for slot: ChekiPairingSlot) -> some View {
        Menu {
            Button {
                setMember(nil, forSlotID: slot.id)
            } label: {
                Label("未分類", systemImage: slot.assignedMember == nil ? "checkmark" : "tray")
            }
            ForEach(idolMembers) { member in
                Button {
                    setMember(member, forSlotID: slot.id)
                } label: {
                    Label(member.stageName, systemImage: slot.assignedMember?.id == member.id ? "checkmark" : "person")
                }
            }
        } label: {
            Label("指派歸檔成員", systemImage: "person.crop.circle")
        }

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
                Label("解除配對（拆為 2 張單面）", systemImage: "rectangle.on.rectangle.slash")
            }
        } else {
            Button {
                handleManualTap(on: slot)
            } label: {
                Label(
                    selectedFirstSlotID == slot.id ? "取消選為正面" : "選為正面並與另一張配對",
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

    // MARK: - 4. 警示橫幅與模式指引列

    private var warningBannerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Vision 偵測到 \(totalWarningCount) 組配對異常")
                    .font(.subheadline.weight(.semibold))

                if doubleFrontWarningCount > 0 && reversedWarningCount > 0 {
                    Text("含 \(doubleFrontWarningCount) 組疑似雙正面、\(reversedWarningCount) 組正反顛倒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if doubleFrontWarningCount > 0 {
                    Text("有 \(doubleFrontWarningCount) 組連續兩張皆為正面，建議拆開")
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
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var memberBrushInstructionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)

            if let brushMember = activeBrushMember {
                Text("快速指派模式：直接點選下方任一拍立得卡片，即可將其歸檔至「**\(brushMember.stageName)**」")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button("完成指派") {
                withAnimation(.snappy(duration: 0.2)) {
                    isMemberBrushMode = false
                    activeBrushMember = nil
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var manualPairingInstructionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedFirstSlotID == nil ? "hand.tap.fill" : "2.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.blue)

            if let firstID = selectedFirstSlotID,
               let firstSlot = slots.first(where: { $0.id == firstID }) {
                Text("已選取 **#\(firstSlot.frontPhoto.sequenceNumber)** 為正面，請點選另一張單面卡片合成撲克牌正反組")
                    .font(.caption)
                Spacer()
                Button("取消") {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedFirstSlotID = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Text("點選任兩張單面卡片即可合成「正反撲克牌展開組」；點選已配對卡片右上角「拆開」可解除綁定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 5. 空白與載入狀態視圖

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
            Text("從系統相簿多選匯入拍立得照片（不限張數），支援一次為不同成員的拍立得個別歸檔與正反配對。")
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

    // MARK: - 6. 底部原生行動列 & 進度遮罩

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
                } else {
                    Text(assignedMembersSummary)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

                Text("正在執行透視校正與多人歸檔…")
                    .font(.subheadline.weight(.semibold))

                Text("已完成 \(processedCount) / \(totalToProcess) 張拍立得")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - 7. 多人成員指派與配對邏輯 (Multi-Member & Pairing Operations)

    private func setMember(_ member: IdolMember?, forSlotID slotID: UUID) {
        guard let idx = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[idx].assignedMember = member
        photoMemberAssignment[slots[idx].frontPhoto.id] = member
        if let backID = slots[idx].backPhoto?.id {
            photoMemberAssignment[backID] = member
        }
    }

    private func assignMemberToAllSlots(_ member: IdolMember?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        defaultFallbackMember = member
        for idx in slots.indices {
            slots[idx].assignedMember = member
            photoMemberAssignment[slots[idx].frontPhoto.id] = member
            if let backID = slots[idx].backPhoto?.id {
                photoMemberAssignment[backID] = member
            }
        }
    }

    private func resolvedMember(for photo: StagingChekiPhoto, slotIndex: Int) -> IdolMember? {
        if let existing = photoMemberAssignment[photo.id] {
            return existing
        }
        if let defaultMember = defaultFallbackMember {
            return defaultMember
        }
        guard !idolMembers.isEmpty else { return nil }
        return idolMembers[slotIndex % idolMembers.count]
    }

    private func handleCellTap(on slot: ChekiPairingSlot) {
        // 若開啟了頂部「快速指派成員筆刷」，點擊卡片直接將該卡片指派給筆刷選中的成員
        if isMemberBrushMode, let brushMember = activeBrushMember {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.2)) {
                setMember(brushMember, forSlotID: slot.id)
            }
            return
        }

        // 若為單面卡片且非「直接執行」模式，點擊可進行手動正反配對
        if !slot.isPaired && pairingMode != .singleOnly {
            handleManualTap(on: slot)
        }
    }

    private func applyPairingMode(_ mode: BatchPairingMode) {
        selectedFirstSlotID = nil
        let orderedPhotos = collectAllPhotosInOrder()
        guard !orderedPhotos.isEmpty else {
            slots = []
            return
        }

        switch mode {
        case .singleOnly:
            slots = orderedPhotos.enumerated().map { (idx, photo) in
                ChekiPairingSlot(
                    id: UUID(),
                    frontPhoto: photo,
                    backPhoto: nil,
                    assignedMember: resolvedMember(for: photo, slotIndex: idx)
                )
            }

        case .autoPair:
            var newSlots: [ChekiPairingSlot] = []
            var idx = 0
            var pairIdx = 0
            while idx < orderedPhotos.count {
                let first = orderedPhotos[idx]
                let member = resolvedMember(for: first, slotIndex: pairIdx)
                if idx + 1 < orderedPhotos.count {
                    let second = orderedPhotos[idx + 1]
                    newSlots.append(
                        ChekiPairingSlot(
                            id: UUID(),
                            frontPhoto: first,
                            backPhoto: second,
                            assignedMember: member
                        )
                    )
                    idx += 2
                } else {
                    newSlots.append(
                        ChekiPairingSlot(
                            id: UUID(),
                            frontPhoto: first,
                            backPhoto: nil,
                            assignedMember: member
                        )
                    )
                    idx += 1
                }
                pairIdx += 1
            }
            slots = newSlots

        case .manualPair:
            if slots.isEmpty {
                slots = orderedPhotos.enumerated().map { (idx, photo) in
                    ChekiPairingSlot(
                        id: UUID(),
                        frontPhoto: photo,
                        backPhoto: nil,
                        assignedMember: resolvedMember(for: photo, slotIndex: idx)
                    )
                }
            }
        }
    }

    /// 一鍵自動處理所有異常：雙正面自動拆為 2 張獨立單面；正反顛倒自動對調
    private func resolveAllWarningsAutomatically() {
        var resolved: [ChekiPairingSlot] = []
        for slot in slots {
            if slot.isDoubleFrontWarning, let backPhoto = slot.backPhoto {
                let secondMember = photoMemberAssignment[backPhoto.id] ?? slot.assignedMember
                resolved.append(
                    ChekiPairingSlot(
                        id: UUID(),
                        frontPhoto: slot.frontPhoto,
                        backPhoto: nil,
                        assignedMember: slot.assignedMember
                    )
                )
                resolved.append(
                    ChekiPairingSlot(
                        id: UUID(),
                        frontPhoto: backPhoto,
                        backPhoto: nil,
                        assignedMember: secondMember
                    )
                )
            } else if slot.isReversedOrderWarning, let backPhoto = slot.backPhoto {
                resolved.append(
                    ChekiPairingSlot(
                        id: slot.id,
                        frontPhoto: backPhoto,
                        backPhoto: slot.frontPhoto,
                        assignedMember: slot.assignedMember
                    )
                )
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
        let currentMember = slots[index].assignedMember
        let backMember = photoMemberAssignment[backPhoto.id] ?? currentMember

        let slotA = ChekiPairingSlot(id: UUID(), frontPhoto: frontPhoto, backPhoto: nil, assignedMember: currentMember)
        let slotB = ChekiPairingSlot(id: UUID(), frontPhoto: backPhoto, backPhoto: nil, assignedMember: backMember)

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
            let member = slots[firstIndex].assignedMember ?? slots[secondIndex].assignedMember
            let combinedSlot = ChekiPairingSlot(
                id: UUID(),
                frontPhoto: frontPhoto,
                backPhoto: backPhoto,
                assignedMember: member
            )

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

    // MARK: - 8. 載入 PhotosPicker 相片與 Apple Vision 正反面特徵分析

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
            if let fallback = defaultFallbackMember {
                photoMemberAssignment[staging.id] = fallback
            }
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

    // MARK: - 9. 豐富擬真測試資料集（8 張涵蓋多位不同成員、正反撲克牌配對、⚠️ 雙正面防呆警示、⚠️ 正反顛倒）

    private func loadSimulatedBatchSample() {
        let sampleSpecs: [(seq: Int, title: String, side: DetectedPhotoSide, note: String, colors: [UIColor], isBackLook: Bool, dateText: String, memberIdx: Int)] = [
            // Pair 1 (成員 0): 正常正反配對 (#1 正面 + #2 背面)
            (1, "夏巡舞台服特寫", .likelyFront, "Vision 偵測到正面人物主體", [.systemIndigo, .systemPink], false, "2026.09.24", 0),
            (2, "夏巡簽名背面",   .likelyBack,  "Vision 偵測到 instax 背面標記", [.darkGray, .black], true, "2026.09.24", 0),
            // Pair 2 (成員 1 & 2): ⚠️ 雙正面防呆警示案例 (#3 正面 + #4 正面，拆開後各自歸屬不同成員)
            (3, "浴衣造型正面",   .likelyFront, "Vision 偵測到正面人物主體", [.systemTeal, .systemBlue], false, "2026.09.28", 1),
            (4, "生誕祭私服正面", .likelyFront, "Vision 偵測到正面人物主體", [.systemOrange, .systemPink], false, "2026.09.29", 2),
            // Pair 3 (成員 2): ⚠️ 正反順序顛倒警示案例 (#5 背面 + #6 正面)
            (5, "握手會背面留言", .likelyBack,  "Vision 偵測到 instax 背面標記", [.systemGray, .darkGray], true, "2026.10.02", 2),
            (6, "握手會比愛心正面", .likelyFront, "Vision 偵測到正面人物主體", [.systemPurple, .systemIndigo], false, "2026.10.02", 2),
            // Pair 4 (成員 3): 正常正反配對 (#7 正面 + #8 背面)
            (7, "五週年紀念服正面", .likelyFront, "Vision 偵測到正面人物主體", [.systemPink, .systemRed], false, "2026.10.05", 3),
            (8, "五週年感謝留言背面", .likelyBack, "Vision 偵測到 instax 背面標記", [.darkGray, .systemIndigo], true, "2026.10.05", 3)
        ]

        var generated: [StagingChekiPhoto] = []
        var assignments: [UUID: IdolMember] = [:]

        for spec in sampleSpecs {
            let img = Self.renderSampleChekiImage(
                sequence: spec.seq,
                title: spec.title,
                colors: spec.colors,
                isBackside: spec.isBackLook,
                dateText: spec.dateText
            )
            let data = img.jpegData(compressionQuality: 0.9) ?? Data()
            let photoID = UUID()
            if !idolMembers.isEmpty {
                assignments[photoID] = idolMembers[spec.memberIdx % idolMembers.count]
            }
            generated.append(
                StagingChekiPhoto(
                    id: photoID,
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
            isUsingSimulatedSample = true
            photoMemberAssignment = assignments
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
            cg.setFillColor(UIColor(white: isBackside ? 0.16 : 0.98, alpha: 1.0).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            let innerRect = CGRect(x: 40, y: 52, width: 460, height: 616)
            cg.saveGState()
            cg.addRect(innerRect)
            cg.clip()

            let cgColors = colors.map {
                isBackside ? $0.withAlphaComponent(0.35).cgColor : $0.cgColor
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
                cg.setFillColor(UIColor.white.withAlphaComponent(0.28).cgColor)
                cg.fillEllipse(in: CGRect(x: 195, y: 170, width: 150, height: 150))
                cg.fillEllipse(in: CGRect(x: 120, y: 340, width: 300, height: 280))
            } else {
                let backAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                NSAttributedString(string: "いつもありがとう！♡\nまた来週のライブでね", attributes: backAttrs)
                    .draw(in: CGRect(x: 72, y: 220, width: 396, height: 150))

                let instaxAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: UIColor(white: 0.78, alpha: 1.0)
                ]
                NSAttributedString(string: "FUJIFILM instax", attributes: instaxAttrs)
                    .draw(at: CGPoint(x: 165, y: 590))
            }
            cg.restoreGState()

            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .bold),
                .foregroundColor: isBackside ? UIColor(white: 0.85, alpha: 1.0) : UIColor(white: 0.22, alpha: 1.0)
            ]
            NSAttributedString(string: dateText, attributes: dateAttrs)
                .draw(at: CGPoint(x: 56, y: 720))

            let seqAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: isBackside ? UIColor(white: 0.70, alpha: 1.0) : UIColor.secondaryLabel
            ]
            NSAttributedString(string: "#\(sequence) \(title)", attributes: seqAttrs)
                .draw(at: CGPoint(x: 56, y: 765))
        }
    }

    // MARK: - 10. 執行批次 Vision 透視拉直、OCR 日期辨識與多人分別歸檔儲存

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
            let targetMember = slot.assignedMember

            let newItem = ChekiItem(
                frontImageData: slot.frontPhoto.imageData,
                backImageData: slot.backPhoto?.imageData,
                capturedAt: itemTimestamp,
                filmFormat: selectedFilmFormat,
                detectedAspectRatio: selectedFilmFormat == .auto ? FilmFormat.mini.aspectRatio : selectedFilmFormat.aspectRatio,
                processingState: .detecting,
                idolMember: targetMember
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

            // 3. 若開啟系統相簿同步，依每張拍立得各自指派的 targetMember 分別寫入對應成員相簿 (Task 3.3 & 3.4)
            if autoSyncToPhotos {
                let syncDate = newItem.displayDate
                let albumName = targetMember?.stageName ?? "ChekiLens"
                let folderName = targetMember?.group?.name
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

#Preview("04. 批次配對工作台 (格狀撲克牌展開 + 多人歸檔)") {
    BatchPairingView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}
