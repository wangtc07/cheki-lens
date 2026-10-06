import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Library Category Scope

enum LibraryScope: String, CaseIterable, Identifiable {
    case all = "全部"
    case groups = "團體"
    case members = "成員"

    var id: String { rawValue }
}

// MARK: - LibraryView (Task 4.2 Gallery + Task 4.4 PhotosPicker)

/// Task 4.2: 首頁拍立得網格畫廊視圖（嚴格遵循 Apple HIG 原生 iOS 17/18 設計規範）
/// - 使用 `NavigationStack`、`.searchable`、Segmented `Picker`（全部 / 團體 / 成員）
/// - 2 欄圓角拍立得卡片網格（`LazyVGrid`），支援正反面雙面標記、日期、成員與 `#標籤` 顯示
/// - 內建範例測試資料一鍵載入與團體/成員快速新增 Sheet
struct LibraryView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    // 分類與搜尋狀態
    @State private var selectedScope: LibraryScope = .all
    @State private var searchText: String = ""
    @State private var selectedMemberFilterID: UUID?
    @State private var showUncategorizedOnly: Bool = false

    // 匯入與 AI 處理狀態
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var processingItems: [PhotosPickerItem] = []
    @State private var isProcessing: Bool = false

    // 批次選取與刪除狀態
    @State private var isSelectionMode: Bool = false
    @State private var selectedItemIDs = Set<PersistentIdentifier>()
    @State private var showDeleteConfirm: Bool = false

    // 新增團體/成員 Sheet
    @State private var showingQuickCreateSheet: Bool = false

    private let twoColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    // 明確宣告 init，避免 Swift 6 因 @Query private var 導致合成 initializer 變成 private
    init() {}

    // MARK: - Filtered Data

    private var filteredChekiItems: [ChekiItem] {
        chekiItems.filter { item in
            // 1. 成員膠囊篩選（僅於「全部」分頁生效）
            if selectedScope == .all {
                if showUncategorizedOnly {
                    if item.idolMember != nil { return false }
                } else if let filterID = selectedMemberFilterID {
                    if item.idolMember?.id != filterID { return false }
                }
            }

            // 2. 關鍵字與 #標籤搜尋
            return Self.matchesSearch(item: item, query: searchText)
        }
    }

    private var filteredGroups: [IdolGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return idolGroups }
        let normalized = query.replacingOccurrences(of: "#", with: "")
        return idolGroups.filter { group in
            if group.name.localizedCaseInsensitiveContains(normalized) {
                return true
            }
            return group.members.contains { member in
                member.stageName.localizedCaseInsensitiveContains(normalized)
                    || member.tags.contains { $0.localizedCaseInsensitiveContains(normalized) }
            }
        }
    }

    private var filteredMembers: [IdolMember] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return idolMembers }
        let normalized = query.replacingOccurrences(of: "#", with: "")
        return idolMembers.filter { member in
            member.stageName.localizedCaseInsensitiveContains(normalized)
                || (member.group?.name.localizedCaseInsensitiveContains(normalized) ?? false)
                || member.tags.contains { $0.localizedCaseInsensitiveContains(normalized) }
        }
    }

    private var uncategorizedItems: [ChekiItem] {
        chekiItems.filter { $0.idolMember == nil }
    }

    /// 彙整所有常用 #標籤供搜尋建議使用
    private var availableHashtags: [String] {
        var counts: [String: Int] = [:]
        for item in chekiItems {
            for tag in item.memo?.hashtags ?? [] {
                counts[tag, default: 0] += 1
            }
        }
        return counts.keys.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
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

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if chekiItems.isEmpty && idolGroups.isEmpty && idolMembers.isEmpty {
                    emptyStateView
                } else {
                    mainContentView
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isSelectionMode ? "已選取 \(selectedItemIDs.count) 張" : "典藏")
            .navigationBarTitleDisplayMode(isSelectionMode ? .inline : .large)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "搜尋成員、團體、活動或 #標籤"
            )
            .toolbar {
                leadingToolbarItem
                trailingToolbarItem
            }
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
            .overlay {
                if isProcessing {
                    processingOverlay
                }
            }
            .navigationDestination(for: ChekiItem.self) { item in
                ChekiDetailView(item: item)
            }
            .navigationDestination(for: IdolGroup.self) { group in
                GroupChekiCollectionView(group: group, allItems: chekiItems)
            }
            .navigationDestination(for: IdolMember.self) { member in
                MemberChekiCollectionView(member: member, allItems: chekiItems)
            }
        }
    }

    // MARK: - Main Content View

    private var mainContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. 原生 Segmented Control：全部 / 團體 / 成員
                Picker("分類檢視", selection: $selectedScope) {
                    ForEach(LibraryScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 4)

                // 2. 搜尋中顯示快速 #標籤建議列
                if !searchText.isEmpty && !availableHashtags.isEmpty {
                    hashtagSuggestionBar
                }

                // 3. 依據分類階層顯示內容
                switch selectedScope {
                case .all:
                    allChekiSection
                case .groups:
                    groupsSection
                case .members:
                    membersSection
                }
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Scope 1: 全部拍立得

    private var allChekiSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !idolMembers.isEmpty {
                memberFilterChipBar
            }

            if filteredChekiItems.isEmpty {
                if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 40)
                } else {
                    ContentUnavailableView(
                        "此分類尚無拍立得",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("點擊右上角「+」匯入照片，或切換其他成員篩選。")
                    )
                    .padding(.top, 40)
                }
            } else {
                // 統計摘要列
                HStack {
                    Text("共 \(filteredChekiItems.count) 張拍立得")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    let dualCount = filteredChekiItems.filter(\.hasBothSides).count
                    if dualCount > 0 {
                        Label("\(dualCount) 張含背面", systemImage: "rectangle.portrait.on.rectangle.portrait")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)

                // 2 欄圓角拍立得卡片網格
                LazyVGrid(columns: twoColumns, spacing: 16) {
                    ForEach(filteredChekiItems) { item in
                        chekiGridCell(for: item)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var memberFilterChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChipButton(
                    title: "全部 (\(chekiItems.count))",
                    isSelected: selectedMemberFilterID == nil && !showUncategorizedOnly
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedMemberFilterID = nil
                        showUncategorizedOnly = false
                    }
                }

                ForEach(idolMembers) { member in
                    FilterChipButton(
                        title: member.stageName,
                        subtitle: member.group?.name,
                        count: member.chekiItems.count,
                        isSelected: selectedMemberFilterID == member.id && !showUncategorizedOnly
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            showUncategorizedOnly = false
                            if selectedMemberFilterID == member.id {
                                selectedMemberFilterID = nil
                            } else {
                                selectedMemberFilterID = member.id
                            }
                        }
                    }
                }

                if !uncategorizedItems.isEmpty {
                    FilterChipButton(
                        title: "未分類",
                        count: uncategorizedItems.count,
                        isSelected: showUncategorizedOnly
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            selectedMemberFilterID = nil
                            showUncategorizedOnly.toggle()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var hashtagSuggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableHashtags.prefix(8), id: \.self) { tag in
                    Button {
                        searchText = "#\(tag)"
                    } label: {
                        Text("#\(tag)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Color.blue.opacity(0.12),
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

    @ViewBuilder
    private func chekiGridCell(for item: ChekiItem) -> some View {
        if isSelectionMode {
            let isSelected = selectedItemIDs.contains(item.persistentModelID)
            ChekiPolaroidCard(item: item)
                .overlay(alignment: .topLeading) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.9), isSelected ? .blue : .black.opacity(0.35))
                        .padding(10)
                }
                .scaleEffect(isSelected ? 0.97 : 1.0)
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
                ChekiPolaroidCard(item: item)
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

    // MARK: - Scope 2: 團體階層

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if filteredGroups.isEmpty {
                if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 40)
                } else {
                    ContentUnavailableView {
                        Label("尚無偶像團體", systemImage: "person.3")
                    } description: {
                        Text("建立團體與成員名冊，讓每張拍立得都能按團體整齊歸檔。")
                    } actions: {
                        Button("新增團體與成員") {
                            showingQuickCreateSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 40)
                }
            } else {
                LazyVGrid(columns: twoColumns, spacing: 16) {
                    ForEach(filteredGroups) { group in
                        NavigationLink(value: group) {
                            IdolGroupCardView(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Scope 3: 成員階層

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if filteredMembers.isEmpty {
                if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 40)
                } else {
                    ContentUnavailableView {
                        Label("尚無推角成員", systemImage: "person.crop.rectangle.stack")
                    } description: {
                        Text("新增您的推角成員，集中瀏覽與管理每位成員的拍立得。")
                    } actions: {
                        Button("新增推角成員") {
                            showingQuickCreateSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 40)
                }
            } else {
                LazyVGrid(columns: twoColumns, spacing: 16) {
                    ForEach(filteredMembers) { member in
                        NavigationLink(value: member) {
                            IdolMemberCardView(member: member)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Empty State View

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("尚無拍立得典藏", systemImage: "photo.stack")
        } description: {
            Text("從系統相簿匯入您的拍立得照片，或載入範例測試資料體驗完整分類與正反面典藏功能。")
        } actions: {
            VStack(spacing: 12) {
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: 50,
                    matching: .images
                ) {
                    Label("從相簿選擇照片", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    loadSampleTestData()
                } label: {
                    Label("載入範例測試資料", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var leadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelectionMode {
                Button(selectedItemIDs.count == filteredChekiItems.count ? "取消全選" : "全選") {
                    if selectedItemIDs.count == filteredChekiItems.count {
                        selectedItemIDs.removeAll()
                    } else {
                        selectedItemIDs = Set(filteredChekiItems.map(\.persistentModelID))
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var trailingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if isSelectionMode {
                Button("完成") {
                    withAnimation {
                        isSelectionMode = false
                        selectedItemIDs.removeAll()
                    }
                }
                .fontWeight(.semibold)
            } else {
                HStack(spacing: 12) {
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 50,
                        matching: .images,
                        preferredItemEncoding: .automatic
                    ) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("匯入拍立得照片")
                    .onChange(of: selectedPhotos) { _, newItems in
                        guard !newItems.isEmpty else { return }
                        processingItems = newItems
                        selectedPhotos = []
                        Task { await processImportedPhotos(processingItems) }
                    }

                    Menu {
                        if !chekiItems.isEmpty {
                            Button {
                                withAnimation {
                                    selectedScope = .all
                                    isSelectionMode = true
                                }
                            } label: {
                                Label("選取拍立得", systemImage: "checkmark.circle")
                            }
                        }

                        Button {
                            showingQuickCreateSheet = true
                        } label: {
                            Label("新增團體 / 成員", systemImage: "person.badge.plus")
                        }

                        Divider()

                        Button {
                            loadSampleTestData()
                        } label: {
                            Label("載入範例測試資料", systemImage: "sparkles.rectangle.stack")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多選項")
                }
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

    // MARK: - Actions & Vision Processing

    private func loadSampleTestData() {
        withAnimation {
            PreviewData.populate(into: modelContext)
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

            let newItem = ChekiItem()
            newItem.frontImageData = data
            newItem.capturedAt = Date()
            newItem.processingState = .unprocessed

            // 若目前有篩選特定成員，自動歸類至該成員
            if let filterID = selectedMemberFilterID,
               let activeMember = idolMembers.first(where: { $0.id == filterID }) {
                newItem.idolMember = activeMember
            }

            modelContext.insert(newItem)
            await processWithVision(newItem, image: uiImage)
        }

        try? modelContext.save()
    }

    private func processWithVision(_ item: ChekiItem, image: UIImage) async {
        guard let cgImage = image.cgImage else { return }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

        do {
            let manager = VisionManager()
            let detection = try await manager.detectQuad(in: cgImage, imageSize: imageSize)
            let cropResult = try await manager.perspectiveCorrect(
                image: cgImage,
                corners: detection.corners,
                detection: detection,
                format: .auto
            )
            await MainActor.run {
                item.frontImageData = UIImage(cgImage: cropResult.cgImage).jpegData(compressionQuality: 0.92)
                item.processingState = .completed
            }
        } catch {
            await MainActor.run {
                item.processingState = .error
            }
        }
    }
}

// MARK: - FilterChipButton

private struct FilterChipButton: View {
    let title: String
    var subtitle: String? = nil
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))

                if let count {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            isSelected ? Color.white.opacity(0.24) : Color(.tertiarySystemFill),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(
                isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color(.separator).opacity(isSelected ? 0 : 0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ChekiPolaroidCard (2 欄圓角拍立得卡片)

struct ChekiPolaroidCard: View {
    let item: ChekiItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 相片預覽區（維持拍立得縱向比例）
            ZStack(alignment: .topTrailing) {
                Color(.tertiarySystemGroupedBackground)

                if let data = item.frontImageData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("尚無影像")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 狀態與正反面徽章
                HStack(spacing: 4) {
                    if item.processingState == .error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    if item.hasBothSides {
                        Label("雙面", systemImage: "rectangle.portrait.on.rectangle.portrait.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .accessibilityLabel("包含正反兩面")
                    }
                }
                .padding(8)
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 卡片底部資訊區
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.idolMember?.stageName ?? "未分類拍立得")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let groupName = item.idolMember?.group?.name {
                        Text(groupName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    Text(ChekiDateFormatter.shared.string(from: item.displayDate))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    if item.ocrDate != nil {
                        Image(systemName: "text.viewfinder")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Spacer(minLength: 0)

                    if let firstTag = item.memo?.hashtags.first {
                        Text("#\(firstTag)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
        .padding(10)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - IdolGroupCardView

private struct IdolGroupCardView: View {
    let group: IdolGroup

    private var coverImageData: Data? {
        for member in group.sortedMembers {
            if let data = member.latestCheki?.frontImageData {
                return data
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color(.tertiarySystemGroupedBackground)

                if let data = coverImageData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else {
                    Image(systemName: "person.3.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                }
            }
            .aspectRatio(1.15, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(group.members.count) 位成員 · \(group.totalChekiCount) 張拍立得")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - IdolMemberCardView

private struct IdolMemberCardView: View {
    let member: IdolMember

    private var coverImageData: Data? {
        member.latestCheki?.frontImageData
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Color(.tertiarySystemGroupedBackground)

                if let data = coverImageData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else {
                    Image(systemName: "person.crop.rectangle")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.purple)
                }

                Text("\(member.chekiItems.count) 張")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            .aspectRatio(0.9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(member.stageName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(member.group?.name ?? "個人 / 未分團")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if let firstTag = member.tags.first {
                        Text("#\(firstTag)")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Group & Member Drill-Down Views

private struct GroupChekiCollectionView: View {
    let group: IdolGroup
    let allItems: [ChekiItem]

    @State private var selectedMemberID: UUID?
    @State private var searchText: String = ""

    private let twoColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var groupItems: [ChekiItem] {
        allItems.filter { item in
            guard item.idolMember?.group?.id == group.id else { return false }
            if let selectedMemberID, item.idolMember?.id != selectedMemberID {
                return false
            }
            return LibraryView.matchesSearch(item: item, query: searchText)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !group.sortedMembers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChipButton(
                                title: "全部成員",
                                count: group.totalChekiCount,
                                isSelected: selectedMemberID == nil
                            ) {
                                selectedMemberID = nil
                            }

                            ForEach(group.sortedMembers) { member in
                                FilterChipButton(
                                    title: member.stageName,
                                    count: member.chekiItems.count,
                                    isSelected: selectedMemberID == member.id
                                ) {
                                    selectedMemberID = (selectedMemberID == member.id) ? nil : member.id
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if groupItems.isEmpty {
                    ContentUnavailableView(
                        "尚無拍立得",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("此團體或篩選條件下尚無拍立得。")
                    )
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: twoColumns, spacing: 16) {
                        ForEach(groupItems) { item in
                            NavigationLink(value: item) {
                                ChekiPolaroidCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(group.name)
        .searchable(text: $searchText, prompt: "搜尋 \(group.name) 的拍立得或 #標籤")
    }
}

private struct MemberChekiCollectionView: View {
    let member: IdolMember
    let allItems: [ChekiItem]

    @State private var searchText: String = ""

    private let twoColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var memberItems: [ChekiItem] {
        allItems.filter { item in
            guard item.idolMember?.id == member.id else { return false }
            return LibraryView.matchesSearch(item: item, query: searchText)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 成員資訊橫幅
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(member.stageName)
                                .font(.headline)
                            if let groupName = member.group?.name {
                                Text(groupName)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                        }

                        if !member.tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(member.tags, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Spacer()
                    Text("\(memberItems.count) 張")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .padding(.horizontal, 16)

                if memberItems.isEmpty {
                    ContentUnavailableView(
                        "尚無拍立得",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("尚未將拍立得歸類給 \(member.stageName)。")
                    )
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: twoColumns, spacing: 16) {
                        ForEach(memberItems) { item in
                            NavigationLink(value: item) {
                                ChekiPolaroidCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(member.stageName)
        .searchable(text: $searchText, prompt: "搜尋 \(member.stageName) 的活動或 #標籤")
    }
}

// MARK: - QuickCreateIdolSheet (快速新增團體 / 成員)

private struct QuickCreateIdolSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var groups: [IdolGroup]

    @State private var stageName: String = ""
    @State private var groupName: String = ""
    @State private var tagsText: String = ""

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

// MARK: - Shared Date Formatter

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

#Preview("含範例測試資料 (Light)") {
    LibraryView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}

#Preview("含範例測試資料 (Dark)") {
    LibraryView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
        .preferredColorScheme(.dark)
}

#Preview("空狀態") {
    LibraryView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: false))
}
