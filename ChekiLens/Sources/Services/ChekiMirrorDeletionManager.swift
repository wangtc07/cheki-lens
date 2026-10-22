import Foundation
import SwiftData
import Photos
import OSLog

// MARK: - Reconcile Result

/// 鏡像刪除與復原調和結果摘要
struct MirrorDeletionReconcileResult: Equatable, Sendable {
    var assetsDeletedCount: Int
    var assetsRestoredCount: Int
    var processedItemCount: Int

    init(assetsDeletedCount: Int = 0, assetsRestoredCount: Int = 0, processedItemCount: Int = 0) {
        self.assetsDeletedCount = assetsDeletedCount
        self.assetsRestoredCount = assetsRestoredCount
        self.processedItemCount = processedItemCount
    }
}

// MARK: - Adapter Protocol

/// 系統相簿操作協議（支援 Live 與 Mock 注入測試）
protocol MirrorPhotoLibraryAdapter: Sendable {
    func assetExists(localIdentifier: String) -> Bool
    func deleteAssets(identifiers: [String]) async
    func syncItemsToLibrary(_ items: [ChekiItem], modelContext: ModelContext) async
}

// MARK: - Live Adapter

/// 正式環境相簿介面介接
final class LiveMirrorPhotoLibraryAdapter: MirrorPhotoLibraryAdapter, @unchecked Sendable {
    init() {}

    func assetExists(localIdentifier: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).count > 0
    }

    func deleteAssets(identifiers: [String]) async {
        await PhotoLibraryManager.shared.deleteAssetsFromSystemPhotoLibrary(identifiers: identifiers)
    }

    func syncItemsToLibrary(_ items: [ChekiItem], modelContext: ModelContext) async {
        await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
            items,
            modelContext: modelContext,
            onlyAlbumAndDateIfAlreadySynced: false
        )
    }
}

// MARK: - Mock Adapter

/// 單元測試使用之 Mock 介面
final class MockMirrorPhotoLibraryAdapter: MirrorPhotoLibraryAdapter, @unchecked Sendable {
    var existingAssetIDs: Set<String>
    var deletedAssetIDs: [String] = []
    var syncedItemIDs: [UUID] = []

    init(existingAssetIDs: Set<String> = []) {
        self.existingAssetIDs = existingAssetIDs
    }

    func assetExists(localIdentifier: String) -> Bool {
        existingAssetIDs.contains(localIdentifier)
    }

    func deleteAssets(identifiers: [String]) async {
        deletedAssetIDs.append(contentsOf: identifiers)
        for id in identifiers {
            existingAssetIDs.remove(id)
        }
    }

    func syncItemsToLibrary(_ items: [ChekiItem], modelContext: ModelContext) async {
        syncedItemIDs.append(contentsOf: items.map(\.id))
        for item in items {
            item.isSyncedToPhotoLibrary = true
        }
    }
}

// MARK: - ChekiMirrorDeletionManager

/// 負責多裝置雲端刪除與復原之嚴格鏡像同步服務
/// - 當遠端裝置標記軟刪除並同步至本機時，若本機開啟「同步刪除系統相片」，本機非同步將對應照片自 Photos 移入最近刪除
/// - 當遠端裝置復原卡片時，若本機開啟相簿同步，本機自動重新將照片同步回系統相簿
@MainActor
final class ChekiMirrorDeletionManager {

    static let shared = ChekiMirrorDeletionManager()

    private let logger = Logger(subsystem: "com.chekilens.app", category: "ChekiMirrorDeletionManager")

    private var remoteChangeListenerTask: Task<Void, Never>?
    var adapter: MirrorPhotoLibraryAdapter

    init(adapter: MirrorPhotoLibraryAdapter = LiveMirrorPhotoLibraryAdapter()) {
        self.adapter = adapter
    }

    deinit {
        remoteChangeListenerTask?.cancel()
    }

