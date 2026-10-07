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

// MARK: - StagingChekiPhoto (工作台單張相片暫存項目 — 支援背景預先偵測拍立得邊界、透視裁切預覽與 OCR)

struct StagingChekiPhoto: Identifiable, Equatable {
    let id: UUID
    /// 原始匯入順序編號（從 1 開始）
    var sequenceNumber: Int
    var title: String
    /// 對應 iOS 原生相簿之 `PHAsset.localIdentifier`（確保直接修改原圖不新增重複照片）
    var assetIdentifier: String? = nil
    /// 原始未裁切圖片資料（供事後進入四頂點手動編輯器或復原原圖時保留完整外圍區域）
    var imageData: Data
    var uiImage: UIImage
    var detectedSide: DetectedPhotoSide
    var detectionNote: String

    /// 背景預先偵測邊界並透視拉直後的圖片資料與預覽圖
    var croppedImageData: Data? = nil
    var croppedUIImage: UIImage? = nil
    /// 背景預先偵測出的正規化四頂點座標 JSON (`[TL, TR, BR, BL]`)
    var normalizedCornersJSON: String? = nil
    /// 背景預先辨識出的手寫日期 OCR 結果
    var detectedOCRDate: Date? = nil
    /// 背景預先辨識出的具體相紙規格（Instax Mini / Square / Wide）
    var resolvedFilmFormat: FilmFormat = .mini
    /// 是否正在背景執行邊界偵測
    var isDetectingBoundary: Bool = false
    /// 是否已完成背景邊界偵測
    var hasCompletedBoundaryDetection: Bool = false
    /// 使用者是否選擇復原為原始未裁切圖片
    var isRevertedToOriginal: Bool = false

    /// 工作台卡片優先顯示已裁切預覽圖；若已選擇復原原圖或尚在背景偵測中則顯示原圖
    var displayUIImage: UIImage {
        if isRevertedToOriginal {
            return uiImage
        }
        return croppedUIImage ?? uiImage
    }

    static func == (lhs: StagingChekiPhoto, rhs: StagingChekiPhoto) -> Bool {
        lhs.id == rhs.id &&
        lhs.sequenceNumber == rhs.sequenceNumber &&
        lhs.title == rhs.title &&
        lhs.assetIdentifier == rhs.assetIdentifier &&
        lhs.detectedSide == rhs.detectedSide &&
        lhs.detectionNote == rhs.detectionNote &&
        lhs.isDetectingBoundary == rhs.isDetectingBoundary &&
        lhs.hasCompletedBoundaryDetection == rhs.hasCompletedBoundaryDetection &&
        lhs.isRevertedToOriginal == rhs.isRevertedToOriginal &&
        lhs.normalizedCornersJSON == rhs.normalizedCornersJSON &&
        lhs.detectedOCRDate == rhs.detectedOCRDate &&
        lhs.resolvedFilmFormat == rhs.resolvedFilmFormat &&
        lhs.croppedImageData?.count == rhs.croppedImageData?.count
    }
}

// MARK: - ChekiPairingSlot (配對工作台中的一筆輸出單元：支援個別指派成員、正反雙面撲克牌展開或單面)

struct ChekiPairingSlot: Identifiable, Equatable {
    let id: UUID
    var frontPhoto: StagingChekiPhoto
    var backPhoto: StagingChekiPhoto?
    /// 每張（或每組）拍立得可獨立指派 1 至多位歸檔成員（支援多人合照或同一批上傳不同人的拍立得）
    var assignedMembers: [IdolMember]

    var assignedMember: IdolMember? {
        get { assignedMembers.first }
        set {
            if let member = newValue {
                assignedMembers = [member]
            } else {
                assignedMembers = []
            }
        }
    }

    init(
        id: UUID,
        frontPhoto: StagingChekiPhoto,
        backPhoto: StagingChekiPhoto?,
        assignedMembers: [IdolMember] = []
    ) {
        self.id = id
        self.frontPhoto = frontPhoto
        self.backPhoto = backPhoto
        self.assignedMembers = assignedMembers
    }

    init(
        id: UUID,
        frontPhoto: StagingChekiPhoto,
        backPhoto: StagingChekiPhoto?,
        assignedMember: IdolMember?
    ) {
        self.id = id
        self.frontPhoto = frontPhoto
        self.backPhoto = backPhoto
        self.assignedMembers = assignedMember.map { [$0] } ?? []
    }

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
        lhs.assignedMembers.map(\.id) == rhs.assignedMembers.map(\.id)
    }
}

// MARK: - BatchPairingView (Task 4.4: 批次配對工作台 — 格狀相簿檢視 + 撲克牌正反展開 + 多層多選成員歸檔設定)

