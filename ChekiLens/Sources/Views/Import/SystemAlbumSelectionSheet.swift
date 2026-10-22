import SwiftUI
import Photos
import PhotosUI
import UIKit

nonisolated enum FolderSelectionStatus: Equatable, Sendable {
    case none
    case partial
    case all
}

nonisolated struct SystemAlbumSelectionState: Equatable, Sendable {
    var hierarchy: SystemPhotoLibraryHierarchy
    var selectedAlbumIDs: Set<String>
    var expandedFolderIDs: Set<String>
    var edgeDetectionOverrides: [String: Bool]
    var defaultEdgeDetection: Bool
    var searchQuery: String

    init(
        hierarchy: SystemPhotoLibraryHierarchy = SystemPhotoLibraryHierarchy(),
        selectedAlbumIDs: Set<String> = [],
        expandedFolderIDs: Set<String> = [],
        edgeDetectionOverrides: [String: Bool] = [:],
        defaultEdgeDetection: Bool = true,
        searchQuery: String = ""
    ) {
        self.hierarchy = hierarchy
        self.selectedAlbumIDs = selectedAlbumIDs
        self.expandedFolderIDs = expandedFolderIDs
        self.edgeDetectionOverrides = edgeDetectionOverrides
        self.defaultEdgeDetection = defaultEdgeDetection
        self.searchQuery = searchQuery
    }

    var allAlbumIDs: Set<String> {
        Set(hierarchy.allAlbums.map(\.id))
    }

    var isAllSelected: Bool {
        !allAlbumIDs.isEmpty && allAlbumIDs.isSubset(of: selectedAlbumIDs)
    }

    var selectedAlbumCount: Int {
        allAlbumIDs.intersection(selectedAlbumIDs).count
    }

    var selectedPhotoCount: Int {
        hierarchy.allAlbums
            .filter { selectedAlbumIDs.contains($0.id) }
            .reduce(0) { $0 + $1.assetCount }
    }

    var canProceed: Bool {
        selectedAlbumCount > 0 && selectedPhotoCount > 0
    }

    var isAllEdgeDetectionEnabled: Bool {
        let ids = allAlbumIDs
        guard !ids.isEmpty else { return defaultEdgeDetection }
        return ids.allSatisfy { isEdgeDetectionEnabled(for: $0) }
    }

    var filteredFolders: [SystemPhotoFolderNode] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return hierarchy.folders }
        return hierarchy.folders.compactMap { filterFolder($0, query: query) }
    }

    var filteredStandaloneAlbums: [SystemPhotoAlbumNode] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return hierarchy.standaloneAlbums }
        return hierarchy.standaloneAlbums.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func filterFolder(_ folder: SystemPhotoFolderNode, query: String) -> SystemPhotoFolderNode? {
        if folder.title.localizedCaseInsensitiveContains(query) {
            return folder
        }
        let matchingAlbums = folder.albums.filter { $0.title.localizedCaseInsensitiveContains(query) }
        let matchingSubfolders = folder.subfolders.compactMap { filterFolder($0, query: query) }
        if !matchingAlbums.isEmpty || !matchingSubfolders.isEmpty {
            return SystemPhotoFolderNode(
                id: folder.id,
                title: folder.title,
                albums: matchingAlbums,
                subfolders: matchingSubfolders
            )
        }
        return nil
    }

    func isAlbumSelected(_ albumID: String) -> Bool {
        selectedAlbumIDs.contains(albumID)
    }

    func isEdgeDetectionEnabled(for albumID: String) -> Bool {
        edgeDetectionOverrides[albumID] ?? defaultEdgeDetection
    }

    func folderSelectionStatus(_ folderID: String) -> FolderSelectionStatus {
        if hierarchy.isFolderFullySelected(folderID, selectedAlbumIDs: selectedAlbumIDs) {
            return .all
        } else if hierarchy.isFolderPartiallySelected(folderID, selectedAlbumIDs: selectedAlbumIDs) {
            return .partial
        } else {
            return .none
        }
    }

    func isFolderExpanded(_ folderID: String) -> Bool {
        expandedFolderIDs.contains(folderID)
    }

    func buildResolvedSelection() -> [SystemPhotoAlbumNode] {
        hierarchy.resolvedSelectedAlbums(
            selectedAlbumIDs: selectedAlbumIDs,
            edgeDetectionOverrides: edgeDetectionOverrides,
            defaultEdgeDetection: defaultEdgeDetection
        )
    }

    mutating func applyHierarchy(_ newHierarchy: SystemPhotoLibraryHierarchy, selectAllByDefault: Bool = false) {
        hierarchy = newHierarchy
        expandedFolderIDs = Set(newHierarchy.folders.map(\.id))
        if selectAllByDefault {
            selectedAlbumIDs = Set(newHierarchy.allAlbums.map(\.id))
        } else {
            selectedAlbumIDs = []
        }
        edgeDetectionOverrides = [:]
    }

    mutating func toggleAlbumSelection(_ albumID: String) {
        if selectedAlbumIDs.contains(albumID) {
            selectedAlbumIDs.remove(albumID)
        } else {
            selectedAlbumIDs.insert(albumID)
        }
    }

    mutating func toggleFolderSelection(_ folderID: String) {
        selectedAlbumIDs = hierarchy.togglingFolder(folderID, in: selectedAlbumIDs)
    }

    mutating func toggleSelectAll() {
        if isAllSelected {
            selectedAlbumIDs.removeAll()
        } else {
            selectedAlbumIDs = allAlbumIDs
        }
    }

    mutating func toggleFolderExpansion(_ folderID: String) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
    }

    mutating func setEdgeDetection(_ enabled: Bool, forAlbum albumID: String) {
        edgeDetectionOverrides[albumID] = enabled
    }

    mutating func setFolderEdgeDetection(_ enabled: Bool, forFolder folderID: String) {
        let ids = hierarchy.albumIDs(inFolder: folderID)
        for id in ids {
            edgeDetectionOverrides[id] = enabled
        }
    }

    mutating func setAllEdgeDetection(_ enabled: Bool) {
        defaultEdgeDetection = enabled
        edgeDetectionOverrides.removeAll()
        for id in allAlbumIDs {
            edgeDetectionOverrides[id] = enabled
        }
    }
}

