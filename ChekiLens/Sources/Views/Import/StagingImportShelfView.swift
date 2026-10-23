import SwiftUI
import SwiftData
import Photos
import UIKit

nonisolated enum StagingCardLoadPhase: Equatable, Sendable {
    case pending
    case loading(loadedCount: Int, totalCount: Int)
    case completed

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var progressFraction: Double {
        switch self {
        case .pending:
            return 0.0
        case .loading(let loaded, let total):
            guard total > 0 else { return 0.0 }
            return min(1.0, max(0.0, Double(loaded) / Double(total)))
        case .completed:
            return 1.0
        }
    }
}

struct StagingMemberAlbumCard: Identifiable, Equatable {
    let id: String
    var memberName: String
    var groupName: String?
    var enableEdgeDetection: Bool
    var sourceAssetIdentifiers: [String]
    var coverAssetIdentifier: String?
    var loadPhase: StagingCardLoadPhase
    var slots: [ChekiPairingSlot]
    var skippedDuplicateCount: Int

    var isReadyForInspection: Bool {
        loadPhase.isCompleted
    }

    var totalCandidateCount: Int {
        sourceAssetIdentifiers.count + skippedDuplicateCount
    }

    var activeSlotCount: Int {
        slots.count
    }

    var pairedSlotCount: Int {
        slots.filter(\.isPaired).count
    }

    var previewImage: UIImage? {
        slots.first?.frontPhoto.displayUIImage
    }

    init(
        id: String,
        memberName: String,
        groupName: String? = nil,
        enableEdgeDetection: Bool = true,
        sourceAssetIdentifiers: [String] = [],
        coverAssetIdentifier: String? = nil,
        loadPhase: StagingCardLoadPhase = .pending,
        slots: [ChekiPairingSlot] = [],
        skippedDuplicateCount: Int = 0
    ) {
        self.id = id
        self.memberName = memberName
        self.groupName = groupName
        self.enableEdgeDetection = enableEdgeDetection
        self.sourceAssetIdentifiers = sourceAssetIdentifiers
        self.coverAssetIdentifier = coverAssetIdentifier ?? sourceAssetIdentifiers.first
        self.loadPhase = loadPhase
        self.slots = slots
        self.skippedDuplicateCount = skippedDuplicateCount
    }
}

struct StagingGroupSection: Identifiable, Equatable {
    let id: String
    var groupName: String?
    var displayTitle: String
    var cards: [StagingMemberAlbumCard]

    init(
        id: String,
        groupName: String?,
        displayTitle: String,
        cards: [StagingMemberAlbumCard] = []
    ) {
        self.id = id
        self.groupName = groupName
        self.displayTitle = displayTitle
        self.cards = cards
    }
}

struct StagingImportShelfState: Equatable {
    var cards: [StagingMemberAlbumCard]
    var isSelectionMode: Bool
    var selectedCardIDs: Set<String>
    var customGroupNames: [String]

    init(
        albums: [SystemPhotoAlbumNode] = [],
        existingGroupNames: [String] = [],
        existingAssetIDs: Set<String> = []
    ) {
        let populatedAlbums = SystemAlbumExplorerService.populateAssetIdentifiers(for: albums)
        var seenIDs = existingAssetIDs
        var builtCards: [StagingMemberAlbumCard] = []
        builtCards.reserveCapacity(populatedAlbums.count)

        for album in populatedAlbums {
            let filterResult = SystemAlbumExplorerService.filterNewAssetIdentifiers(
                album.assetIdentifiers,
                excluding: seenIDs
            )
            seenIDs.formUnion(filterResult.newIdentifiers)

            let isImmediateCompleted = filterResult.newIdentifiers.isEmpty
            let card = StagingMemberAlbumCard(
                id: album.id,
                memberName: album.title,
                groupName: album.parentFolderTitle,
                enableEdgeDetection: album.enableEdgeDetection,
                sourceAssetIdentifiers: filterResult.newIdentifiers,
                coverAssetIdentifier: album.coverAssetIdentifier ?? filterResult.newIdentifiers.first,
                loadPhase: isImmediateCompleted ? .completed : .pending,
                slots: [],
                skippedDuplicateCount: filterResult.skippedDuplicateCount
            )
            builtCards.append(card)
        }

        self.cards = builtCards
        self.isSelectionMode = false
        self.selectedCardIDs = []
        self.customGroupNames = existingGroupNames
    }