/// 批次相簿匯入與正反面配對工作台
/// - 採用與相簿一覽相同的 **格狀檢視 (`LazyVGrid`)**
/// - 正反雙面配對項目採用 **撲克牌兩張扇形展開樣式 (`Playing-Card Fan`)**，直覺呈現正反疊合關係
/// - 支援 **多層選擇 Multiple Select（團體 ➔ 成員，最後可新增成員）**，並提供 **「全部套用」** 與 **「選擇套用（多選照片後確認一次套用）」**
struct BatchPairingView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var existingChekiItems: [ChekiItem]
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]
    @AppStorage("hasSeenBatchPairingCoachMark") private var hasSeenCoachMark: Bool = false
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = false
    @AppStorage("defaultBorderInsetPercentage") private var defaultBorderInsetPercentage: Double = 0.0

    let initialPickerItems: [PhotosPickerItem]
    let defaultMember: IdolMember?

    @State private var pairingMode: BatchPairingMode = .autoPair
    @State private var allPhotos: [StagingChekiPhoto] = []
    @State private var slots: [ChekiPairingSlot] = []

    /// 記錄每張相片已指派的成員清單（切換配對模式或拆開/重組時保留各自的成員設定）
    @State private var photoMemberAssignment: [UUID: [IdolMember]] = [:]

    /// 上方「歸檔成員」多層選擇 (Multiple Select) 當前勾選的目標成員清單
    @State private var selectedTargetMembers: [IdolMember] = []

    /// 「選擇套用」模式：開啟後可多選下方拍立得卡片，再按「確認套用」一次套用所選成員
    @State private var isSelectingPhotosToApply: Bool = false
    @State private var selectedSlotIDsForApply: Set<UUID> = []

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

    /// 已在背景完成拍立得邊界偵測與預裁切的照片數量
    private var boundaryDetectedPhotoCount: Int {
        allPhotos.filter(\.hasCompletedBoundaryDetection).count
    }

    /// 是否所有匯入照片皆已在背景完成拍立得邊界偵測與透視預裁切
    private var allBoundariesDetected: Bool {
        !allPhotos.isEmpty && boundaryDetectedPhotoCount == allPhotos.count
    }

    /// 上方多層多選成員選擇器目前選中的成員摘要字串
    private var selectedTargetMembersDisplayString: String {
        if selectedTargetMembers.isEmpty {
            return "未分類"
        } else if selectedTargetMembers.count == 1 {
            return selectedTargetMembers[0].stageName
        } else if selectedTargetMembers.count == 2 {
            return "\(selectedTargetMembers[0].stageName)、\(selectedTargetMembers[1].stageName)"
        } else {
            return "\(selectedTargetMembers[0].stageName)、\(selectedTargetMembers[1].stageName) 等 \(selectedTargetMembers.count) 人"
        }
    }

    /// 目前所有卡片涵蓋的不同成員摘要（例如：「遠藤さくら、河田陽菜 等 3 人」）
    private var assignedMembersSummary: String {
        var uniqueNames: [String] = []
        var hasUncategorized = false
        for slot in slots {
            if slot.assignedMembers.isEmpty {
                hasUncategorized = true
            } else {
                for member in slot.assignedMembers {
                    if !uniqueNames.contains(member.stageName) {
                        uniqueNames.append(member.stageName)
                    }
                }
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
                            preferredItemEncoding: .automatic,
                            photoLibrary: .shared()
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
                                        systemPhotoSeedAlertMessage = "已成功將 \(count) 張帶封面手寫日期的拍立得相片寫入 iOS 原生相簿 (Photos.app)。\n\n現在可點選上方「＋」直接從系統相簿選取這 \(count) 張相片進行導入與自動日期判斷測試！"
                                    } catch {
                                        systemPhotoSeedAlertMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Label("寫入 10 張帶日期拍立得至系統相簿 (Photos.app)", systemImage: "photo.badge.plus")
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
                                        isSelectingPhotosToApply = false
                                        selectedSlotIDsForApply.removeAll()
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
            .onChange(of: idolMembers.count) { oldCount, newCount in
                // 當使用者透過「新增成員」建立新成員後，自動將最新建立的成員加入上方多選目標中
                if newCount > oldCount, let newestMember = idolMembers.last {
                    if !selectedTargetMembers.contains(where: { $0.id == newestMember.id }) {
                        selectedTargetMembers.append(newestMember)
                    }
                }
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
                if selectedTargetMembers.isEmpty, let initialTarget = defaultFallbackMember {
                    selectedTargetMembers = [initialTarget]
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
            .onChange(of: selectedFilmFormat) { _, newFormat in
                Task {
                    await reapplyFilmFormatInBackground(newFormat)
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
                    // 1. 多人歸檔成員（多層選擇 Multiple Select + 全部套用 / 選擇套用）與相紙規格設定卡
                    multiMemberAndFormatHeaderCard

                    // 2. Vision 防呆警示橫幅（若有雙正面或正反顛倒）
                    if totalWarningCount > 0 {
                        warningBannerCard
                    }

                    // 3. 「選擇套用（多選照片）」或「手動配對」指引列
                    if isSelectingPhotosToApply {
                        photoMultiSelectApplyBanner
                    } else if pairingMode == .manualPair || selectedFirstSlotID != nil {
                        manualPairingInstructionBanner
                    }

                    // 4. 格狀標題列
                    HStack {
                        Text("已選取 \(allPhotos.count) 張照片 · 將輸出 \(slots.count) 張拍立得")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if isSelectingPhotosToApply {
                            Text("已勾選 \(selectedSlotIDsForApply.count) / \(slots.count) 張")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.blue)
                        } else if isAnalyzingSides || !allBoundariesDetected {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("背景偵測邊界 (\(boundaryDetectedPhotoCount)/\(allPhotos.count))")
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                                Text("已完成邊界預裁切")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
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

    // MARK: - 2. 多層多選歸檔成員與規格設定卡 (Hierarchical Multiple-Select + Apply All / Select to Apply)

    private var multiMemberAndFormatHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 第一列：左側「歸檔成員」標題 ＋ 右側「全部套用」&「選擇套用」按鈕（保留充足寬度不截斷）
            HStack(spacing: 8) {
                Label("歸檔成員", systemImage: "person.2.crop.square.stack")
                    .font(.subheadline.weight(.medium))

                Spacer()

                // 1. 全部套用按鈕
                Button {
                    applyTargetMembersToAllSlots()
                } label: {
                    Text("全部套用")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)

                // 2. 選擇套用按鈕（緊接在「全部套用」後面：開啟照片多選模式，選完照片後確認一次套用）
                Button {
                    togglePhotoSelectionApplyMode()
                } label: {
                    Text(isSelectingPhotosToApply ? "取消選擇" : "選擇套用")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelectingPhotosToApply ? .white : .blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(
                            isSelectingPhotosToApply
                                ? AnyShapeStyle(Color.blue)
                                : AnyShapeStyle(Color.blue.opacity(0.14)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            // 第二列：成員選擇移至下方
            // - 沒有選擇時：顯示「選擇成員 ⌄」下拉選單膠囊
            // - 有選擇時：每個已選成員顯示為下拉選單膠囊框（直接點選可用多層下拉選單重選成員，右邊保持 X 按鈕取消），後面接著未選擇的下拉選單（可多選追加）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(selectedTargetMembers.enumerated()), id: \.element.id) { index, member in
                        selectedMemberDropdownCapsule(member: member, index: index)
                    }

                    // 後方接著未選擇的多層下拉選單膠囊（未選擇時作為主選單，已選擇時可繼續多選追加成員）
                    unselectedMemberDropdownCapsule
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

    /// 已選中的成員下拉膠囊框：直接點選膠囊本體可用多層下拉選單重選該成員，右側保持 `X` 按鈕可取消移除
    private func selectedMemberDropdownCapsule(member: IdolMember, index: Int) -> some View {
        HStack(spacing: 2) {
            // 左側主體：點選開啟多層下拉選單（團體 ➔ 成員 ➔ 新增成員）直接重選／替換此位置的成員
            Menu {
                memberHierarchyMenuContent(replacingAt: index)
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Self.groupColor(for: member))
                        .frame(width: 8, height: 8)

                    Text(member.stageName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: true, vertical: false)

                    if let groupName = member.group?.name {
                        Text(groupName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 右側：保持 X 按鈕取消該成員
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.2)) {
                    selectedTargetMembers.removeAll { $0.id == member.id }
                    defaultFallbackMember = selectedTargetMembers.first
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除\(member.stageName)")
        }
        .background(Color(.tertiarySystemFill), in: Capsule())
    }

    /// 未選擇的成員多層下拉選單膠囊（沒有選擇任何成員時顯示「未分類 · 選擇成員」，已有選擇時緊接在後方供多選追加）
    private var unselectedMemberDropdownCapsule: some View {
        Menu {
            memberHierarchyMenuContent(replacingAt: nil)
        } label: {
            HStack(spacing: 5) {
                if selectedTargetMembers.isEmpty {
                    Image(systemName: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("未分類 · 選擇成員")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("選擇成員")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 多層級成員選單內容（第一層：團體 ➔ 第二層：成員，最後可新增成員）
    /// - Parameter replacingAt: 若為 `Int` 代表重選並替換該索引的膠囊成員；若為 `nil` 代表在後方追加新成員
    @ViewBuilder
    private func memberHierarchyMenuContent(replacingAt index: Int?) -> some View {
        let ungroupedMembers = idolMembers.filter { $0.group == nil }
        let currentMemberAtSlot: IdolMember? = {
            if let idx = index, selectedTargetMembers.indices.contains(idx) {
                return selectedTargetMembers[idx]
            }
            return nil
        }()

        Section(index != nil ? "重新選擇成員" : "選擇成員（可多選）") {
            ForEach(idolGroups) { group in
                let groupMembers = idolMembers.filter { $0.group?.id == group.id }
                if !groupMembers.isEmpty {
                    Menu(group.name) {
                        ForEach(groupMembers) { member in
                            let isCurrent = (currentMemberAtSlot?.id == member.id)
                            let isAlreadyInList = selectedTargetMembers.contains(where: { $0.id == member.id })
                            Button {
                                selectTargetMember(member, replacingAt: index)
                            } label: {
                                Label(
                                    member.stageName,
                                    systemImage: isCurrent
                                        ? "checkmark.circle.fill"
                                        : (isAlreadyInList ? "checkmark" : "person")
                                )
                            }
                        }
                    }
                }
            }

            if !ungroupedMembers.isEmpty {
                Menu("未分團成員") {
                    ForEach(ungroupedMembers) { member in
                        let isCurrent = (currentMemberAtSlot?.id == member.id)
                        let isAlreadyInList = selectedTargetMembers.contains(where: { $0.id == member.id })
                        Button {
                            selectTargetMember(member, replacingAt: index)
                        } label: {
                            Label(
                                member.stageName,
                                systemImage: isCurrent
                                    ? "checkmark.circle.fill"
                                    : (isAlreadyInList ? "checkmark" : "person")
                            )
                        }
                    }
                }
            }
        }

        if let idx = index {
            Divider()
            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.2)) {
                    if selectedTargetMembers.indices.contains(idx) {
                        selectedTargetMembers.remove(at: idx)
                        defaultFallbackMember = selectedTargetMembers.first
                    }
                }
            } label: {
                Label("移除此成員", systemImage: "xmark.circle")
            }
        } else if !selectedTargetMembers.isEmpty {
            Divider()
            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.2)) {
                    selectedTargetMembers.removeAll()
                    defaultFallbackMember = nil
                }
            } label: {
                Label("清空所有已選成員（設為未分類）", systemImage: "tray")
            }
        }

        Divider()

        // 最後一項：新增成員
        Button {
            showingQuickCreateMemberSheet = true
        } label: {
            Label("新增成員…", systemImage: "person.badge.plus")
        }
    }

    // MARK: - 3. 格狀卡片單元：撲克牌兩張展開樣式 (Playing-Card Fan) & 單張直立樣式

    @ViewBuilder
    private func slotGridCell(for slot: ChekiPairingSlot) -> some View {
        let isSelectedFirst = (selectedFirstSlotID == slot.id)
        let isSelectedForMemberApply = isSelectingPhotosToApply && selectedSlotIDsForApply.contains(slot.id)
        let hasWarning = slot.isDoubleFrontWarning || slot.isReversedOrderWarning

        let borderColor: Color = {
            if isSelectedForMemberApply || isSelectedFirst {
                return .blue
            } else if hasWarning {
                return .orange.opacity(0.85)
            } else {
                return .primary.opacity(0.06)
            }
        }()
        let borderWidth: CGFloat = (isSelectedForMemberApply || isSelectedFirst || hasWarning) ? 2.2 : 1.0

        VStack(spacing: 8) {
            // 上方視覺舞台：若為正反雙面則呈現「撲克牌兩張扇形展開」，若為單面則呈現單張拍立得
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isSelectedForMemberApply
                            ? Color.blue.opacity(0.10)
                            : Color(.secondarySystemGroupedBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: borderWidth)
                    )

                if slot.isPaired, let backPhoto = slot.backPhoto {
                    playingCardFanView(slot: slot, frontPhoto: slot.frontPhoto, backPhoto: backPhoto)
                } else {
                    singleCardStageView(slot: slot, photo: slot.frontPhoto, isSelectedFirst: isSelectedFirst)
                }

                // 當處於「選擇套用（多選照片）」模式時，在卡片右上角顯示清晰的勾選圓圈角標
                if isSelectingPhotosToApply {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: isSelectedForMemberApply ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(isSelectedForMemberApply ? .blue : .white.opacity(0.85))
                                .background(
                                    Circle()
                                        .fill(isSelectedForMemberApply ? Color.white : Color.black.opacity(0.35))
                                        .padding(2)
                                )
                                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
                        }
                        .padding(8)
                        Spacer()
                    }
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

            // 下方：每張（或每組）拍立得獨立的「多層多選歸檔成員膠囊」
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
            // 1. 右後扇形展開：背面卡片 (Back Card — 向右旋轉展開如撲克牌，優先顯示背景已裁切預覽圖)
            ZStack(alignment: .topTrailing) {
                Image(uiImage: backPhoto.displayUIImage)
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

            // 2. 左前扇形展開：正面卡片 (Front Card — 向左微傾疊於前側，優先顯示背景已裁切預覽圖)
            ZStack(alignment: .topLeading) {
                Image(uiImage: frontPhoto.displayUIImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.2)
                    )
                    .shadow(color: .black.opacity(0.32), radius: 9, x: 4, y: 4)

                HStack(spacing: 3) {
                    Text("正面")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                    if frontPhoto.isDetectingBoundary || backPhoto.isDetectingBoundary {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.88), in: Capsule())
                .padding(5)
            }
            .rotationEffect(.degrees(-8), anchor: .bottom)
            .offset(x: -16, y: 0)

            // 3. 頂部左右控制角標：左側序號 (#1+#2)，右側一鍵「拆開」按鈕（照片多選模式時隱藏拆開鈕以免誤觸）
            VStack {
                HStack {
                    Text("#\(frontPhoto.sequenceNumber)+#\(backPhoto.sequenceNumber)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())

                    Spacer()

                    if !isSelectingPhotosToApply {
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
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Spacer()

                // 4. 底部中央：撲克牌交疊處的「⇄ 對調正反」或異常提示膠囊
                if !isSelectingPhotosToApply {
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
    }

    /// 單張直立拍立得樣式 (Single Card Stage — 優先顯示背景已裁切預覽圖)
    private func singleCardStageView(
        slot: ChekiPairingSlot,
        photo: StagingChekiPhoto,
        isSelectedFirst: Bool
    ) -> some View {
        ZStack {
            Image(uiImage: photo.displayUIImage)
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

                    if !isSelectingPhotosToApply {
                        HStack(spacing: 3) {
                            if photo.isDetectingBoundary {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white)
                                    .scaleEffect(0.7)
                            }
                            Text(photo.detectedSide.rawValue)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            photo.detectedSide == .likelyBack ? Color.purple.opacity(0.85) : Color.black.opacity(0.58),
                            in: Capsule()
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Spacer()

                if pairingMode != .singleOnly && !isSelectingPhotosToApply {
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

    /// 每組拍立得卡片正下方的「多層多選成員膠囊」(支援依團體 ➔ 成員複選，最後可新增成員)
    private func perSlotMemberSelectorPill(for slot: ChekiPairingSlot) -> some View {
        let ungroupedMembers = idolMembers.filter { $0.group == nil }

        return Menu {
            Section("指派此張拍立得的歸檔成員（可複選）") {
                ForEach(idolGroups) { group in
                    let groupMembers = idolMembers.filter { $0.group?.id == group.id }
                    if !groupMembers.isEmpty {
                        Menu(group.name) {
                            ForEach(groupMembers) { member in
                                let isAssigned = slot.assignedMembers.contains(where: { $0.id == member.id })
                                Button {
                                    toggleMember(member, forSlotID: slot.id)
                                } label: {
                                    Label(
                                        member.stageName,
                                        systemImage: isAssigned ? "checkmark.circle.fill" : "circle"
                                    )
                                }
                                .menuActionDismissBehavior(.disabled)
                            }
                        }
                    }
                }

                if !ungroupedMembers.isEmpty {
                    Menu("未分團成員") {
                        ForEach(ungroupedMembers) { member in
                            let isAssigned = slot.assignedMembers.contains(where: { $0.id == member.id })
                            Button {
                                toggleMember(member, forSlotID: slot.id)
                            } label: {
                                Label(
                                    member.stageName,
                                    systemImage: isAssigned ? "checkmark.circle.fill" : "circle"
                                )
                            }
                            .menuActionDismissBehavior(.disabled)
                        }
                    }
                }
            }

            Divider()

            Button {
                setMembers([], forSlotID: slot.id)
            } label: {
                Label("設為「未分類」", systemImage: slot.assignedMembers.isEmpty ? "checkmark" : "tray")
            }

            Divider()

            Button {
                showingQuickCreateMemberSheet = true
            } label: {
                Label("新增成員…", systemImage: "person.badge.plus")
            }
        } label: {
            HStack(spacing: 6) {
                if let primary = slot.assignedMembers.first {
                    Circle()
                        .fill(Self.groupColor(for: primary))
                        .frame(width: 8, height: 8)

                    if slot.assignedMembers.count == 1 {
                        Text(primary.stageName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let groupName = primary.group?.name {
                            Text(groupName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        let names = slot.assignedMembers.map(\.stageName).joined(separator: "、")
                        Text(names)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
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
            ForEach(idolGroups) { group in
                let groupMembers = idolMembers.filter { $0.group?.id == group.id }
                if !groupMembers.isEmpty {
                    Menu(group.name) {
                        ForEach(groupMembers) { member in
                            let isAssigned = slot.assignedMembers.contains(where: { $0.id == member.id })
                            Button {
                                toggleMember(member, forSlotID: slot.id)
                            } label: {
                                Label(member.stageName, systemImage: isAssigned ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                setMembers([], forSlotID: slot.id)
            } label: {
                Label("未分類", systemImage: slot.assignedMembers.isEmpty ? "checkmark" : "tray")
            }
            Button {
                showingQuickCreateMemberSheet = true
            } label: {
                Label("新增成員…", systemImage: "person.badge.plus")
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

        if slot.frontPhoto.croppedImageData != nil {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    togglePhotoRevertToOriginal(photoID: slot.frontPhoto.id)
                }
            } label: {
                Label(
                    slot.frontPhoto.isRevertedToOriginal ? "套用自動邊界裁切" : "復原為原始未裁切圖片",
                    systemImage: slot.frontPhoto.isRevertedToOriginal ? "crop" : "arrow.uturn.backward.circle"
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

    private func togglePhotoRevertToOriginal(photoID: UUID) {
        if let idx = allPhotos.firstIndex(where: { $0.id == photoID }) {
            allPhotos[idx].isRevertedToOriginal.toggle()
        }
        for i in slots.indices {
            if slots[i].frontPhoto.id == photoID {
                slots[i].frontPhoto.isRevertedToOriginal.toggle()
            }
            if slots[i].backPhoto?.id == photoID {
                slots[i].backPhoto?.isRevertedToOriginal.toggle()
            }
        }
    }

    // MARK: - 4. 警示橫幅與「選擇套用（多選照片）」確認列

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

    /// 「選擇套用」模式橫幅：多選下方拍立得卡片後，按「確認套用」一次套用上方所選成員
    private var photoMultiSelectApplyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.badge.questionmark.fill")
                .font(.subheadline)
                .foregroundStyle(.blue)

            Text("請點選要套用「**\(selectedTargetMembersDisplayString)**」的照片")
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(selectedSlotIDsForApply.count == slots.count ? "取消全選" : "全選") {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.snappy(duration: 0.2)) {
                    if selectedSlotIDsForApply.count == slots.count {
                        selectedSlotIDsForApply.removeAll()
                    } else {
                        selectedSlotIDsForApply = Set(slots.map(\.id))
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button("確認套用(\(selectedSlotIDsForApply.count)張)") {
                confirmApplyTargetMembersToSelectedSlots()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .disabled(selectedSlotIDsForApply.isEmpty)
        }
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    preferredItemEncoding: .automatic,
                    photoLibrary: .shared()
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
        VStack(spacing: 6) {
            HStack {
                Label(
                    "雙面 \(pairedCount) 組 · 單面 \(singleCount) 張",
                    systemImage: "rectangle.portrait.on.rectangle.portrait"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                Spacer()

                if isSelectingPhotosToApply {
                    Text("目標：\(selectedTargetMembersDisplayString)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                } else if totalWarningCount > 0 {
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

            if isSelectingPhotosToApply {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isSelectingPhotosToApply = false
                            selectedSlotIDsForApply.removeAll()
                        }
                    } label: {
                        Text("取消")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        confirmApplyTargetMembersToSelectedSlots()
                    } label: {
                        Text("確認套用(\(selectedSlotIDsForApply.count)張)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selectedSlotIDsForApply.isEmpty ? Color.blue.opacity(0.4) : Color.blue,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedSlotIDsForApply.isEmpty)
                }
            } else {
                Button {
                    Task { await executeBatchProcessing() }
                } label: {
                    HStack(spacing: 6) {
                        if !allBoundariesDetected {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                        }
                        Text(
                            allBoundariesDetected
                                ? "確認歸檔（共 \(slots.count) 張拍立得）"
                                : "背景偵測邊界中 (\(boundaryDetectedPhotoCount)/\(allPhotos.count)) · 點此歸檔"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8.5)
                    .background(
                        (slots.isEmpty || isProcessingBatch) ? Color.blue.opacity(0.4) : Color.blue,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(slots.isEmpty || isProcessingBatch)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
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

    // MARK: - 7. 多層多選成員指派與配對邏輯 (Hierarchical Multi-Select & Photo Batch Apply)

    private func selectTargetMember(_ member: IdolMember, replacingAt index: Int?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.2)) {
            if let idx = index, selectedTargetMembers.indices.contains(idx) {
                // 直接點選已選成員膠囊重選成員：替換該位置的成員，並移除可能重複的項目
                selectedTargetMembers[idx] = member
                for i in selectedTargetMembers.indices.reversed() where i != idx && selectedTargetMembers[i].id == member.id {
                    selectedTargetMembers.remove(at: i)
                }
            } else {
                // 點選後方的「未選擇下拉選單」：追加選擇新成員（可多選用）
                if !selectedTargetMembers.contains(where: { $0.id == member.id }) {
                    selectedTargetMembers.append(member)
                }
            }
            defaultFallbackMember = selectedTargetMembers.first
        }
    }

    private func setMembers(_ members: [IdolMember], forSlotID slotID: UUID) {
        guard let idx = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[idx].assignedMembers = members
        photoMemberAssignment[slots[idx].frontPhoto.id] = members
        if let backID = slots[idx].backPhoto?.id {
            photoMemberAssignment[backID] = members
        }
    }

    private func toggleMember(_ member: IdolMember, forSlotID slotID: UUID) {
        guard let idx = slots.firstIndex(where: { $0.id == slotID }) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        var current = slots[idx].assignedMembers
        if let existingIdx = current.firstIndex(where: { $0.id == member.id }) {
            current.remove(at: existingIdx)
        } else {
            current.append(member)
        }
        setMembers(current, forSlotID: slotID)
    }

    /// 點擊「全部套用」：將上方多層選擇器目前選中的成員清單套用至全部拍立得卡片
    private func applyTargetMembersToAllSlots() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        defaultFallbackMember = selectedTargetMembers.first
        withAnimation(.snappy(duration: 0.22)) {
            for idx in slots.indices {
                slots[idx].assignedMembers = selectedTargetMembers
                photoMemberAssignment[slots[idx].frontPhoto.id] = selectedTargetMembers
                if let backID = slots[idx].backPhoto?.id {
                    photoMemberAssignment[backID] = selectedTargetMembers
                }
            }
            isSelectingPhotosToApply = false
            selectedSlotIDsForApply.removeAll()
        }
    }

    /// 點擊「選擇套用」：切換照片多選模式
    private func togglePhotoSelectionApplyMode() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.22)) {
            isSelectingPhotosToApply.toggle()
            selectedFirstSlotID = nil
            if !isSelectingPhotosToApply {
                selectedSlotIDsForApply.removeAll()
            }
        }
    }

    /// 在「選擇套用」模式下，點選「確認套用」將上方已選成員一次套用至所有勾選的拍立得照片
    private func confirmApplyTargetMembersToSelectedSlots() {
        guard !selectedSlotIDsForApply.isEmpty else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        defaultFallbackMember = selectedTargetMembers.first
        withAnimation(.snappy(duration: 0.24)) {
            for idx in slots.indices where selectedSlotIDsForApply.contains(slots[idx].id) {
                slots[idx].assignedMembers = selectedTargetMembers
                photoMemberAssignment[slots[idx].frontPhoto.id] = selectedTargetMembers
                if let backID = slots[idx].backPhoto?.id {
                    photoMemberAssignment[backID] = selectedTargetMembers
                }
            }
            selectedSlotIDsForApply.removeAll()
            isSelectingPhotosToApply = false
        }
    }

    private func resolvedMembers(for photo: StagingChekiPhoto, slotIndex: Int) -> [IdolMember] {
        if let existing = photoMemberAssignment[photo.id] {
            return existing
        }
        if !selectedTargetMembers.isEmpty {
            return selectedTargetMembers
        }
        if let defaultMember = defaultFallbackMember {
            return [defaultMember]
        }
        guard !idolMembers.isEmpty else { return [] }
        return [idolMembers[slotIndex % idolMembers.count]]
    }

    private func handleCellTap(on slot: ChekiPairingSlot) {
        // 1. 若處於「選擇套用（多選照片）」模式，點擊卡片即勾選 / 取消勾選該張拍立得
        if isSelectingPhotosToApply {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.18)) {
                if selectedSlotIDsForApply.contains(slot.id) {
                    selectedSlotIDsForApply.remove(slot.id)
                } else {
                    selectedSlotIDsForApply.insert(slot.id)
                }
            }
            return
        }

        // 2. 若為單面卡片且非「直接執行」模式，點擊可進行手動正反配對
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
                    assignedMembers: resolvedMembers(for: photo, slotIndex: idx)
                )
            }

        case .autoPair:
            var newSlots: [ChekiPairingSlot] = []
            var idx = 0
            var pairIdx = 0
            while idx < orderedPhotos.count {
                let first = orderedPhotos[idx]
                let members = resolvedMembers(for: first, slotIndex: pairIdx)
                if idx + 1 < orderedPhotos.count {
                    let second = orderedPhotos[idx + 1]
                    newSlots.append(
                        ChekiPairingSlot(
                            id: UUID(),
                            frontPhoto: first,
                            backPhoto: second,
                            assignedMembers: members
                        )
                    )
                    idx += 2
                } else {
                    newSlots.append(
                        ChekiPairingSlot(
                            id: UUID(),
                            frontPhoto: first,
                            backPhoto: nil,
                            assignedMembers: members
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
                        assignedMembers: resolvedMembers(for: photo, slotIndex: idx)
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
                let secondMembers = photoMemberAssignment[backPhoto.id] ?? slot.assignedMembers
                resolved.append(
                    ChekiPairingSlot(
                        id: UUID(),
                        frontPhoto: slot.frontPhoto,
                        backPhoto: nil,
                        assignedMembers: slot.assignedMembers
                    )
                )
                resolved.append(
                    ChekiPairingSlot(
                        id: UUID(),
                        frontPhoto: backPhoto,
                        backPhoto: nil,
                        assignedMembers: secondMembers
                    )
                )
            } else if slot.isReversedOrderWarning, let backPhoto = slot.backPhoto {
                resolved.append(
                    ChekiPairingSlot(
                        id: slot.id,
                        frontPhoto: backPhoto,
                        backPhoto: slot.frontPhoto,
                        assignedMembers: slot.assignedMembers
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
        let currentMembers = slots[index].assignedMembers
        let backMembers = photoMemberAssignment[backPhoto.id] ?? currentMembers

        let slotA = ChekiPairingSlot(id: UUID(), frontPhoto: frontPhoto, backPhoto: nil, assignedMembers: currentMembers)
        let slotB = ChekiPairingSlot(id: UUID(), frontPhoto: backPhoto, backPhoto: nil, assignedMembers: backMembers)

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
        selectedSlotIDsForApply.remove(id)
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
            let members = !slots[firstIndex].assignedMembers.isEmpty
                ? slots[firstIndex].assignedMembers
                : slots[secondIndex].assignedMembers
            let combinedSlot = ChekiPairingSlot(
                id: UUID(),
                frontPhoto: frontPhoto,
                backPhoto: backPhoto,
                assignedMembers: members
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

    // MARK: - 8. 載入 PhotosPicker 相片與背景預先執行 Vision 正反面分類 + 四頂點邊界偵測 + 透視裁切 + OCR

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
                assetIdentifier: item.itemIdentifier,
                imageData: normalizedData,
                uiImage: normalized,
                detectedSide: .analyzing,
                detectionNote: "Vision 背景偵測邊界中…",
                isDetectingBoundary: true,
                hasCompletedBoundaryDetection: false
            )
            if !selectedTargetMembers.isEmpty {
                photoMemberAssignment[staging.id] = selectedTargetMembers
            } else if let fallback = defaultFallbackMember {
                photoMemberAssignment[staging.id] = [fallback]
            }
            newlyLoaded.append(staging)
            nextSequence += 1
        }

        guard !newlyLoaded.isEmpty else { return }
        allPhotos.append(contentsOf: newlyLoaded)
        applyPairingMode(pairingMode)

        await analyzePhotoSides(for: newlyLoaded.map(\.id))
    }

    /// 在進入工作台頁面時即於背景依序完成：
    /// 1. 正反面特徵分類 (`classifyPhotoSide`)
    /// 2. 拍立得四頂點邊界偵測 (`detectQuad`) 與透視拉直預裁切 (`perspectiveCorrect`)
    /// 3. 手寫日期 OCR (`recognizeDate`)
    /// 完成後即時更新工作台卡片預覽圖，按「確認歸檔」時可直接秒速寫入無須重複等待
    @MainActor
    private func analyzePhotoSides(for targetIDs: [UUID]) async {
        isAnalyzingSides = true
        defer { isAnalyzingSides = false }

        let visionManager = VisionManager()
        let chekiFormat = Self.toChekiFilmFormat(selectedFilmFormat)
        let defaultInsetRatio = defaultBorderInsetPercentage / 100.0

        for photoID in targetIDs {
            guard let photo = findPhoto(by: photoID),
                  let cgImage = photo.uiImage.cgImage else { continue }

            setPhotoDetectingBoundary(id: photoID, isDetecting: true)

            // Step 1: 正反面分類
            let (side, note) = await Self.classifyPhotoSide(cgImage: cgImage)
            updatePhotoSide(id: photoID, side: side, note: note)

            // Step 2: 背景偵測拍立得邊界 + 套用設定邊界微調 + 透視拉直預裁切 + 封面手寫日期 OCR + 規格判定
            let imgSize = CGSize(width: cgImage.width, height: cgImage.height)
            var croppedData: Data? = nil
            var croppedUI: UIImage? = nil
            var cornersJSON: String? = nil
            var ocrDate: Date? = nil
            var resolvedFormat: FilmFormat = selectedFilmFormat.concreteFormat

            if let detection = try? await visionManager.detectQuad(in: cgImage, imageSize: imgSize) {
                let adjustedCorners = await visionManager.applyBorderInset(
                    corners: detection.corners,
                    imageSize: imgSize,
                    ratio: defaultInsetRatio
                )
                if let cropRes = try? await visionManager.perspectiveCorrect(
                    image: cgImage,
                    corners: adjustedCorners,
                    detection: detection,
                    format: chekiFormat
                ) {
                    let uiImg = UIImage(cgImage: cropRes.cgImage)
                    croppedUI = uiImg
                    croppedData = uiImg.jpegData(compressionQuality: 0.92)
                    cornersJSON = ChekiItem.encodeNormalizedCorners(adjustedCorners, imageSize: imgSize)
                    resolvedFormat = FilmFormat.resolvedConcreteFormat(
                        preferred: selectedFilmFormat,
                        specName: cropRes.filmSpecification?.format.rawValue,
                        outputSize: cropRes.outputSize
                    )

                    if let ocrRes = await visionManager.recognizeDate(from: cropRes.cgImage) {
                        ocrDate = ocrRes.date
                    } else if let fallbackOCR = await visionManager.recognizeDate(from: cgImage) {
                        ocrDate = fallbackOCR.date
                    }
                }
            } else {
                if let ocrRes = await visionManager.recognizeDate(from: cgImage) {
                    ocrDate = ocrRes.date
                }
            }

            withAnimation(.snappy(duration: 0.22)) {
                updatePhotoBoundaryResult(
                    id: photoID,
                    croppedData: croppedData,
                    croppedImage: croppedUI,
                    cornersJSON: cornersJSON,
                    ocrDate: ocrDate,
                    resolvedFormat: resolvedFormat
                )
            }
        }
    }

    /// 當使用者在工作台上方切換「相紙規格」時，背景利用已偵測到的四頂點座標快速重新套用比例鎖定
    @MainActor
    private func reapplyFilmFormatInBackground(_ format: FilmFormat) async {
        let visionManager = VisionManager()
        let chekiFormat = Self.toChekiFilmFormat(format)

        for photo in allPhotos {
            guard let cornersJSON = photo.normalizedCornersJSON,
                  let normCorners = ChekiItem.decodeNormalizedCorners(from: cornersJSON),
                  let cgImage = photo.uiImage.cgImage else { continue }

            let imgSize = CGSize(width: cgImage.width, height: cgImage.height)
            let pixelCorners = normCorners.map { pt in
                CGPoint(x: pt.x * imgSize.width, y: pt.y * imgSize.height)
            }
            let detection = DetectionResult(
                corners: pixelCorners,
                method: .visionNative,
                confidence: 1.0,
                imageSize: imgSize
            )
            if let cropRes = try? await visionManager.perspectiveCorrect(
                image: cgImage,
                corners: pixelCorners,
                detection: detection,
                format: chekiFormat
            ) {
                let uiImg = UIImage(cgImage: cropRes.cgImage)
                let jpeg = uiImg.jpegData(compressionQuality: 0.92)
                let resolvedFormat = FilmFormat.resolvedConcreteFormat(
                    preferred: format,
                    specName: cropRes.filmSpecification?.format.rawValue,
                    outputSize: cropRes.outputSize
                )
                withAnimation(.snappy(duration: 0.2)) {
                    updatePhotoBoundaryResult(
                        id: photo.id,
                        croppedData: jpeg,
                        croppedImage: uiImg,
                        cornersJSON: cornersJSON,
                        ocrDate: photo.detectedOCRDate,
                        resolvedFormat: resolvedFormat
                    )
                }
            }
        }
    }

    private static func toChekiFilmFormat(_ format: FilmFormat) -> ChekiFilmFormat {
        switch format {
        case .mini: return .mini
        case .square: return .square
        case .wide: return .wide
        case .auto: return .auto
        }
    }

    private func findPhoto(by id: UUID) -> StagingChekiPhoto? {
        for slot in slots {
            if slot.frontPhoto.id == id { return slot.frontPhoto }
            if let back = slot.backPhoto, back.id == id { return back }
        }
        return allPhotos.first { $0.id == id }
    }

    private func setPhotoDetectingBoundary(id: UUID, isDetecting: Bool) {
        if let idx = allPhotos.firstIndex(where: { $0.id == id }) {
            allPhotos[idx].isDetectingBoundary = isDetecting
        }
        for i in slots.indices {
            if slots[i].frontPhoto.id == id {
                slots[i].frontPhoto.isDetectingBoundary = isDetecting
            }
            if slots[i].backPhoto?.id == id {
                slots[i].backPhoto?.isDetectingBoundary = isDetecting
            }
        }
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

    private func updatePhotoBoundaryResult(
        id: UUID,
        croppedData: Data?,
        croppedImage: UIImage?,
        cornersJSON: String?,
        ocrDate: Date?,
        resolvedFormat: FilmFormat = .mini
    ) {
        if let idx = allPhotos.firstIndex(where: { $0.id == id }) {
            allPhotos[idx].croppedImageData = croppedData
            allPhotos[idx].croppedUIImage = croppedImage
            allPhotos[idx].normalizedCornersJSON = cornersJSON
            allPhotos[idx].detectedOCRDate = ocrDate
            allPhotos[idx].resolvedFilmFormat = resolvedFormat
            allPhotos[idx].isDetectingBoundary = false
            allPhotos[idx].hasCompletedBoundaryDetection = true
        }
        for i in slots.indices {
            if slots[i].frontPhoto.id == id {
                slots[i].frontPhoto.croppedImageData = croppedData
                slots[i].frontPhoto.croppedUIImage = croppedImage
                slots[i].frontPhoto.normalizedCornersJSON = cornersJSON
                slots[i].frontPhoto.detectedOCRDate = ocrDate
                slots[i].frontPhoto.resolvedFilmFormat = resolvedFormat
                slots[i].frontPhoto.isDetectingBoundary = false
                slots[i].frontPhoto.hasCompletedBoundaryDetection = true
            }
            if slots[i].backPhoto?.id == id {
                slots[i].backPhoto?.croppedImageData = croppedData
                slots[i].backPhoto?.croppedUIImage = croppedImage
                slots[i].backPhoto?.normalizedCornersJSON = cornersJSON
                slots[i].backPhoto?.detectedOCRDate = ocrDate
                slots[i].backPhoto?.resolvedFilmFormat = resolvedFormat
                slots[i].backPhoto?.isDetectingBoundary = false
                slots[i].backPhoto?.hasCompletedBoundaryDetection = true
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
        var assignments: [UUID: [IdolMember]] = [:]

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
                assignments[photoID] = [idolMembers[spec.memberIdx % idolMembers.count]]
            }
            generated.append(
                StagingChekiPhoto(
                    id: photoID,
                    sequenceNumber: spec.seq,
                    title: spec.title,
                    imageData: data,
                    uiImage: img,
                    detectedSide: spec.side,
                    detectionNote: spec.note,
                    croppedImageData: data,
                    croppedUIImage: img,
                    resolvedFilmFormat: .mini,
                    isDetectingBoundary: false,
                    hasCompletedBoundaryDetection: true
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

    // MARK: - 10. 執行批次歸檔儲存（直接重用背景已完成的邊界預裁切與 OCR 結果，不新增重複照片、直接修改原圖並保留原始圖片可復原）

    @MainActor
    private func executeBatchProcessing() async {
        guard !slots.isEmpty else { return }
        isProcessingBatch = true
        processedCount = 0
        totalToProcess = slots.count
        defer { isProcessingBatch = false }

        let visionManager = VisionManager()
        let chekiFormat = Self.toChekiFilmFormat(selectedFilmFormat)
        let defaultInsetRatio = defaultBorderInsetPercentage / 100.0
        let baseTimestamp = Date()

        for (index, slot) in slots.enumerated() {
            // 同一組拍立得的正反面賦予完全相同的秒數 (Task 3.3)
            let itemTimestamp = baseTimestamp.addingTimeInterval(TimeInterval(-index))
            let targetMember = slot.assignedMembers.first
            var concreteFormat: FilmFormat = selectedFilmFormat == .auto
                ? slot.frontPhoto.resolvedFilmFormat.concreteFormat
                : selectedFilmFormat.concreteFormat

            let initialFrontData = slot.frontPhoto.isRevertedToOriginal
                ? slot.frontPhoto.imageData
                : (slot.frontPhoto.croppedImageData ?? slot.frontPhoto.imageData)
            let initialBackData = slot.backPhoto.map { back in
                back.isRevertedToOriginal ? back.imageData : (back.croppedImageData ?? back.imageData)
            }

            // 若該張照片已存在於典藏庫（依系統相簿 assetIdentifier 或原始圖片比對），直接原地修改該筆紀錄而不新建重複照片
            let targetItem: ChekiItem
            if let existing = existingChekiItems.first(where: { item in
                if let assetId = slot.frontPhoto.assetIdentifier, !assetId.isEmpty, item.frontAssetIdentifier == assetId {
                    return true
                }
                if let origData = item.originalFrontImageData, origData == slot.frontPhoto.imageData {
                    return true
                }
                return false
            }) {
                targetItem = existing
                if targetItem.originalFrontImageData == nil {
                    targetItem.originalFrontImageData = slot.frontPhoto.imageData
                }
                targetItem.frontImageData = initialFrontData
                if let backPhoto = slot.backPhoto {
                    if targetItem.originalBackImageData == nil {
                        targetItem.originalBackImageData = backPhoto.imageData
                    }
                    targetItem.backImageData = initialBackData
                    if let backAssetId = backPhoto.assetIdentifier {
                        targetItem.backAssetIdentifier = backAssetId
                    }
                }
                if let frontAssetId = slot.frontPhoto.assetIdentifier {
                    targetItem.frontAssetIdentifier = frontAssetId
                }
                targetItem.filmFormat = concreteFormat
                targetItem.detectedAspectRatio = concreteFormat.aspectRatio
                targetItem.borderInsetRatio = defaultInsetRatio
                if let targetMember {
                    targetItem.idolMember = targetMember
                }
            } else {
                let newItem = ChekiItem(
                    frontImageData: initialFrontData,
                    backImageData: initialBackData,
                    originalFrontImageData: slot.frontPhoto.imageData,
                    originalBackImageData: slot.backPhoto?.imageData,
                    capturedAt: itemTimestamp,
                    filmFormat: concreteFormat,
                    detectedAspectRatio: concreteFormat.aspectRatio,
                    borderInsetRatio: defaultInsetRatio,
                    processingState: .detecting,
                    frontAssetIdentifier: slot.frontPhoto.assetIdentifier,
                    backAssetIdentifier: slot.backPhoto?.assetIdentifier,
                    idolMember: targetMember
                )
                modelContext.insert(newItem)
                targetItem = newItem
            }

            // 1. 正面：優先直接使用背景已完成的邊界裁切與封面手寫日期 OCR 結果
            var finalFrontUIImage = slot.frontPhoto.displayUIImage
            var recognizedDate: Date? = slot.frontPhoto.detectedOCRDate
            if slot.frontPhoto.isRevertedToOriginal {
                targetItem.frontImageData = slot.frontPhoto.imageData
                targetItem.perspectivePointsJSON = nil
                finalFrontUIImage = slot.frontPhoto.uiImage
                if recognizedDate == nil, let frontCG = slot.frontPhoto.uiImage.cgImage {
                    recognizedDate = await visionManager.recognizeDate(from: frontCG)?.date
                }
            } else if slot.frontPhoto.hasCompletedBoundaryDetection {
                if let preCroppedData = slot.frontPhoto.croppedImageData {
                    targetItem.frontImageData = preCroppedData
                    targetItem.detectionMethod = .visionNative
                }
                targetItem.perspectivePointsJSON = slot.frontPhoto.normalizedCornersJSON
                if recognizedDate == nil, let frontCG = slot.frontPhoto.displayUIImage.cgImage {
                    recognizedDate = await visionManager.recognizeDate(from: frontCG)?.date
                }
            } else if let frontCG = slot.frontPhoto.uiImage.cgImage {
                // 若使用者在背景偵測尚未跑完前就按下歸檔，則即時補跑該張照片（含設定邊界微調與手寫日期 OCR）
                let imgSize = CGSize(width: frontCG.width, height: frontCG.height)
                if let detection = try? await visionManager.detectQuad(in: frontCG, imageSize: imgSize) {
                    let adjustedCorners = await visionManager.applyBorderInset(
                        corners: detection.corners,
                        imageSize: imgSize,
                        ratio: defaultInsetRatio
                    )
                    if let cropRes = try? await visionManager.perspectiveCorrect(
                        image: frontCG,
                        corners: adjustedCorners,
                        detection: detection,
                        format: chekiFormat
                    ) {
                        let croppedUI = UIImage(cgImage: cropRes.cgImage)
                        finalFrontUIImage = croppedUI
                        if let jpeg = croppedUI.jpegData(compressionQuality: 0.92) {
                            targetItem.frontImageData = jpeg
                        }
                        targetItem.perspectivePointsJSON = ChekiItem.encodeNormalizedCorners(adjustedCorners, imageSize: imgSize)
                        targetItem.detectionMethod = .visionNative
                        concreteFormat = FilmFormat.resolvedConcreteFormat(
                            preferred: selectedFilmFormat,
                            specName: cropRes.filmSpecification?.format.rawValue,
                            outputSize: cropRes.outputSize
                        )
                        targetItem.filmFormat = concreteFormat
                        targetItem.detectedAspectRatio = concreteFormat.aspectRatio

                        if let ocrRes = await visionManager.recognizeDate(from: cropRes.cgImage) {
                            recognizedDate = ocrRes.date
                        } else if let fallbackOCR = await visionManager.recognizeDate(from: frontCG) {
                            recognizedDate = fallbackOCR.date
                        }
                    }
                } else {
                    if let ocrRes = await visionManager.recognizeDate(from: frontCG) {
                        recognizedDate = ocrRes.date
                    }
                }
            }

            // 2. 背面：優先直接使用背景已完成的邊界裁切結果
            var finalBackUIImage: UIImage? = slot.backPhoto?.displayUIImage
            if let backPhoto = slot.backPhoto {
                if backPhoto.isRevertedToOriginal {
                    targetItem.backImageData = backPhoto.imageData
                    targetItem.backPerspectivePointsJSON = nil
                    finalBackUIImage = backPhoto.uiImage
                } else if backPhoto.hasCompletedBoundaryDetection {
                    if let preCroppedBackData = backPhoto.croppedImageData {
                        targetItem.backImageData = preCroppedBackData
                    }
                    targetItem.backPerspectivePointsJSON = backPhoto.normalizedCornersJSON
                    if recognizedDate == nil {
                        recognizedDate = backPhoto.detectedOCRDate
                    }
                } else if let backCG = backPhoto.uiImage.cgImage {
                    let backSize = CGSize(width: backCG.width, height: backCG.height)
                    if let backDetection = try? await visionManager.detectQuad(in: backCG, imageSize: backSize) {
                        let adjustedBackCorners = await visionManager.applyBorderInset(
                            corners: backDetection.corners,
                            imageSize: backSize,
                            ratio: defaultInsetRatio
                        )
                        if let backCrop = try? await visionManager.perspectiveCorrect(
                            image: backCG,
                            corners: adjustedBackCorners,
                            detection: backDetection,
                            format: chekiFormat
                        ) {
                            let croppedBackUI = UIImage(cgImage: backCrop.cgImage)
                            finalBackUIImage = croppedBackUI
                            if let jpeg = croppedBackUI.jpegData(compressionQuality: 0.92) {
                                targetItem.backImageData = jpeg
                            }
                            targetItem.backPerspectivePointsJSON = ChekiItem.encodeNormalizedCorners(adjustedBackCorners, imageSize: backSize)
                        }
                    }
                }
            }

            // 若辨識出拍立得封面（或背面）手寫日期，自動填入拍攝日期（保留當下時分秒）
            if let recognizedDate {
                let mergedDate = ChekiItem.mergeRecognizedDate(recognizedDate, into: itemTimestamp)
                targetItem.ocrDate = mergedDate
                targetItem.capturedAt = mergedDate
            }

            // 備忘預設保持空白（不自動塞入系統匯入文字）
            targetItem.processingState = .completed

            // 3. 若開啟系統相簿同步，直接原地修改系統相簿原圖（不新增重複照片，保留原始底圖可復原）
            if autoSyncToPhotos {
                let syncDate = targetItem.displayDate
                let membersToSync = slot.assignedMembers.isEmpty ? [nil as IdolMember?] : slot.assignedMembers.map { Optional($0) }
                for (memberIdx, memberOpt) in membersToSync.enumerated() {
                    let albumName = memberOpt?.stageName ?? "ChekiLens"
                    let folderName = memberOpt?.group?.name
                    if let album = try? await PhotoLibraryManager.shared.getOrCreateAlbum(
                        albumName: albumName,
                        inFolder: folderName
                    ) {
                        if memberIdx == 0 {
                            if let updatedFrontId = try? await PhotoLibraryManager.shared.updateOrSaveImage(
                                finalFrontUIImage,
                                originalImageData: targetItem.originalFrontImageData,
                                existingAssetIdentifier: targetItem.frontAssetIdentifier,
                                creationDate: syncDate,
                                to: album
                            ) {
                                targetItem.frontAssetIdentifier = updatedFrontId
                            }
                            if let backImg = finalBackUIImage {
                                if let updatedBackId = try? await PhotoLibraryManager.shared.updateOrSaveImage(
                                    backImg,
                                    originalImageData: targetItem.originalBackImageData,
                                    existingAssetIdentifier: targetItem.backAssetIdentifier,
                                    creationDate: syncDate,
                                    to: album
                                ) {
                                    targetItem.backAssetIdentifier = updatedBackId
                                }
                            }
                        } else {
                            if let frontId = targetItem.frontAssetIdentifier {
                                try? await PhotoLibraryManager.shared.addExistingAsset(
                                    identifier: frontId,
                                    creationDate: syncDate,
                                    to: album
                                )
                            }
                            if let backId = targetItem.backAssetIdentifier {
                                try? await PhotoLibraryManager.shared.addExistingAsset(
                                    identifier: backId,
                                    creationDate: syncDate,
                                    to: album
                                )
                            }
                        }
                        targetItem.isSyncedToPhotoLibrary = true
                        targetItem.isDateWrittenToAlbum = (targetItem.ocrDate != nil)
                    }
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
