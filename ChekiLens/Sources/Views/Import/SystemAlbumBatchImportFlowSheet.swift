import SwiftUI
import SwiftData

enum SystemAlbumBatchImportFlowStep: Equatable {
    case selectingAlbums
    case stagingShelf(StagingImportShelfState)
}

struct SystemAlbumBatchImportFlowState: Equatable {
    var step: SystemAlbumBatchImportFlowStep = .selectingAlbums
    var selectionState: SystemAlbumSelectionState = SystemAlbumSelectionState()

    mutating func advanceToStagingShelf(
        selectedAlbums: [SystemPhotoAlbumNode],
        existingGroupNames: [String] = [],
        existingAssetIDs: Set<String> = []
    ) {
        guard !selectedAlbums.isEmpty else { return }
        let shelfState = StagingImportShelfState(
            albums: selectedAlbums,
            existingGroupNames: existingGroupNames,
            existingAssetIDs: existingAssetIDs
        )
        step = .stagingShelf(shelfState)
    }

    mutating func returnToAlbumSelection() {
        step = .selectingAlbums
    }
}

struct SystemAlbumBatchImportFlowSheet: View {
    var selectAllByDefault: Bool = false
    var onFinished: ((AlbumImportCommitResult?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \IdolGroup.sortOrder, order: .forward) private var idolGroups: [IdolGroup]
    @Query private var chekiItems: [ChekiItem]

    @State private var flowState = SystemAlbumBatchImportFlowState()

    private var existingGroupNames: [String] {
        idolGroups
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .map(\.name)
    }

    private var existingAssetIDs: Set<String> {
        let validItems = chekiItems.filter { !$0.isDeleted && $0.modelContext != nil }
        return SystemAlbumExplorerService.collectExistingAssetIdentifiers(from: validItems)
    }

    var body: some View {
        Group {
            switch flowState.step {
            case .selectingAlbums:
                SystemAlbumSelectionSheet(
                    state: $flowState.selectionState,
                    selectAllByDefault: selectAllByDefault,
                    dismissOnConfirm: false,
                    onCancel: {
                        onFinished?(nil)
                        dismiss()
                    },
                    onConfirm: { selectedAlbums in
                        withAnimation(ChekiMotion.toggle) {
                            flowState.advanceToStagingShelf(
                                selectedAlbums: selectedAlbums,
                                existingGroupNames: existingGroupNames,
                                existingAssetIDs: existingAssetIDs
                            )
                        }
                    }
                )
            case .stagingShelf:
                StagingImportShelfView(
                    state: stagingShelfBinding,
                    onCancel: {
                        withAnimation(ChekiMotion.toggle) {
                            flowState.returnToAlbumSelection()
                        }
                    },
                    onFinishCommit: { result in
                        onFinished?(result)
                        dismiss()
                    }
                )
            }
        }
    }

    private var stagingShelfBinding: Binding<StagingImportShelfState> {
        Binding(
            get: {
                if case .stagingShelf(let shelfState) = flowState.step {
                    return shelfState
                }
                return StagingImportShelfState(albums: [])
            },
            set: { updatedShelf in
                if case .stagingShelf = flowState.step {
                    flowState.step = .stagingShelf(updatedShelf)
                }
            }
        )
    }
}