    var sections: [StagingGroupSection] {
        var groupedDict: [String: [StagingMemberAlbumCard]] = [:]
        var canonicalDisplayTitle: [String: String] = [:]
        var groupKeyOrder: [String] = []
        var ungroupedCards: [StagingMemberAlbumCard] = []

        for card in cards {
            if let rawGroup = card.groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawGroup.isEmpty {
                let key = SystemAlbumExplorerService.normalizedNameKey(rawGroup)
                if groupedDict[key] == nil {
                    groupKeyOrder.append(key)
                    groupedDict[key] = []
                    canonicalDisplayTitle[key] = rawGroup
                }
                groupedDict[key]?.append(card)
            } else {
                ungroupedCards.append(card)
            }
        }

        var result: [StagingGroupSection] = []
        for key in groupKeyOrder {
            if let cardsInGroup = groupedDict[key], !cardsInGroup.isEmpty {
                let title = canonicalDisplayTitle[key] ?? key
                result.append(
                    StagingGroupSection(
                        id: "group-\(key)",
                        groupName: title,
                        displayTitle: title,
                        cards: cardsInGroup
                    )
                )
            }
        }

        if !ungroupedCards.isEmpty {
            result.append(
                StagingGroupSection(
                    id: "group-ungrouped",
                    groupName: nil,
                    displayTitle: L10n.tr("未分類", "未分類"),
                    cards: ungroupedCards
                )
            )
        }

        return result
    }

