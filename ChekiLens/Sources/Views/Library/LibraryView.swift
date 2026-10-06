import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Album Hierarchy Mode (相冊頂部分段控制：團體 vs 成員)

enum AlbumHierarchyMode: String, CaseIterable, Identifiable {
    case groups = "團體"
    case members = "成員"

    var id: String { rawValue }
}

// MARK: - Uncategorized Album Route

struct UncategorizedAlbumRoute: Hashable {}

// MARK: - 1. LibraryView (底部左側 Tab 1：「全部」)

/// 「全部」拍立得視圖
/// - 取消上方分段控制與下方個人數字膠囊列，純粹展示全部拍立得
/// - 右上角提供 `+` 匯入拍立得，以及 `...` 選單（選取、新增團體/成員、載入測試資料、設定）
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

    private let twoColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    init() {}

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
            Group {
                if chekiItems.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("共 \(chekiItems.count) 張拍立得")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                let dualCount = chekiItems.filter(\.hasBothSides).count
                                if dualCount > 0 {
                                    Label("\(dualCount) 張含背面", systemImage: "rectangle.portrait.on.rectangle.portrait")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)

                            LazyVGrid(columns: twoColumns, spacing: 16) {
                                ForEach(chekiItems) { item in
                                    chekiGridCell(for: item)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 28)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isSelectionMode ? "已選取 \(selectedItemIDs.count) 張" : "全部")
            .navigationBarTitleDisplayMode(isSelectionMode ? .inline : .large)
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
            .sheet(isPresented: $showingSettingsSheet) {
                SettingsView()
            }
            .overlay {
                if isProcessing {
                    processingOverlay
                }
            }
            .navigationDestination(for: ChekiItem.self) { item in
                ChekiDetailView(item: item)
            }
        }
    }

    // MARK: - Subviews

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

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("尚無拍立得典藏", systemImage: "photo.stack")
        } description: {
            Text("從系統相簿匯入您的拍立得照片，或載入範例測試資料體驗完整相冊與正反面典藏功能。")
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

    @ToolbarContentBuilder
    private var leadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelectionMode {
                Button(selectedItemIDs.count == chekiItems.count ? "取消全選" : "全選") {
                    if selectedItemIDs.count == chekiItems.count {
                        selectedItemIDs.removeAll()
                    } else {
                        selectedItemIDs = Set(chekiItems.map(\.persistentModelID))
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
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多選項與設定")
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

            modelContext.insert(newItem)
            await VisionPhotoProcessor.process(newItem, image: uiImage)
        }

        try? modelContext.save()
    }
}

// MARK: - 2. AlbumsRootView (底部左側 Tab 2：「相冊」— 仿照 Apple 原生相簿設計)

/// Apple 原生相簿風格的「相冊」視圖（對應參考圖 2、3、4）
/// - 頂部保留「團體 | 成員」Segmented Control（取消下方個人數字膠囊列）
/// - 基本相簿構造為 `團體 > 成員`（點擊團體展開成員相冊，點擊成員展開圖 3 全幅封面相冊）
/// - 切換頂部至「成員」時，無視團體階層直接展開全部成員相冊
struct AlbumsRootView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    @State private var hierarchyMode: AlbumHierarchyMode = .groups
    @State private var showingQuickCreateSheet: Bool = false
    @State private var showingSettingsSheet: Bool = false

    private let albumColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var uncategorizedItems: [ChekiItem] {
        chekiItems.filter { $0.idolMember == nil }
    }

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 頂部保留「團體 | 成員」切換（圖 4 上方，取消下方個人數字部分）
                    Picker("相冊檢視階層", selection: $hierarchyMode) {
                        ForEach(AlbumHierarchyMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                    switch hierarchyMode {
                    case .groups:
                        groupsAlbumGrid
                    case .members:
                        allMembersAlbumGrid
                    }
                }
                .padding(.bottom, 28)
            }
            .background(Color(.systemBackground))
            .navigationTitle("相冊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showingQuickCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("新增團體或成員相冊")

                        Menu {
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
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("更多選項與設定")
                    }
                }
            }
            .sheet(isPresented: $showingQuickCreateSheet) {
                QuickCreateIdolSheet()
            }
            .sheet(isPresented: $showingSettingsSheet) {
                SettingsView()
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

    // MARK: - 成員相冊網格（無視團體階層直接展開全部成員）

    @ViewBuilder
    private var allMembersAlbumGrid: some View {
        if idolMembers.isEmpty && uncategorizedItems.isEmpty {
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
                ForEach(idolMembers) { member in
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
        if result.count < 4 {
            for member in group.sortedMembers {
                for item in member.chekiItems {
                    if let data = item.frontImageData, result.count < 4 {
                        result.append(data)
                    }
                }
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

// MARK: - 3. ApplePhotoAlbumTile (仿照圖 2：Apple 相簿 1:1 圓角滿版相冊磚，左下角白字疊加標題)

struct ApplePhotoAlbumTile: View {
    let primaryTitle: String
    let secondaryTitle: String?
    let coverImagesData: [Data]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width
            ZStack(alignment: .bottomLeading) {
                // 背景封面（單張滿版，自動微放大裁除相紙白邊以呈現圖 2 滿版相冊視覺）
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

                // 底部漸層確保白色標題清晰可讀（與圖 2 Apple 相簿一致）
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

                // 左下角白字標題（不顯示下方個人數字，完全對齊圖 2 樣式）
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
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - 4. GroupMembersAlbumView (團體 > 成員 第二層：點開團體後顯示旗下成員相冊)

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

// MARK: - 5. AlbumHeroDetailView (點開相冊後：仿照圖 3 Apple 相簿全幅 Hero 封面 + 緊密縮圖網格)

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

    @State private var sortAscending: Bool = false
    @State private var filterDualSideOnly: Bool = false
    @State private var columnCount: Int = 5

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
                // 頂部全幅 Hero 封面區（對應參考圖 3 上半部）
                heroHeaderView

                // 下方緊密相片網格（對應參考圖 3 下半部）
                if displayedItems.isEmpty {
                    ContentUnavailableView {
                        Label("尚無拍立得項目", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("點擊右上角「⋯」匯入拍立得至此相冊。")
                    }
                    .padding(.vertical, 48)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 2) {
                        ForEach(displayedItems) { item in
                            albumPhotoCell(for: item)
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    Menu {
                        PhotosPicker(
                            selection: $selectedPhotos,
                            maxSelectionCount: 50,
                            matching: .images
                        ) {
                            Label("匯入拍立得至此相冊", systemImage: "photo.badge.plus")
                        }

                        Menu {
                            Button {
                                columnCount = 3
                            } label: {
                                Label("3 欄大縮圖", systemImage: columnCount == 3 ? "checkmark" : "square.grid.3x3")
                            }
                            Button {
                                columnCount = 5
                            } label: {
                                Label("5 欄緊密網格", systemImage: columnCount == 5 ? "checkmark" : "square.grid.4x3.fill")
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
                            Label("設定", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }

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
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
            }
        }
        .onChange(of: selectedPhotos) { _, newItems in
            guard !newItems.isEmpty else { return }
            processingItems = newItems
            selectedPhotos = []
            Task { await processImportedPhotos(processingItems) }
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

    // MARK: - Hero Header (對應參考圖 3 上半部：全幅大圖 + 左下標題與項目數 + 右下播放鈕)

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
        }
        .frame(height: 390)
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
            let newItem = ChekiItem()
            newItem.frontImageData = data
            newItem.capturedAt = Date()
            newItem.processingState = .unprocessed
            newItem.idolMember = defaultMember

            modelContext.insert(newItem)
            await VisionPhotoProcessor.process(newItem, image: uiImage)
        }

        try? modelContext.save()
    }
}

private struct AlbumSquareThumbnailCell: View {
    let item: ChekiItem

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                if let data = item.frontImageData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.22)
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .frame(width: geo.size.width, height: geo.size.width)
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
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - 6. LibrarySearchView (底部右側圓形「🔍 搜尋」Tab)

struct LibrarySearchView: View {

    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]
    @Query(sort: \IdolMember.sortOrder, order: .forward) private var idolMembers: [IdolMember]

    @State private var searchText: String = ""
    @State private var showingSettingsSheet: Bool = false

    private let twoColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
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
                        // 熱門 #標籤快速探索
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

                        // 推角成員相冊快速捷徑
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
                        Text("找到 \(filteredItems.count) 張拍立得")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: twoColumns, spacing: 16) {
                            ForEach(filteredItems) { item in
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
            .navigationTitle("搜尋")
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

// MARK: - ChekiPolaroidCard (雙欄圓角拍立得卡片)

struct ChekiPolaroidCard: View {
    let item: ChekiItem

    private static func formatHashtag(_ raw: String) -> String {
        raw.hasPrefix("#") ? raw : "#\(raw)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                        Text(Self.formatHashtag(firstTag))
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

// MARK: - QuickCreateIdolSheet (快速新增團體 / 成員)

private struct QuickCreateIdolSheet: View {
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

#Preview("相冊 (Apple Photos 風格)") {
    AlbumsRootView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}

#Preview("全部拍立得") {
    LibraryView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}