struct SystemAlbumThumbnailView: View {
    let assetIdentifier: String?
    var sideLength: CGFloat = 48
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(.tertiarySystemFill)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: sideLength * 0.4))
                    }
            }
        }
        .frame(width: sideLength, height: sideLength)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: assetIdentifier) {
            guard let id = assetIdentifier, !id.isEmpty else { return }
            let loaded = await SystemAlbumExplorerService.shared.requestThumbnail(
                for: id,
                targetSize: CGSize(width: sideLength * 2, height: sideLength * 2)
            )
            withAnimation(ChekiMotion.small) {
                self.thumbnail = loaded
            }
        }
    }
}

struct LimitedAccessBannerView: View {
    var onManageAccess: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("相片存取受限", "写真へのアクセス制限"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.tr("僅顯示已授權相簿。若缺少目標相簿可調整授權範圍。", "許可されたアルバムのみ表示中。不足時は設定を変更してください。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onManageAccess) {
                Text(L10n.tr("管理", "管理"))
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("import.albumSelection.manageLimitedAccess")
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

struct SystemAlbumSelectionContentView: View {
    @Binding var state: SystemAlbumSelectionState
    var isLoading: Bool = false
    var authorizationStatus: PHAuthorizationStatus = .authorized
    var onRefresh: (() async -> Void)? = nil
    var onConfirm: ([SystemPhotoAlbumNode]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if authorizationStatus == .limited {
                LimitedAccessBannerView {
                    presentLimitedLibraryPicker()
                }
            }

            headerActionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            if isLoading {
                ProgressView(L10n.tr("正在掃描相簿…", "アルバムをスキャン中…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.hierarchy.isEmpty {
                ContentUnavailableView(
                    L10n.tr("未找到相簿", "アルバムが見つかりません"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(L10n.tr("請確認相簿權限，或在系統相簿中建立相簿", "写真の権限を確認するか、アルバムを作成してください"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.filteredFolders.isEmpty && state.filteredStandaloneAlbums.isEmpty {
                ContentUnavailableView.search(text: state.searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.filteredFolders) { folder in
                        folderSection(folder)
                    }

                    if !state.filteredStandaloneAlbums.isEmpty {
                        Section(header: Text(L10n.tr("獨立相簿", "単独アルバム"))) {
                            ForEach(state.filteredStandaloneAlbums) { album in
                                albumRow(album, indent: 0)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await onRefresh?()
                }
            }

            bottomSummaryBar
        }
        .searchable(text: $state.searchQuery, prompt: Text(L10n.tr("搜尋相簿或團體", "アルバムやグループを検索")))
    }

    private var headerActionBar: some View {
        HStack {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(ChekiMotion.toggle) {
                    state.toggleSelectAll()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.isAllSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(state.isAllSelected ? .blue : .secondary)
                    Text(state.isAllSelected ? L10n.tr("取消全選", "選択解除") : L10n.tr("全選", "すべて選択"))
                        .font(.subheadline.weight(.medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("import.albumSelection.selectAll")

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(ChekiMotion.toggle) {
                    state.setAllEdgeDetection(!state.isAllEdgeDetectionEnabled)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.isAllEdgeDetectionEnabled ? "viewfinder.rectangular" : "crop")
                        .foregroundStyle(state.isAllEdgeDetectionEnabled ? .blue : .secondary)
                    Text(state.isAllEdgeDetectionEnabled ? L10n.tr("邊緣偵測 · 開啟", "端検出 · オン") : L10n.tr("邊緣偵測 · 關閉", "端検出 · オフ"))
                        .font(.subheadline)
                        .foregroundStyle(state.isAllEdgeDetectionEnabled ? .primary : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("import.albumSelection.globalEdgeToggle")
        }
    }

    @ViewBuilder
    private func folderSection(_ folder: SystemPhotoFolderNode) -> some View {
        Section {
            folderHeaderRow(folder)

            if state.isFolderExpanded(folder.id) {
                ForEach(folder.allAlbums) { album in
                    albumRow(album, indent: 20)
                }
            }
        }
    }

    private func folderHeaderRow(_ folder: SystemPhotoFolderNode) -> some View {
        let status = state.folderSelectionStatus(folder.id)
        let isExpanded = state.isFolderExpanded(folder.id)
        let allEdgeEnabled = folder.allAlbums.allSatisfy { state.isEdgeDetectionEnabled(for: $0.id) }

        return HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(ChekiMotion.toggle) {
                    state.toggleFolderSelection(folder.id)
                }
            } label: {
                Group {
                    switch status {
                    case .all:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    case .partial:
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.blue)
                    case .none:
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.title3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("切換資料夾選取", "フォルダ選択を切替"))
            .accessibilityIdentifier("import.folder.select.\(folder.id)")

            Button {
                withAnimation(ChekiMotion.small) {
                    state.toggleFolderExpansion(folder.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(L10n.tr("\(folder.albums.count) 個相簿 · \(folder.totalAssetCount) 張", "\(folder.albums.count)個のアルバム · \(folder.totalAssetCount)枚"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("import.folder.expand.\(folder.id)")

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(ChekiMotion.toggle) {
                    state.setFolderEdgeDetection(!allEdgeEnabled, forFolder: folder.id)
                }
            } label: {
                Image(systemName: allEdgeEnabled ? "viewfinder.rectangular" : "crop")
                    .font(.callout)
                    .foregroundStyle(allEdgeEnabled ? .blue : .secondary)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(allEdgeEnabled ? Color.blue.opacity(0.12) : Color(.tertiarySystemFill))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(allEdgeEnabled ? L10n.tr("關閉資料夾邊緣偵測", "フォルダ端検出をオフ") : L10n.tr("開啟資料夾邊緣偵測", "フォルダ端検出をオン"))
            .accessibilityIdentifier("import.folder.edgeToggle.\(folder.id)")
        }
        .padding(.vertical, 4)
    }

    private func albumRow(_ album: SystemPhotoAlbumNode, indent: CGFloat) -> some View {
        let isSelected = state.isAlbumSelected(album.id)
        let isEdgeEnabled = state.isEdgeDetectionEnabled(for: album.id)

        return HStack(spacing: 12) {
            if indent > 0 {
                Spacer().frame(width: indent)
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(ChekiMotion.toggle) {
                    state.toggleAlbumSelection(album.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? .blue : .secondary)

                    SystemAlbumThumbnailView(assetIdentifier: album.coverAssetIdentifier)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(
                            album.parentFolderTitle.map {
                                L10n.tr("\(album.assetCount) 張 · \($0)", "\(album.assetCount)枚 · \($0)")
                            } ?? L10n.tr("\(album.assetCount) 張相片", "\(album.assetCount)枚の写真")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("import.album.select.\(album.id)")

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(ChekiMotion.toggle) {
                    state.setEdgeDetection(!isEdgeEnabled, forAlbum: album.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isEdgeEnabled ? "viewfinder.rectangular" : "crop")
                        .font(.callout)
                        .foregroundStyle(isEdgeEnabled ? .blue : .secondary)
                    Text(isEdgeEnabled ? L10n.tr("邊緣偵測", "端検出") : L10n.tr("原圖直入", "原画維持"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isEdgeEnabled ? .blue : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isEdgeEnabled ? Color.blue.opacity(0.12) : Color(.tertiarySystemFill))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isEdgeEnabled
                    ? L10n.tr("邊緣偵測 · 開啟", "端検出 · オン")
                    : L10n.tr("邊緣偵測 · 關閉", "端検出 · オフ")
            )
            .accessibilityIdentifier("import.album.edgeToggle.\(album.id)")
        }
        .padding(.vertical, 4)
    }

    private var bottomSummaryBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("已選 \(state.selectedAlbumCount) 個相簿", "\(state.selectedAlbumCount)個のアルバムを選択"))
                        .font(.headline)
                    Text(L10n.tr("共 \(state.selectedPhotoCount) 張相片", "計 \(state.selectedPhotoCount) 枚"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onConfirm(state.buildResolvedSelection())
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text(L10n.tr("下一步 · 工作台", "次へ · ワークベンチ"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canProceed)
                .accessibilityIdentifier("import.albumSelection.proceed")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
    }

    private func presentLimitedLibraryPicker() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }
        var topController = rootVC
        while let presented = topController.presentedViewController {
            topController = presented
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: topController)
    }
}

struct SystemAlbumSelectionSheet: View {
    var selectAllByDefault: Bool = false
    var dismissOnConfirm: Bool = true
    var onConfirm: ([SystemPhotoAlbumNode]) -> Void
    var onCancel: (() -> Void)? = nil

    private var externalState: Binding<SystemAlbumSelectionState>?
    @State private var internalState = SystemAlbumSelectionState()
    @State private var isLoading = true
    @State private var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Environment(\.dismiss) private var dismiss

    init(
        state: Binding<SystemAlbumSelectionState>? = nil,
        selectAllByDefault: Bool = false,
        dismissOnConfirm: Bool = true,
        onCancel: (() -> Void)? = nil,
        onConfirm: @escaping ([SystemPhotoAlbumNode]) -> Void
    ) {
        self.externalState = state
        self.selectAllByDefault = selectAllByDefault
        self.dismissOnConfirm = dismissOnConfirm
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var activeState: Binding<SystemAlbumSelectionState> {
        externalState ?? $internalState
    }

    var body: some View {
        NavigationStack {
            SystemAlbumSelectionContentView(
                state: activeState,
                isLoading: isLoading,
                authorizationStatus: authorizationStatus,
                onRefresh: {
                    await loadHierarchy(forceReload: true)
                },
                onConfirm: { selection in
                    onConfirm(selection)
                    if dismissOnConfirm {
                        dismiss()
                    }
                }
            )
            .navigationTitle(L10n.tr("選擇系統相簿", "アルバム選択"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CloseToolbarButton(accessibilityIdentifier: "chrome.import.albumSelection.close") {
                        if let onCancel {
                            onCancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConfirmToolbarButton(accessibilityIdentifier: "chrome.import.albumSelection.confirm") {
                        onConfirm(activeState.wrappedValue.buildResolvedSelection())
                        if dismissOnConfirm {
                            dismiss()
                        }
                    }
                    .disabled(!activeState.wrappedValue.canProceed)
                }
            }
        }
        .task {
            await loadHierarchy(forceReload: false)
        }
    }

    private func loadHierarchy(forceReload: Bool) async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if !forceReload && !activeState.wrappedValue.hierarchy.isEmpty {
            isLoading = false
            return
        }
        isLoading = true
        let hierarchy = await SystemAlbumExplorerService.shared.fetchHierarchy()
        activeState.wrappedValue.applyHierarchy(hierarchy, selectAllByDefault: selectAllByDefault)
        isLoading = false
    }
}