    var availableGroupNames: [String] {
        var seenKeys = Set<String>()
        var result: [String] = []
        for name in customGroupNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = SystemAlbumExplorerService.normalizedNameKey(trimmed)
            if !trimmed.isEmpty && seenKeys.insert(key).inserted {
                result.append(trimmed)
            }
        }
        for card in cards {
            if let g = card.groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !g.isEmpty {
                let key = SystemAlbumExplorerService.normalizedNameKey(g)
                if seenKeys.insert(key).inserted {
                    result.append(g)
                }
            }
        }
        return result
    }

    var allCardsLoaded: Bool {
        cards.allSatisfy { $0.loadPhase.isCompleted }
    }

    var totalActiveSlotCount: Int {
        cards.reduce(0) { $0 + $1.activeSlotCount }
    }

    var totalSkippedDuplicateCount: Int {
        cards.reduce(0) { $0 + $1.skippedDuplicateCount }
    }

    var overallProgressFraction: Double {
        guard !cards.isEmpty else { return 1.0 }
        let total = cards.reduce(0) { $0 + $1.sourceAssetIdentifiers.count }
        guard total > 0 else { return 1.0 }
        let loaded = cards.reduce(0) { sum, card in
            switch card.loadPhase {
            case .pending:
                return sum
            case .loading(let count, _):
                return sum + min(count, card.sourceAssetIdentifiers.count)
            case .completed:
                return sum + card.sourceAssetIdentifiers.count
            }
        }
        return min(1.0, max(0.0, Double(loaded) / Double(total)))
    }

    var canCommitImport: Bool {
        allCardsLoaded && totalActiveSlotCount > 0
    }

    mutating func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode {
            selectedCardIDs.removeAll()
        }
    }

    mutating func toggleCardSelection(_ cardID: String) {
        if selectedCardIDs.contains(cardID) {
            selectedCardIDs.remove(cardID)
        } else {
            selectedCardIDs.insert(cardID)
        }
    }

    mutating func selectAllCards() {
        selectedCardIDs = Set(cards.map(\.id))
    }

    mutating func clearCardSelection() {
        selectedCardIDs.removeAll()
    }

    mutating func assignSelectedCards(toGroup groupName: String?) {
        let trimmed: String? = {
            guard let name = groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return name
        }()

        if let validGroup = trimmed {
            let key = SystemAlbumExplorerService.normalizedNameKey(validGroup)
            if !customGroupNames.contains(where: { SystemAlbumExplorerService.normalizedNameKey($0) == key }) {
                customGroupNames.append(validGroup)
            }
        }

        for i in cards.indices where selectedCardIDs.contains(cards[i].id) {
            cards[i].groupName = trimmed
        }

        selectedCardIDs.removeAll()
        isSelectionMode = false
    }

    mutating func assignCard(_ cardID: String, toGroup groupName: String?) {
        let trimmed: String? = {
            guard let name = groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return name
        }()

        if let validGroup = trimmed {
            let key = SystemAlbumExplorerService.normalizedNameKey(validGroup)
            if !customGroupNames.contains(where: { SystemAlbumExplorerService.normalizedNameKey($0) == key }) {
                customGroupNames.append(validGroup)
            }
        }

        if let idx = cards.firstIndex(where: { $0.id == cardID }) {
            cards[idx].groupName = trimmed
        }
    }

    mutating func renameGroup(from oldGroupName: String, to newGroupName: String) {
        let trimmedOld = oldGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldKey = SystemAlbumExplorerService.normalizedNameKey(trimmedOld)
        guard !oldKey.isEmpty, trimmedOld != trimmedNew else { return }

        let targetGroup: String? = trimmedNew.isEmpty ? nil : trimmedNew

        if let idx = customGroupNames.firstIndex(where: { SystemAlbumExplorerService.normalizedNameKey($0) == oldKey }) {
            if let targetGroup {
                customGroupNames[idx] = targetGroup
            } else {
                customGroupNames.remove(at: idx)
            }
        } else if let targetGroup {
            let newKey = SystemAlbumExplorerService.normalizedNameKey(targetGroup)
            if !customGroupNames.contains(where: { SystemAlbumExplorerService.normalizedNameKey($0) == newKey }) {
                customGroupNames.append(targetGroup)
            }
        }

        for i in cards.indices {
            if let existing = cards[i].groupName,
               SystemAlbumExplorerService.normalizedNameKey(existing) == oldKey {
                cards[i].groupName = targetGroup
            }
        }
    }

    mutating func renameMemberCard(_ cardID: String, to newMemberName: String) {
        let trimmed = newMemberName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = cards.firstIndex(where: { $0.id == cardID }) {
            cards[idx].memberName = trimmed
        }
    }

    mutating func updateCardLoadProgress(_ cardID: String, loadedCount: Int, totalCount: Int) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        if totalCount <= 0 || loadedCount >= totalCount {
            cards[idx].loadPhase = .completed
        } else {
            cards[idx].loadPhase = .loading(loadedCount: loadedCount, totalCount: totalCount)
        }
    }

    mutating func appendLoadedSlot(_ slot: ChekiPairingSlot, toCard cardID: String) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        if let assetID = slot.frontPhoto.assetIdentifier,
           cards[idx].slots.contains(where: { $0.frontPhoto.assetIdentifier == assetID }) {
            return
        }
        cards[idx].slots.append(slot)
        if cards[idx].coverAssetIdentifier == nil {
            cards[idx].coverAssetIdentifier = slot.frontPhoto.assetIdentifier
        }
    }

    mutating func markCardCompleted(_ cardID: String) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx].loadPhase = .completed
    }

    mutating func updateCardSlots(_ cardID: String, slots: [ChekiPairingSlot]) {
        guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[idx].slots = slots
    }

    mutating func removeCard(_ cardID: String) {
        cards.removeAll(where: { $0.id == cardID })
        selectedCardIDs.remove(cardID)
    }

    mutating func removeSelectedCards() {
        cards.removeAll(where: { selectedCardIDs.contains($0.id) })
        selectedCardIDs.removeAll()
        isSelectionMode = false
    }
}

struct StagingAlbumPhotoProcessor {