    /// 啟動遠端儲存庫變更監聽器（監聽 SwiftData / CoreData RemoteChange 通知）
    func startListeningForRemoteChanges(modelContext: ModelContext) {
        remoteChangeListenerTask?.cancel()
        remoteChangeListenerTask = Task { [weak self] in
            let remoteChangeName = Notification.Name("NSPersistentStoreRemoteChangeNotification")
            for await _ in NotificationCenter.default.notifications(named: remoteChangeName) {
                guard let self else { return }
                self.logger.info("檢測到遠端資料庫變更通知，啟動鏡像刪除與復原調和")
                let autoSync = UserDefaults.standard.bool(forKey: "autoSyncToPhotosLibrary")
                _ = await self.reconcileMirrorDeletions(in: modelContext, autoDeleteFromPhotos: autoSync)
            }
        }
    }

    /// 執行鏡像刪除與復原調和管線
    @discardableResult
    func reconcileMirrorDeletions(
        in modelContext: ModelContext,
        autoDeleteFromPhotos: Bool
    ) async -> MirrorDeletionReconcileResult {
        var result = MirrorDeletionReconcileResult()

        guard let allItems = try? modelContext.fetch(FetchDescriptor<ChekiItem>()) else {
            return result
        }

        result.processedItemCount = allItems.count

        // 1. 處理遠端軟刪除鏡像（deletedAt != nil 且本機相簿中尚存在對應 PHAsset）
        let trashedItems = allItems.filter(\.isDeleted)
        if autoDeleteFromPhotos && !trashedItems.isEmpty {
            var assetIDsToDelete: [String] = []

            for item in trashedItems {
                var candidateIDs: [String] = []
                if let frontID = item.frontAssetIdentifier, !frontID.isEmpty {
                    candidateIDs.append(frontID)
                }
                if let backID = item.backAssetIdentifier, !backID.isEmpty {
                    candidateIDs.append(backID)
                }

                guard !candidateIDs.isEmpty else { continue }

                // 檢查這些 ID 在本機系統相簿中是否仍然存在
                let existing = candidateIDs.filter { adapter.assetExists(localIdentifier: $0) }
                if !existing.isEmpty {
                    assetIDsToDelete.append(contentsOf: existing)
                    item.isSyncedToPhotoLibrary = false
                }
            }

            if !assetIDsToDelete.isEmpty {
                logger.info("鏡像同步：準備自系統相簿移入最近刪除 \(assetIDsToDelete.count) 張照片")
                await adapter.deleteAssets(identifiers: assetIDsToDelete)
                result.assetsDeletedCount = assetIDsToDelete.count
                try? modelContext.save()
            }
        }

        // 2. 處理遠端復原鏡像（deletedAt == nil 但曾被標記為未同步或需重新匯出至相簿）
        let activeItems = allItems.filter { !$0.isDeleted }
        if autoDeleteFromPhotos && !activeItems.isEmpty {
            var itemsNeedingPhotoSync: [ChekiItem] = []

            for item in activeItems {
                if !item.isSyncedToPhotoLibrary && item.frontImageData != nil {
                    if let frontID = item.frontAssetIdentifier {
                        if !adapter.assetExists(localIdentifier: frontID) {
                            itemsNeedingPhotoSync.append(item)
                        } else {
                            item.isSyncedToPhotoLibrary = true
                        }
                    } else {
                        itemsNeedingPhotoSync.append(item)
                    }
                }
            }

            if !itemsNeedingPhotoSync.isEmpty {
                logger.info("鏡像同步：遠端復原後重新同步 \(itemsNeedingPhotoSync.count) 張拍立得至系統相簿")
                await adapter.syncItemsToLibrary(itemsNeedingPhotoSync, modelContext: modelContext)
                result.assetsRestoredCount = itemsNeedingPhotoSync.count
                try? modelContext.save()
            }
        }

        return result
    }
}