    static func makePreCroppedStagingPhoto(
        from payload: SystemImportedAssetPayload,
        sequenceNumber: Int,
        recognizedOCRDate: Date?,
        fallbackDate: Date = Date()
    ) -> StagingChekiPhoto {
        StagingChekiPhoto(
            id: UUID(),
            sequenceNumber: sequenceNumber,
            title: "Photo #\(sequenceNumber)",
            assetIdentifier: payload.assetIdentifier,
            imageData: payload.imageData,
            uiImage: payload.uiImage,
            detectedSide: .likelyFront,
            detectionNote: "原圖直接匯入",
            croppedImageData: nil,
            croppedUIImage: nil,
            normalizedCornersJSON: nil,
            detectedOCRDate: recognizedOCRDate,
            hasManuallyModifiedDate: false,
            resolvedFilmFormat: payload.inferredFilmFormat,
            hasManuallyModifiedFormat: false,
            isDetectingBoundary: false,
            isImageReady: true,
            hasCompletedBoundaryDetection: true,
            isRevertedToOriginal: true,
            shutterDate: payload.creationDate ?? fallbackDate
        )
    }

    static func loadAndProcessSlot(
        for assetIdentifier: String,
        sequenceNumber: Int,
        enableEdgeDetection: Bool,
        borderInsetRatio: Double = 0.0,
        shouldRunOCR: Bool = true
    ) async -> ChekiPairingSlot? {
        guard let payload = await SystemAlbumExplorerService.shared.loadFullImagePayload(for: assetIdentifier) else {
            return nil
        }

        let visionManager = VisionManager()

        if !enableEdgeDetection {
            var recognizedDate: Date? = nil
            if shouldRunOCR, let cgImage = payload.uiImage.cgImage {
                recognizedDate = await visionManager.recognizeDate(from: cgImage)?.date
            }
            let photo = makePreCroppedStagingPhoto(
                from: payload,
                sequenceNumber: sequenceNumber,
                recognizedOCRDate: recognizedDate
            )
            return ChekiPairingSlot(id: UUID(), frontPhoto: photo, backPhoto: nil, assignedMembers: [])
        }

        guard let cgImage = payload.uiImage.cgImage else {
            let fallbackPhoto = makePreCroppedStagingPhoto(
                from: payload,
                sequenceNumber: sequenceNumber,
                recognizedOCRDate: nil
            )
            return ChekiPairingSlot(id: UUID(), frontPhoto: fallbackPhoto, backPhoto: nil, assignedMembers: [])
        }

        let imgSize = CGSize(width: cgImage.width, height: cgImage.height)

        if let detection = try? await visionManager.detectQuad(in: cgImage, imageSize: imgSize) {
            let adjustedCorners = await visionManager.applyBorderInset(
                corners: detection.corners,
                imageSize: imgSize,
                ratio: borderInsetRatio
            )

            if let cropRes = try? await visionManager.perspectiveCorrect(
                image: cgImage,
                corners: adjustedCorners,
                detection: detection,
                format: .auto
            ) {
                let croppedUI = UIImage(cgImage: cropRes.cgImage)
                let croppedData = croppedUI.jpegData(compressionQuality: 0.92)
                let cornersJSON = ChekiItem.encodeNormalizedCorners(adjustedCorners, imageSize: imgSize)
                let resolvedFormat = FilmFormat.resolvedConcreteFormat(
                    preferred: .auto,
                    specName: cropRes.filmSpecification?.format.rawValue,
                    outputSize: cropRes.outputSize
                )

                var ocrDate: Date? = nil
                if shouldRunOCR {
                    if let res = await visionManager.recognizeDate(from: cropRes.cgImage) {
                        ocrDate = res.date
                    } else if let fallbackRes = await visionManager.recognizeDate(from: cgImage) {
                        ocrDate = fallbackRes.date
                    }
                }

                let frontPhoto = StagingChekiPhoto(
                    id: UUID(),
                    sequenceNumber: sequenceNumber,
                    title: "Photo #\(sequenceNumber)",
                    assetIdentifier: payload.assetIdentifier,
                    imageData: payload.imageData,
                    uiImage: payload.uiImage,
                    detectedSide: .likelyFront,
                    detectionNote: "Vision 自動裁切",
                    croppedImageData: croppedData,
                    croppedUIImage: croppedUI,
                    normalizedCornersJSON: cornersJSON,
                    detectedOCRDate: ocrDate,
                    hasManuallyModifiedDate: false,
                    resolvedFilmFormat: resolvedFormat,
                    hasManuallyModifiedFormat: false,
                    isDetectingBoundary: false,
                    isImageReady: true,
                    hasCompletedBoundaryDetection: true,
                    isRevertedToOriginal: false,
                    shutterDate: payload.creationDate ?? Date()
                )

                return ChekiPairingSlot(id: UUID(), frontPhoto: frontPhoto, backPhoto: nil, assignedMembers: [])
            }
        }

        var fallbackOCR: Date? = nil
        if shouldRunOCR {
            fallbackOCR = await visionManager.recognizeDate(from: cgImage)?.date
        }

        let fallbackPhoto = makePreCroppedStagingPhoto(
            from: payload,
            sequenceNumber: sequenceNumber,
            recognizedOCRDate: fallbackOCR
        )
        return ChekiPairingSlot(id: UUID(), frontPhoto: fallbackPhoto, backPhoto: nil, assignedMembers: [])
    }
}

struct StagingMemberCardCell: View {
    let card: StagingMemberAlbumCard
    let isSelected: Bool
    let isSelectionMode: Bool
    var onToggleSelect: () -> Void
    var onTapCard: () -> Void
    var onRenameMember: () -> Void
    var onAssignGroup: (String?) -> Void
    var onRemoveCard: (() -> Void)? = nil
    var availableGroups: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                previewContainerView
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if isSelectionMode {
                    selectionBadgeView
                        .padding(8)
                }

                if card.loadPhase.isLoading {
                    loadingBadgeView
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(card.memberName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                statusSubtitleView
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.blue.opacity(0.10) : Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.blue : Color(.separator).opacity(0.35), lineWidth: isSelected ? 2.0 : 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if isSelectionMode {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onToggleSelect()
            } else {
                onTapCard()
            }
        }
        .contextMenu {
            cardContextMenu
        }
        .accessibilityIdentifier("staging.card.\(card.id)")
    }

    @ViewBuilder
    private var previewContainerView: some View {
        if let previewImage = card.previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let coverID = card.coverAssetIdentifier {
            SystemAlbumThumbnailView(assetIdentifier: coverID, sideLength: 140)
        } else {
            Color(.tertiarySystemFill)
                .overlay {
                    Image(systemName: "photo.stack")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var selectionBadgeView: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? .blue : .white)
            .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.40)).padding(2))
    }

    private var loadingBadgeView: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
            if case .loading(let count, let total) = card.loadPhase {
                Text("\(count)/\(total)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.65), in: Capsule())
    }

    @ViewBuilder
    private var statusSubtitleView: some View {
        switch card.loadPhase {
        case .pending:
            Text(L10n.tr("等待讀入…", "待機中…"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .loading(let count, let total):
            Text(L10n.tr("讀入中 \(count)/\(total)", "読込中 \(count)/\(total)"))
                .font(.caption2)
                .foregroundStyle(.blue)
        case .completed:
            HStack(spacing: 4) {
                Text(L10n.tr("\(card.slots.count) 張", "\(card.slots.count)枚"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if card.pairedSlotCount > 0 {
                    Text(L10n.tr("· \(card.pairedSlotCount) 組雙面", "· \(card.pairedSlotCount)組両面"))
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                if card.skippedDuplicateCount > 0 {
                    Text(L10n.tr("· 略過 \(card.skippedDuplicateCount)", "· 重複 \(card.skippedDuplicateCount)"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var cardContextMenu: some View {
        Button(action: onRenameMember) {
            Label(L10n.tr("重新命名成員", "メンバー名を変更"), systemImage: "pencil")
        }

        Menu {
            ForEach(availableGroups, id: \.self) { g in
                Button(g) {
                    onAssignGroup(g)
                }
            }
            Divider()
            Button(L10n.tr("移至未分類", "未分類に移動")) {
                onAssignGroup(nil)
            }
        } label: {
            Label(L10n.tr("歸類團體", "グループ変更"), systemImage: "folder")
        }

        if card.isReadyForInspection {
            Divider()
            Button(action: onTapCard) {
                Label(L10n.tr("檢視相片", "写真を確認"), systemImage: "photo.on.rectangle")
            }
        }

        if let onRemoveCard {
            Divider()
            Button(role: .destructive, action: onRemoveCard) {
                Label(L10n.tr("排除此相冊", "このアルバムを除外"), systemImage: "trash")
            }
        }
    }
}

struct StagingImportShelfView: View {
    @Binding var state: StagingImportShelfState
    var onCancel: (() -> Void)? = nil
    var onCommitImport: (([StagingMemberAlbumCard]) -> Void)? = nil
    var onInspectCard: ((StagingMemberAlbumCard) -> Void)? = nil
    var onFinishCommit: ((AlbumImportCommitResult) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @AppStorage("defaultBorderInsetPercentage") private var defaultBorderInsetPercentage: Double = 0.0
    @AppStorage("autoRecognizeOCRDateOnImport") private var autoRecognizeOCRDateOnImport: Bool = true

    @State private var showingNewGroupAlert: Bool = false
    @State private var showingRenameGroupAlert: Bool = false
    @State private var showingRenameMemberAlert: Bool = false

    @State private var inputGroupName: String = ""
    @State private var inputMemberName: String = ""
    @State private var targetOldGroupName: String = ""
    @State private var targetCardIDForAction: String = ""
    @State private var inspectingCard: StagingMemberAlbumCard? = nil
    @State private var commitResultForAlert: AlbumImportCommitResult? = nil
    @State private var commitErrorMessage: String? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !state.allCardsLoaded {
                    overallProgressBar
                }

                if state.isSelectionMode {
                    selectionControlBar
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(state.sections) { section in
                            sectionBlock(section)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                bottomCommitBar
            }
            .navigationTitle(L10n.tr("匯入工作台", "ワークベンチ"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CloseToolbarButton(accessibilityIdentifier: "chrome.staging.shelf.close") {
                        onCancel?()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(ChekiMotion.toggle) {
                                state.toggleSelectionMode()
                            }
                        } label: {
                            Image(systemName: state.isSelectionMode ? "checkmark.circle.fill" : "checklist")
                                .foregroundStyle(state.isSelectionMode ? .blue : .primary)
                        }
                        .accessibilityLabel(
                            state.isSelectionMode
                                ? L10n.tr("結束批次選取", "一括選択を終了")
                                : L10n.tr("批次選取成員", "メンバーを一括選択")
                        )
                        .accessibilityIdentifier("staging.shelf.selectModeToggle")

                        ConfirmToolbarButton(accessibilityIdentifier: "chrome.staging.shelf.confirm") {
                            handleConfirmImport()
                        }
                        .disabled(!state.canCommitImport)
                    }
                }
            }
            .alert(L10n.tr("新增團體", "グループを新規作成"), isPresented: $showingNewGroupAlert) {
                TextField(L10n.tr("團體名稱", "グループ名"), text: $inputGroupName)
                Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                    inputGroupName = ""
                }
                Button(L10n.tr("確定", "OK")) {
                    handleConfirmNewGroup()
                }
            }
            .alert(L10n.tr("重新命名團體", "グループ名を変更"), isPresented: $showingRenameGroupAlert) {
                TextField(L10n.tr("團體名稱", "グループ名"), text: $inputGroupName)
                Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                    inputGroupName = ""
                    targetOldGroupName = ""
                }
                Button(L10n.tr("確定", "OK")) {
                    withAnimation(ChekiMotion.toggle) {
                        state.renameGroup(from: targetOldGroupName, to: inputGroupName)
                    }
                    inputGroupName = ""
                    targetOldGroupName = ""
                }
            }
            .alert(L10n.tr("重新命名成員", "メンバー名を変更"), isPresented: $showingRenameMemberAlert) {
                TextField(L10n.tr("成員名稱", "メンバー名"), text: $inputMemberName)
                Button(L10n.tr("取消", "キャンセル"), role: .cancel) {
                    inputMemberName = ""
                    targetCardIDForAction = ""
                }
                Button(L10n.tr("確定", "OK")) {
                    withAnimation(ChekiMotion.toggle) {
                        state.renameMemberCard(targetCardIDForAction, to: inputMemberName)
                    }
                    inputMemberName = ""
                    targetCardIDForAction = ""
                }
            }
            .fullScreenCover(item: $inspectingCard) { card in
                BatchPairingView(
                    initialPreloadedSlots: card.slots,
                    stagingHeaderTitle: card.memberName,
                    stagingGroupTitle: card.groupName,
                    onCompleteStagingEdit: { updatedSlots in
                        state.updateCardSlots(card.id, slots: updatedSlots)
                    }
                )
            }
            .alert(
                L10n.tr("匯入完成", "インポート完了"),
                isPresented: Binding(
                    get: { commitResultForAlert != nil },
                    set: { if !$0 { commitResultForAlert = nil } }
                ),
                presenting: commitResultForAlert
            ) { result in
                Button(L10n.tr("確定", "OK")) {
                    let finalResult = result
                    commitResultForAlert = nil
                    onFinishCommit?(finalResult)
                }
            } message: { result in
                Text(result.localizedSummaryMessage)
            }
            .alert(
                L10n.tr("匯入失敗", "インポート失敗"),
                isPresented: Binding(
                    get: { commitErrorMessage != nil },
                    set: { if !$0 { commitErrorMessage = nil } }
                )
            ) {
                Button(L10n.tr("確定", "OK"), role: .cancel) {
                    commitErrorMessage = nil
                }
            } message: {
                Text(commitErrorMessage ?? "")
            }
        }
        .task {
            await startBackgroundProcessing()
        }
    }

    private var overallProgressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text(L10n.tr("相片背景讀入中…", "写真をバックグラウンドで読込中…"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(state.overallProgressFraction * 100))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: state.overallProgressFraction)
                .tint(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var selectionControlBar: some View {
        HStack(spacing: 12) {
            Text(L10n.tr("已選 \(state.selectedCardIDs.count) 本相冊", "\(state.selectedCardIDs.count)冊を選択中"))
                .font(.subheadline.weight(.semibold))

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(ChekiMotion.toggle) {
                    if state.selectedCardIDs.count == state.cards.count {
                        state.clearCardSelection()
                    } else {
                        state.selectAllCards()
                    }
                }
            } label: {
                Text(state.selectedCardIDs.count == state.cards.count ? L10n.tr("取消全選", "選択解除") : L10n.tr("全選", "すべて選択"))
                    .font(.caption.weight(.medium))
            }
            .accessibilityIdentifier("staging.shelf.selectAllCards")

            Menu {
                ForEach(state.availableGroupNames, id: \.self) { g in
                    Button(g) {
                        withAnimation(ChekiMotion.toggle) {
                            state.assignSelectedCards(toGroup: g)
                        }
                    }
                }
                Divider()
                Button(L10n.tr("新增團體…", "グループを新規作成…")) {
                    inputGroupName = ""
                    showingNewGroupAlert = true
                }
                Button(L10n.tr("移至未分類", "未分類に移動")) {
                    withAnimation(ChekiMotion.toggle) {
                        state.assignSelectedCards(toGroup: nil)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.gearshape")
                    Text(L10n.tr("指派團體", "グループ設定"))
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.12), in: Capsule())
            }
            .disabled(state.selectedCardIDs.isEmpty)
            .accessibilityIdentifier("staging.shelf.assignGroupMenu")
            if !state.selectedCardIDs.isEmpty {
                Button(role: .destructive) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(ChekiMotion.toggle) {
                        state.removeSelectedCards()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text(L10n.tr("排除", "除外"))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("staging.shelf.removeSelectedCards")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground))
    }

    @ViewBuilder
    private func sectionBlock(_ section: StagingGroupSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("\(section.cards.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())

                Spacer()

                if let g = section.groupName {
                    Menu {
                        Button {
                            targetOldGroupName = g
                            inputGroupName = g
                            showingRenameGroupAlert = true
                        } label: {
                            Label(L10n.tr("重新命名團體", "グループ名を変更"), systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(section.cards) { card in
                    StagingMemberCardCell(
                        card: card,
                        isSelected: state.selectedCardIDs.contains(card.id),
                        isSelectionMode: state.isSelectionMode,
                        onToggleSelect: {
                            state.toggleCardSelection(card.id)
                        },
                        onTapCard: {
                            if card.isReadyForInspection {
                                inspectingCard = card
                                onInspectCard?(card)
                            }
                        },
                        onRenameMember: {
                            targetCardIDForAction = card.id
                            inputMemberName = card.memberName
                            showingRenameMemberAlert = true
                        },
                        onAssignGroup: { newGroup in
                            withAnimation(ChekiMotion.toggle) {
                                state.assignCard(card.id, toGroup: newGroup)
                            }
                        },
                        onRemoveCard: {
                            withAnimation(ChekiMotion.toggle) {
                                state.removeCard(card.id)
                            }
                        },
                        availableGroups: state.availableGroupNames
                    )
                }
            }
        }
    }

    private var bottomCommitBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("\(state.cards.count) 個成員相冊", "\(state.cards.count)個のメンバーアルバム"))
                        .font(.headline)
                    Text(L10n.tr("共 \(state.totalActiveSlotCount) 張相片", "計 \(state.totalActiveSlotCount) 枚"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    handleConfirmImport()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc.fill")
                        Text(state.allCardsLoaded
                            ? L10n.tr("確認匯入", "インポート実行")
                            : L10n.tr("讀取中…", "読込中…"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canCommitImport)
                .accessibilityIdentifier("staging.shelf.commitImport")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
    }

    private func handleConfirmImport() {
        if let onCommitImport {
            onCommitImport(state.cards)
            return
        }
        do {
            let ratio = defaultBorderInsetPercentage / 100.0
            let result = try AlbumImportCommitEngine.commit(
                cards: state.cards,
                in: modelContext,
                borderInsetRatio: ratio
            )
            commitResultForAlert = result
        } catch {
            commitErrorMessage = error.localizedDescription
        }
    }

    private func handleConfirmNewGroup() {
        let trimmed = inputGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(ChekiMotion.toggle) {
            if state.isSelectionMode && !state.selectedCardIDs.isEmpty {
                state.assignSelectedCards(toGroup: trimmed)
            } else if !targetCardIDForAction.isEmpty {
                state.assignCard(targetCardIDForAction, toGroup: trimmed)
            }
        }
        inputGroupName = ""
        targetCardIDForAction = ""
    }

    private func startBackgroundProcessing() async {
        let defaultInset = defaultBorderInsetPercentage / 100.0
        let shouldOCR = autoRecognizeOCRDateOnImport

        for card in state.cards {
            if card.loadPhase.isCompleted { continue }
            let total = card.sourceAssetIdentifiers.count
            guard total > 0 else {
                state.markCardCompleted(card.id)
                continue
            }

            state.updateCardLoadProgress(card.id, loadedCount: card.slots.count, totalCount: total)

            for (index, assetID) in card.sourceAssetIdentifiers.enumerated() {
                if Task.isCancelled { return }
                let alreadyLoaded = state.cards
                    .first(where: { $0.id == card.id })?
                    .slots
                    .contains(where: { $0.frontPhoto.assetIdentifier == assetID }) ?? false
                if alreadyLoaded {
                    state.updateCardLoadProgress(card.id, loadedCount: index + 1, totalCount: total)
                    continue
                }

                let slot = await StagingAlbumPhotoProcessor.loadAndProcessSlot(
                    for: assetID,
                    sequenceNumber: index + 1,
                    enableEdgeDetection: card.enableEdgeDetection,
                    borderInsetRatio: defaultInset,
                    shouldRunOCR: shouldOCR
                )
                if let slot {
                    state.appendLoadedSlot(slot, toCard: card.id)
                }
                state.updateCardLoadProgress(card.id, loadedCount: index + 1, totalCount: total)
            }
            state.markCardCompleted(card.id)
        }
    }
}
