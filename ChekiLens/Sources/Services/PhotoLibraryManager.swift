import Foundation
import Photos
import UIKit
import CoreImage
import SwiftUI
import SwiftData
import OSLog

@Observable
final class PhotoLibraryManager {
    static let shared = PhotoLibraryManager()
    
    var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private let logger = Logger(subsystem: "com.chekilens.app", category: "PhotoLibrary")
    
    /// 是否已解鎖 ChekiLens Pro 終身買斷版
    static var isProLifetimeUnlocked: Bool {
        UserDefaults.standard.bool(forKey: "isProLifetimeUnlocked")
    }
    
    // MARK: - Authorization
    
    /// 檢查並更新目前的相簿權限狀態
    func checkAuthorizationStatus() {
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
    
    /// 請求相簿權限
    func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            self.authorizationStatus = status
        }
        return status == .authorized || status == .limited
    }
    
    // MARK: - Album Management
    
    /// 取得或建立指定的相簿 (Album)
    /// - Parameters:
    ///   - albumName: 相簿名稱 (例如：成員名稱)
    ///   - folderName: 父資料夾名稱 (例如：ChekiLens 或 團體名稱)。若為 nil 則建立在根目錄
    func getOrCreateAlbum(albumName: String, inFolder folderName: String? = nil) async throws -> PHAssetCollection {
        // 確保有權限
        guard await requestAuthorization() else {
            throw NSError(domain: "PhotoLibraryManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "無相簿權限"])
        }
        
        var targetFolder: PHCollectionList? = nil
        
        // 1. 若有指定資料夾，先取得或建立資料夾
        if let folderName = folderName {
            targetFolder = try await getOrCreateFolder(folderName: folderName)
        }
        
        // 2. 尋找現有相簿（使用安全的列舉比對 localizedTitle，避免部分 iOS 版本因 predicate key 拋出例外）
        if let folder = targetFolder {
            let query = PHCollectionList.fetchCollections(in: folder, options: nil)
            var foundAlbum: PHAssetCollection? = nil
            query.enumerateObjects { (collection, _, stop) in
                if let album = collection as? PHAssetCollection, album.localizedTitle == albumName {
                    foundAlbum = album
                    stop.pointee = true
                }
            }
            if let found = foundAlbum {
                return found
            }
        } else {
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var foundAlbum: PHAssetCollection? = nil
            collections.enumerateObjects { (album, _, stop) in
                if album.localizedTitle == albumName {
                    foundAlbum = album
                    stop.pointee = true
                }
            }
            if let found = foundAlbum {
                return found
            }
        }
        
        // 3. 建立新相簿
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            placeholder = createRequest.placeholderForCreatedAssetCollection
            
            // 如果有父資料夾，將新相簿加入該資料夾
            if let folder = targetFolder, let placeholder = placeholder {
                guard let folderChangeRequest = PHCollectionListChangeRequest(for: folder) else { return }
                folderChangeRequest.addChildCollections([placeholder] as NSArray)
            }
        }
        
        guard let placeholder = placeholder,
              let createdAlbum = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil).firstObject else {
            throw NSError(domain: "PhotoLibraryManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "建立相簿失敗"])
        }
        
        return createdAlbum
    }
    
    /// 取得或建立資料夾 (Folder)
    private func getOrCreateFolder(folderName: String) async throws -> PHCollectionList {
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: nil)
        var existingFolder: PHCollectionList? = nil
        folders.enumerateObjects { (folder, _, stop) in
            if folder.localizedTitle == folderName {
                existingFolder = folder
                stop.pointee = true
            }
        }
        if let folder = existingFolder {
            return folder
        }
        
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let createRequest = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: folderName)
            placeholder = createRequest.placeholderForCreatedCollectionList
        }
        
        guard let placeholder = placeholder,
              let createdFolder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [placeholder.localIdentifier], options: nil).firstObject else {
            throw NSError(domain: "PhotoLibraryManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "建立資料夾失敗"])
        }
        
        return createdFolder
    }
    
    // MARK: - Save & Non-Destructive In-Place Edit Image
    
    /// 同步照片至 iOS 系統相簿（依免費版 / Pro 版區分裁切寫入行為）：
    /// - **免費版 (`isProLifetimeUnlocked == false`)**：原生相簿**不裁切**（保留未裁切原圖），但依然可同步歸檔至 `ChekiLens › 團體 › 成員` 相簿階層並寫入 OCR 拍攝時間軸；裁切後的照片僅在 App 內（加上浮水印）查看，分享或輸出時亦加上浮水印。
    /// - **Pro 終身買斷版 (`isProLifetimeUnlocked == true`)**：
    ///   - 若為系統相簿既有照片 (`existingAssetIdentifier != nil`)，以 `PHContentEditingOutput` 非破壞性原地修改為裁切後拍立得（不新增重複照片，且保留原始底圖供隨時復原）。
    ///   - 若為 App 內相機新拍攝的照片 (`existingAssetIdentifier == nil`)，直接將正位裁切／去反光後的成品存入系統相簿（避免觸發二次修改系統彈窗，同時在 App 內 SwiftData 完整保留 `originalFrontImageData` 供隨時復原）。
    /// - Returns: 該張照片在系統相簿中的 `PHAsset.localIdentifier`
    func updateOrSaveImage(
        _ image: UIImage,
        originalImageData: Data? = nil,
        existingAssetIdentifier: String? = nil,
        creationDate: Date,
        to album: PHAssetCollection? = nil
    ) async throws -> String {
        guard await requestAuthorization() else {
            throw NSError(domain: "PhotoLibraryManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "無相簿權限"])
        }
        
        let isPro = Self.isProLifetimeUnlocked
        
        // 1. 若已有現存 PHAsset
        if let existingId = existingAssetIdentifier,
           !existingId.isEmpty,
           let existingAsset = PHAsset.fetchAssets(withLocalIdentifiers: [existingId], options: nil).firstObject {
            if isPro {
                // Pro 版：直接以 PHContentEditingOutput 非破壞性修改原圖為裁切後拍立得（不新增照片，且保留原始底圖可復原）
                // 若因權限或系統取消原地修改，仍確保將該張照片歸入對應系統相簿與時間軸
                do {
                    try await modifyAssetInPlace(
                        asset: existingAsset,
                        croppedImage: image,
                        creationDate: creationDate,
                        album: album
                    )
                } catch {
                    try? await PHPhotoLibrary.shared().performChanges {
                        let changeRequest = PHAssetChangeRequest(for: existingAsset)
                        changeRequest.creationDate = creationDate
                        if let album {
                            let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                            albumChangeRequest?.addAssets([existingAsset] as NSArray)
                        }
                    }
                }
            } else {
                // 免費版：原生相簿不裁切（維持未裁切原圖），但同步寫入拍攝時間軸與相簿分類
                try await PHPhotoLibrary.shared().performChanges {
                    let changeRequest = PHAssetChangeRequest(for: existingAsset)
                    changeRequest.creationDate = creationDate
                    if let album {
                        let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                        albumChangeRequest?.addAssets([existingAsset] as NSArray)
                    }
                }
            }
            Self.recordAssetSyncedTimestamp(for: existingAsset.localIdentifier)
            return existingAsset.localIdentifier
        }
        
        // 2. 若尚未存在於系統相簿（例如使用 App 內建相機拍攝）：
        // - Pro 版：直接將正位裁切／Mode B 去反光後的成品存入系統相簿（單次寫入、零彈窗、極速完成；原始未裁切底圖已保存在 SwiftData 供隨時復原）
        // - 免費版：依規則於原生相簿保留未裁切原圖（若無原圖則存 croppedJPEG）
        guard let croppedJPEG = image.jpegData(compressionQuality: 0.92) else {
            throw NSError(domain: "PhotoLibraryManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "影像編碼失敗"])
        }
        let dataToSave = isPro ? croppedJPEG : (originalImageData ?? croppedJPEG)
        var placeholderId: String?
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: dataToSave, options: nil)
                creationRequest.creationDate = creationDate
                
                if let album = album, let placeholder = creationRequest.placeholderForCreatedAsset {
                    let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                    albumChangeRequest?.addAssets([placeholder] as NSArray)
                }
                placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            // 若因相簿權限（如 .limited 選取照片模式）導致加入相簿失敗，自動回退為直接寫入系統「最近項目 (Camera Roll)」
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: dataToSave, options: nil)
                creationRequest.creationDate = creationDate
                placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
            }
        }
        
        guard let createdId = placeholderId else {
            throw NSError(domain: "PhotoLibraryManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "儲存照片失敗"])
        }
        
        Self.recordAssetSyncedTimestamp(for: createdId)
        return createdId
    }
    
    /// 相容舊版呼叫介面：轉發至 `updateOrSaveImage`
    func saveImage(_ image: UIImage, creationDate: Date, to album: PHAssetCollection? = nil) async throws -> String {
        try await updateOrSaveImage(
            image,
            originalImageData: nil,
            existingAssetIdentifier: nil,
            creationDate: creationDate,
            to: album
        )
    }
    
    /// 使用 Apple Photos 原生 `PHContentEditingOutput` 直接修改既有 `PHAsset`（不新建照片，且保留原始未裁切圖片供隨時復原）
    func modifyAssetInPlace(
        asset: PHAsset,
        croppedImage: UIImage,
        creationDate: Date? = nil,
        album: PHAssetCollection? = nil,
        adjustmentFormatIdentifier: String = "wangtc07.ChekiLens.crop",
        adjustmentPayloadString: String? = nil
    ) async throws {
        guard let jpegData = croppedImage.jpegData(compressionQuality: 0.92) else {
            throw NSError(domain: "PhotoLibraryManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "無法編碼裁切後影像"])
        }
        
        let editingInput = try await requestContentEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: editingInput)
        let payload = adjustmentPayloadString ?? "cheki-perspective-crop-\(Date().timeIntervalSince1970)"
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: adjustmentFormatIdentifier,
            formatVersion: "1.2",
            data: Data(payload.utf8)
        )
        try jpegData.write(to: output.renderedContentURL, options: .atomic)
        
        try await PHPhotoLibrary.shared().performChanges {
            let changeRequest = PHAssetChangeRequest(for: asset)
            changeRequest.contentEditingOutput = output
            if let creationDate {
                changeRequest.creationDate = creationDate
            }
            if let album {
                let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                albumChangeRequest?.addAssets([asset] as NSArray)
            }
        }
        Self.recordAssetSyncedTimestamp(for: asset.localIdentifier)
    }
    
    /// 將既有 `PHAsset` 加入指定相簿（不複製或新建照片）
    func addExistingAsset(identifier: String, creationDate: Date? = nil, to album: PHAssetCollection) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
        try await PHPhotoLibrary.shared().performChanges {
            if let creationDate {
                let changeRequest = PHAssetChangeRequest(for: asset)
                changeRequest.creationDate = creationDate
            }
            let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
            albumChangeRequest?.addAssets([asset] as NSArray)
        }
    }

    /// 批次將指定拍立得項目 (`ChekiItem`) 同步並歸入其目前所在的系統相簿 (`ChekiLens › 團體 › 成員` 或 `ChekiLens`)
    /// - 支援「先從相簿追加匯入、事後再打開相簿同步」以及「變更所屬相冊後即時更新系統相簿」
    @MainActor
    @discardableResult
    func syncItemsToSystemPhotoLibrary(
        _ items: [ChekiItem],
        modelContext: ModelContext,
        onlyAlbumAndDateIfAlreadySynced: Bool = true
    ) async -> Int {
        guard !items.isEmpty else { return 0 }
        guard await requestAuthorization() else { return 0 }

        let overwriteExif = UserDefaults.standard.object(forKey: "overwriteExifDateWithOCR") as? Bool ?? true
        let useGroupMemberAlbums = UserDefaults.standard.object(forKey: "createGroupMemberAlbumsInPhotos") as? Bool ?? true
        let timelineStrategy = UserDefaults.standard.string(forKey: "backsideTimelineStrategy") ?? "sameSecond"

        let allMembers = (try? modelContext.fetch(FetchDescriptor<IdolMember>())) ?? []
        var syncedCount = 0

        for item in items {
            let assignedMembers = item.assignedMembers(from: allMembers)
            let targetAlbumSpecs: [(albumName: String, folderName: String?)] = {
                guard useGroupMemberAlbums, !assignedMembers.isEmpty else {
                    return [("ChekiLens", nil)]
                }
                return assignedMembers.map { ($0.albumTitle, $0.group?.name) }
            }()

            let frontSyncDate = overwriteExif ? item.displayDate : item.capturedAt
            let backSyncDate = (timelineStrategy == "plusOneSecond")
                ? frontSyncDate.addingTimeInterval(1.0)
                : frontSyncDate

            guard let primarySpec = targetAlbumSpecs.first,
                  let primaryAlbum = try? await getOrCreateAlbum(albumName: primarySpec.albumName, inFolder: primarySpec.folderName) else {
                continue
            }

            var didSyncItem = false

            // 1. 正面同步（先寫入主相簿，若有多位成員再將同一 PHAsset 加入其餘成員相簿）
            if onlyAlbumAndDateIfAlreadySynced,
               item.isSyncedToPhotoLibrary,
               let existingFrontID = item.frontAssetIdentifier,
               !existingFrontID.isEmpty,
               PHAsset.fetchAssets(withLocalIdentifiers: [existingFrontID], options: nil).firstObject != nil {
                try? await addExistingAsset(
                    identifier: existingFrontID,
                    creationDate: frontSyncDate,
                    to: primaryAlbum
                )
                didSyncItem = true
            } else if let frontData = item.frontImageData,
                      let frontUI = UIImage(data: frontData) {
                if let updatedFrontID = try? await updateOrSaveImage(
                    frontUI,
                    originalImageData: item.originalFrontImageData,
                    existingAssetIdentifier: item.frontAssetIdentifier,
                    creationDate: frontSyncDate,
                    to: primaryAlbum
                ) {
                    item.frontAssetIdentifier = updatedFrontID
                    didSyncItem = true
                }
            }

            // 2. 背面同步（若有背面）
            if onlyAlbumAndDateIfAlreadySynced,
               item.isSyncedToPhotoLibrary,
               let existingBackID = item.backAssetIdentifier,
               !existingBackID.isEmpty,
               PHAsset.fetchAssets(withLocalIdentifiers: [existingBackID], options: nil).firstObject != nil {
                try? await addExistingAsset(
                    identifier: existingBackID,
                    creationDate: backSyncDate,
                    to: primaryAlbum
                )
            } else if let backData = item.backImageData,
                      let backUI = UIImage(data: backData) {
                if let updatedBackID = try? await updateOrSaveImage(
                    backUI,
                    originalImageData: item.originalBackImageData,
                    existingAssetIdentifier: item.backAssetIdentifier,
                    creationDate: backSyncDate,
                    to: primaryAlbum
                ) {
                    item.backAssetIdentifier = updatedBackID
                }
            }

            // 3. 若指派了多位成員，將同一個 PHAsset 一併掛入其餘成員的系統相簿
            if targetAlbumSpecs.count > 1 {
                for extraSpec in targetAlbumSpecs.dropFirst() {
                    guard let extraAlbum = try? await getOrCreateAlbum(albumName: extraSpec.albumName, inFolder: extraSpec.folderName) else {
                        continue
                    }
                    if let frontID = item.frontAssetIdentifier, !frontID.isEmpty {
                        try? await addExistingAsset(
                            identifier: frontID,
                            creationDate: frontSyncDate,
                            to: extraAlbum
                        )
                    }
                    if let backID = item.backAssetIdentifier, !backID.isEmpty {
                        try? await addExistingAsset(
                            identifier: backID,
                            creationDate: backSyncDate,
                            to: extraAlbum
                        )
                    }
                }
            }

            if didSyncItem {
                item.isSyncedToPhotoLibrary = true
                item.isDateWrittenToAlbum = overwriteExif && (item.ocrDate != nil)
                syncedCount += 1
            }
        }

        try? modelContext.save()
        return syncedCount
    }

    // MARK: - Delete Sync with System Photo Library

    /// 判斷刪除指定拍立得時是否應一併自 iOS 系統相簿 (`Photos.app`) 刪除對應照片：
    /// - 只要該拍立得已綁定系統相簿 `frontAssetIdentifier` / `backAssetIdentifier` 或 `isSyncedToPhotoLibrary == true`，或系統相簿同步開啟時，一律同步自系統相簿刪除
    static func shouldSyncDeleteFromSystemPhotoLibrary(for item: ChekiItem? = nil) -> Bool {
        if let item, !item.isDeleted, item.modelContext != nil {
            if item.isSyncedToPhotoLibrary { return true }
            if let f = item.frontAssetIdentifier, !f.isEmpty { return true }
            if let b = item.backAssetIdentifier, !b.isEmpty { return true }
        }
        if let explicit = UserDefaults.standard.object(forKey: "autoSyncToPhotosLibrary") as? Bool {
            return explicit
        }
        if let legacyExplicit = UserDefaults.standard.object(forKey: "autoSyncToPhotos") as? Bool {
            return legacyExplicit
        }
        return true
    }

    /// 收集待刪除項目對應之 iOS 系統相簿 `PHAsset.localIdentifier`（包含拍攝時間軸 ±2.5 秒自動回退比對）
    @MainActor
    private func collectAssetIdentifiersToDelete(
        for items: [ChekiItem],
        modelContext: ModelContext
    ) async -> [String] {
        let liveItems = items.filter { !$0.isDeleted && $0.modelContext != nil }
        guard !liveItems.isEmpty else { return [] }

        let deletingIDs = Set(liveItems.map(\.id))
        let allItems = ((try? modelContext.fetch(FetchDescriptor<ChekiItem>())) ?? [])
            .filter { !$0.isDeleted && $0.modelContext != nil }

        var retainedAssetIDs = Set<String>()
        for existing in allItems where !deletingIDs.contains(existing.id) {
            if let f = existing.frontAssetIdentifier, !f.isEmpty {
                retainedAssetIDs.insert(f)
            }
            if let b = existing.backAssetIdentifier, !b.isEmpty {
                retainedAssetIDs.insert(b)
            }
        }

        var assetIDsToDelete: [String] = []
        var fallbackDatesToSearch: [Date] = []

        for item in liveItems {
            guard Self.shouldSyncDeleteFromSystemPhotoLibrary(for: item) else { continue }
            var foundExplicitID = false
            if let frontID = item.frontAssetIdentifier,
               !frontID.isEmpty,
               !retainedAssetIDs.contains(frontID) {
                if !assetIDsToDelete.contains(frontID) {
                    assetIDsToDelete.append(frontID)
                }
                foundExplicitID = true
            }
            if let backID = item.backAssetIdentifier,
               !backID.isEmpty,
               !retainedAssetIDs.contains(backID) {
                if !assetIDsToDelete.contains(backID) {
                    assetIDsToDelete.append(backID)
                }
                foundExplicitID = true
            }
            if !foundExplicitID {
                fallbackDatesToSearch.append(item.capturedAt)
                if abs(item.displayDate.timeIntervalSince(item.capturedAt)) > 1.0 {
                    fallbackDatesToSearch.append(item.displayDate)
                }
            }
        }

        // 若相機剛拍完背景正位同步剛寫入系統相簿、或舊項目未記錄 frontAssetIdentifier，以拍攝時間軸 ±2.5 秒在系統相簿定位對應相片
        if !fallbackDatesToSearch.isEmpty, await requestAuthorization() {
            for targetDate in fallbackDatesToSearch {
                let opts = PHFetchOptions()
                let minDate = targetDate.addingTimeInterval(-2.5)
                let maxDate = targetDate.addingTimeInterval(2.5)
                opts.predicate = NSPredicate(
                    format: "creationDate >= %@ AND creationDate <= %@",
                    minDate as NSDate,
                    maxDate as NSDate
                )
                let matched = PHAsset.fetchAssets(with: .image, options: opts)
                matched.enumerateObjects { asset, _, _ in
                    let id = asset.localIdentifier
                    if !retainedAssetIDs.contains(id) && !assetIDsToDelete.contains(id) {
                        assetIDsToDelete.append(id)
                    }
                }
            }
        }

        return assetIDsToDelete
    }

    /// 非同步安全刪除指定的 `ChekiItem` 陣列：
    /// 1. 先向 iOS 系統相簿 (`Photos.app`) 請求刪除對應的 `PHAsset`（確保系統相簿確實刪除且視圖狀態穩定不閃退）。
    /// 2. 執行 `onBeforeContextDelete` 讓單張檢視器先行切換上/下一張或關閉頁面，徹底脫離被刪除物件之引用。
    /// 3. 最後再解除關聯並從 SwiftData `modelContext` 刪除與儲存。
    @MainActor
    func deleteItemsAsync(
        _ items: [ChekiItem],
        modelContext: ModelContext,
        onBeforeContextDelete: (@MainActor () -> Void)? = nil
    ) async {
        let liveItems = items.filter { !$0.isDeleted && $0.modelContext != nil }
        guard !liveItems.isEmpty else {
            onBeforeContextDelete?()
            return
        }

        let assetIDsToDelete = await collectAssetIdentifiersToDelete(for: liveItems, modelContext: modelContext)
        if !assetIDsToDelete.isEmpty {
            await deleteAssetsFromSystemPhotoLibrary(identifiers: assetIDsToDelete)
        }

        onBeforeContextDelete?()
        await Task.yield()

        for item in liveItems where !item.isDeleted && item.modelContext != nil {
            if let memo = item.memo {
                item.memo = nil
                modelContext.delete(memo)
            }
            item.idolMember = nil
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    /// 刪除指定的 `ChekiItem` 陣列，並一併自 iOS 系統相簿 (`Photos.app`) 刪除對應的正反面照片
    @MainActor
    func deleteItems(
        _ items: [ChekiItem],
        modelContext: ModelContext
    ) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            await self.deleteItemsAsync(items, modelContext: modelContext)
        }
    }

    /// 移除單張拍立得的背面照片，並在啟用「系統相簿同步」時一併自 iOS 系統相簿刪除該背面照片
    @MainActor
    func removeBackside(
        from item: ChekiItem,
        modelContext: ModelContext
    ) {
        guard !item.isDeleted, item.modelContext != nil else { return }
        let removedBackAssetID = item.backAssetIdentifier
        let shouldDeleteFromPhotos = Self.shouldSyncDeleteFromSystemPhotoLibrary(for: item)

        item.backImageData = nil
        item.originalBackImageData = nil
        item.backPerspectivePointsJSON = nil
        item.backAssetIdentifier = nil
        try? modelContext.save()

        guard shouldDeleteFromPhotos,
              let backID = removedBackAssetID,
              !backID.isEmpty else {
            return
        }

        let allItems = ((try? modelContext.fetch(FetchDescriptor<ChekiItem>())) ?? [])
            .filter { !$0.isDeleted && $0.modelContext != nil }
        let isStillReferenced = allItems.contains { existing in
            existing.frontAssetIdentifier == backID || existing.backAssetIdentifier == backID
        }
        guard !isStillReferenced else { return }

        Task {
            await deleteAssetsFromSystemPhotoLibrary(identifiers: [backID])
        }
    }

    /// 自 iOS 系統相簿 (`Photos.app`) 刪除指定 `localIdentifier` 的照片 (`PHAsset`)
    func deleteAssetsFromSystemPhotoLibrary(identifiers: [String]) async {
        let validIDs = identifiers.filter { !$0.isEmpty }
        guard !validIDs.isEmpty else { return }
        guard await requestAuthorization() else { return }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: validIDs, options: nil)
        guard fetchResult.count > 0 else { return }

        // 等待 SwiftUI confirmationDialog (UIAlertController) 收合動畫完成，避免阻擋 iOS 系統相簿刪除權限對話框彈出
        try? await Task.sleep(nanoseconds: 350_000_000)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(fetchResult)
            }
            logger.info("已同步自 iOS 系統相簿刪除 \(fetchResult.count) 張照片")
        } catch {
            logger.error("自 iOS 系統相簿刪除照片失敗或使用者取消：\(error.localizedDescription)")
        }
    }

    /// 將系統相簿中的 `PHAsset` 復原為未裁切的原始圖片 (`revertAssetContentToOriginal`)
    func revertAssetToOriginal(assetIdentifier: String) async throws {
        guard !assetIdentifier.isEmpty,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            return
        }
        try await PHPhotoLibrary.shared().performChanges {
            let changeRequest = PHAssetChangeRequest(for: asset)
            changeRequest.revertAssetContentToOriginal()
        }
        Self.recordAssetSyncedTimestamp(for: asset.localIdentifier)
    }
    
    private func requestContentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            options.canHandleAdjustmentData = { _ in true }
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    let err = (info[PHContentEditingInputErrorKey] as? Error)
                        ?? NSError(domain: "PhotoLibraryManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "無法取得原圖編輯輸入"])
                    continuation.resume(throwing: err)
                }
            }
        }
    }

    // MARK: - Task 6.5.8 (Part A): 系統相簿調色／修改同步更新 (Sync Color Adjustments from iOS Photos.app)

    private static let assetSyncTimestampPrefix = "systemAssetLastSyncedModTime."

    static func recordAssetSyncedTimestamp(for assetIdentifier: String, modificationDate: Date? = nil) {
        guard !assetIdentifier.isEmpty else { return }
        let resolvedModDate: Date? = {
            if let modificationDate { return modificationDate }
            return PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject?.modificationDate
        }()
        let timestamp = (resolvedModDate ?? Date()).timeIntervalSince1970
        UserDefaults.standard.set(timestamp, forKey: assetSyncTimestampPrefix + assetIdentifier)
    }

    private static func lastKnownSyncedTimestamp(for assetIdentifier: String) -> TimeInterval? {
        guard !assetIdentifier.isEmpty else { return nil }
        let key = assetSyncTimestampPrefix + assetIdentifier
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.double(forKey: key)
    }

    /// 讀取 `PHAsset` 在 iOS 系統相簿中最新渲染後的影像資料（`.version = .current`，包含系統相簿內所有調色、色溫、濾鏡與曝光修改）
    private func requestCurrentRenderedImageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            var didResume = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                guard !didResume else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                didResume = true
                continuation.resume(returning: data)
            }
        }
    }

    /// 檢查 `PHAsset` 是否在系統相簿中含有外部編輯（如 `Photos.app` 的調色修改）或 `modificationDate` 較上次同步更新
    private func hasExternalSystemEdit(for asset: PHAsset) async -> Bool {
        let assetID = asset.localIdentifier
        let currentModTime = asset.modificationDate?.timeIntervalSince1970 ?? 0

        if let lastKnown = Self.lastKnownSyncedTimestamp(for: assetID) {
            return currentModTime > lastKnown + 0.5
        }

        // 若為舊項目尚未紀錄 timestamp，檢查該 PHAsset 是否含有非 ChekiLens 寫入之系統調色 (.adjustmentData)
        let resources = PHAssetResource.assetResources(for: asset)
        let hasAdjustmentResource = resources.contains { $0.type == .adjustmentData }
        guard hasAdjustmentResource else {
            Self.recordAssetSyncedTimestamp(for: assetID, modificationDate: asset.modificationDate)
            return false
        }

        return await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false
            var detectedFormatID: String? = nil
            options.canHandleAdjustmentData = { adjustmentData in
                detectedFormatID = adjustmentData.formatIdentifier
                return false
            }
            asset.requestContentEditingInput(with: options) { _, _ in
                if let formatID = detectedFormatID {
                    // 若 formatIdentifier 不是 ChekiLens 寫入的（例如 com.apple.photo 原生相簿調色），代表在系統相簿有調色修改
                    let isExternal = !formatID.hasPrefix("wangtc07.ChekiLens")
                    if !isExternal {
                        Self.recordAssetSyncedTimestamp(for: assetID, modificationDate: asset.modificationDate)
                    }
                    continuation.resume(returning: isExternal)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// 將從系統相簿讀取到的最新調色影像套用回單面（若系統相簿為未裁切原圖且 App 內存有四頂點座標，自動重新套用相同四頂點透視裁切以保留調色與白邊裁切）
    private func buildUpdatedSideDataFromSystemAsset(
        renderedData: Data,
        existingCroppedData: Data?,
        existingOriginalData: Data?,
        savedCornersJSON: String?,
        filmFormat: FilmFormat
    ) async -> (updatedCroppedData: Data, updatedOriginalData: Data?)? {
        guard let renderedUI = UIImage(data: renderedData)?.normalizedImage,
              let renderedCG = renderedUI.cgImage else {
            return nil
        }
        let renderedJPEG = renderedUI.jpegData(compressionQuality: 0.92) ?? renderedData
        let renderedSize = CGSize(width: renderedCG.width, height: renderedCG.height)

        if let savedNormCorners = ChekiItem.decodeNormalizedCorners(from: savedCornersJSON),
           savedNormCorners.count == 4 {
            var isRenderedUncroppedOriginal = false
            if let origData = existingOriginalData,
               let origUI = UIImage(data: origData)?.normalizedImage,
               let cropData = existingCroppedData,
               let cropUI = UIImage(data: cropData)?.normalizedImage {
                let origW = origUI.size.width * origUI.scale
                let origH = origUI.size.height * origUI.scale
                let cropW = cropUI.size.width * cropUI.scale
                let cropH = cropUI.size.height * cropUI.scale
                let distToOrig = hypot(renderedSize.width - origW, renderedSize.height - origH)
                let distToCrop = hypot(renderedSize.width - cropW, renderedSize.height - cropH)
                if distToOrig + 8.0 < distToCrop {
                    isRenderedUncroppedOriginal = true
                }
            } else if !Self.isProLifetimeUnlocked {
                isRenderedUncroppedOriginal = true
            }

            if isRenderedUncroppedOriginal {
                let pixelCorners = savedNormCorners.map {
                    CGPoint(x: $0.x * renderedSize.width, y: $0.y * renderedSize.height)
                }
                let visionManager = VisionManager()
                let chekiFormat: ChekiFilmFormat = {
                    switch filmFormat {
                    case .mini: return .mini
                    case .square: return .square
                    case .wide: return .wide
                    case .auto: return .auto
                    }
                }()
                let manualDetection = DetectionResult(
                    corners: pixelCorners,
                    method: .visionNative,
                    confidence: 1.0,
                    imageSize: renderedSize
                )
                if let cropResult = try? await visionManager.perspectiveCorrect(
                    image: renderedCG,
                    corners: pixelCorners,
                    detection: manualDetection,
                    format: chekiFormat,
                    preserveCornerOrder: true
                ),
                let reCroppedJPEG = UIImage(cgImage: cropResult.cgImage).jpegData(compressionQuality: 0.92) {
                    return (reCroppedJPEG, renderedJPEG)
                }
            }
        }

        return (renderedJPEG, existingOriginalData)
    }

    /// 單張檢查並同步系統相簿 (`Photos.app`) 的調色或編輯修改（於點開單張照片時呼叫）
    @MainActor
    @discardableResult
    func syncExternalEditsFromSystemPhotoLibrary(
        for item: ChekiItem,
        modelContext: ModelContext
    ) async -> Bool {
        guard !item.isDeleted, item.modelContext != nil else { return false }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }

        var didUpdate = false

        // 1. 檢查正面 PHAsset
        if let frontID = item.frontAssetIdentifier,
           !frontID.isEmpty,
           let frontAsset = PHAsset.fetchAssets(withLocalIdentifiers: [frontID], options: nil).firstObject {
            if await hasExternalSystemEdit(for: frontAsset),
               let renderedData = await requestCurrentRenderedImageData(for: frontAsset),
               let updated = await buildUpdatedSideDataFromSystemAsset(
                   renderedData: renderedData,
                   existingCroppedData: item.frontImageData,
                   existingOriginalData: item.originalFrontImageData,
                   savedCornersJSON: item.perspectivePointsJSON,
                   filmFormat: item.filmFormat
               ) {
                guard !item.isDeleted, item.modelContext != nil else { return false }
                item.frontImageData = updated.updatedCroppedData
                if let updatedOrig = updated.updatedOriginalData {
                    item.originalFrontImageData = updatedOrig
                }
                Self.recordAssetSyncedTimestamp(for: frontID, modificationDate: frontAsset.modificationDate)
                didUpdate = true
            }
        }

        // 2. 檢查背面 PHAsset
        if let backID = item.backAssetIdentifier,
           !backID.isEmpty,
           let backAsset = PHAsset.fetchAssets(withLocalIdentifiers: [backID], options: nil).firstObject {
            if await hasExternalSystemEdit(for: backAsset),
               let renderedData = await requestCurrentRenderedImageData(for: backAsset),
               let updated = await buildUpdatedSideDataFromSystemAsset(
                   renderedData: renderedData,
                   existingCroppedData: item.backImageData,
                   existingOriginalData: item.originalBackImageData,
                   savedCornersJSON: item.backPerspectivePointsJSON,
                   filmFormat: item.filmFormat
               ) {
                guard !item.isDeleted, item.modelContext != nil else { return false }
                item.backImageData = updated.updatedCroppedData
                if let updatedOrig = updated.updatedOriginalData {
                    item.originalBackImageData = updatedOrig
                }
                Self.recordAssetSyncedTimestamp(for: backID, modificationDate: backAsset.modificationDate)
                didUpdate = true
            }
        }

        if didUpdate {
            try? modelContext.save()
            logger.info("已從 iOS 系統相簿同步更新拍立得調色修改 (item: \(item.id.uuidString))")
        }
        return didUpdate
    }

    /// 批次檢查並同步所有關聯系統相簿之拍立得調色修改（於 App 啟動或從背景返回前景時呼叫）
    @MainActor
    @discardableResult
    func syncAllExternalEditsFromSystemPhotoLibrary(modelContext: ModelContext) async -> Int {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return 0 }

        let allItems = ((try? modelContext.fetch(FetchDescriptor<ChekiItem>())) ?? [])
            .filter { !$0.isDeleted && $0.modelContext != nil }
        var updatedCount = 0

        for item in allItems {
            let hasAssetID = (item.frontAssetIdentifier?.isEmpty == false) || (item.backAssetIdentifier?.isEmpty == false)
            guard hasAssetID else { continue }
            if await syncExternalEditsFromSystemPhotoLibrary(for: item, modelContext: modelContext) {
                updatedCount += 1
            }
        }
        return updatedCount
    }

    // MARK: - Task 6.5.8 (Part B): 點選白色部分自動白平衡 (Tap-on-White Auto White Balance via Core Image CITemperatureAndTint)

    struct AutoWhiteBalanceOutcome: Sendable {
        let calibratedImage: UIImage
        let calibratedJPEGData: Data
        /// 估計的原始取樣點色溫（Kelvin，標準中性白為 6500K）
        let sampledTemperatureKelvin: Double
        /// 估計的原始取樣點色調偏移（Tint，標準中性白為 0）
        let sampledTint: Double
        /// 套用的色溫補償量（ΔK = 6500 - sampledTemperatureKelvin）
        var deltaTemperatureKelvin: Int {
            Int((6500.0 - sampledTemperatureKelvin).rounded())
        }
        /// 套用的色調補償量
        var deltaTint: Int {
            Int((-sampledTint).rounded())
        }
    }

    enum AutoWhiteBalanceError: LocalizedError {
        case invalidImage
        case sampleTooDark

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return L10n.tr("無法讀取拍立得影像進行白平衡校正", "ホワイトバランス補正用の画像を読み込めませんでした")
            case .sampleTooDark:
                return L10n.tr("所選位置過暗，請點選拍立得「白色邊框」區域", "選択箇所が暗すぎます。チェキの「白い余白」部分をタップしてください")
            }
        }
    }

    private static let sharedWhiteBalanceCIContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])

    /// 根據使用者在拍立得上點選的白色區域座標 (`normalizedTapPoint`, 0...1)，
    /// 取樣周圍像素並透過 Core Image 原生 `CITemperatureAndTint`（色溫／色調）＋亮度守恆微調自動校正白平衡。
    static func applyAutoWhiteBalance(
        to sourceImage: UIImage,
        normalizedTapPoint: CGPoint
    ) -> Result<AutoWhiteBalanceOutcome, AutoWhiteBalanceError> {
        let normalizedUI = sourceImage.normalizedImage
        guard let cgImage = normalizedUI.cgImage else {
            return .failure(.invalidImage)
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 4, height > 4 else {
            return .failure(.invalidImage)
        }

        let clampedX = min(max(normalizedTapPoint.x, 0.0), 1.0)
        let clampedY = min(max(normalizedTapPoint.y, 0.0), 1.0)
        let centerX = Int((clampedX * CGFloat(width - 1)).rounded())
        let centerY = Int((clampedY * CGFloat(height - 1)).rounded())

        // 1. 取樣點選位置周圍 13x13 像素區塊的平均 sRGB 值
        let radius = 6
        let minX = max(0, centerX - radius)
        let maxX = min(width - 1, centerX + radius)
        let minY = max(0, centerY - radius)
        let maxY = min(height - 1, centerY + radius)
        let patchW = max(1, maxX - minX + 1)
        let patchH = max(1, maxY - minY + 1)

        guard let croppedPatch = cgImage.cropping(to: CGRect(x: minX, y: minY, width: patchW, height: patchH)) else {
            return .failure(.invalidImage)
        }

        var rawPixels = [UInt8](repeating: 0, count: patchW * patchH * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rawPixels,
            width: patchW,
            height: patchH,
            bitsPerComponent: 8,
            bytesPerRow: patchW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .failure(.invalidImage)
        }
        ctx.draw(croppedPatch, in: CGRect(x: 0, y: 0, width: patchW, height: patchH))

        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0
        var validCount: Double = 0

        for i in stride(from: 0, to: rawPixels.count, by: 4) {
            let r = Double(rawPixels[i]) / 255.0
            let g = Double(rawPixels[i + 1]) / 255.0
            let b = Double(rawPixels[i + 2]) / 255.0
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // 排除完全死白過曝 (>0.992) 或深黑字跡 (<0.18) 的像素，優先取樣真實白邊紙質基底
            if luma >= 0.18 && luma <= 0.992 {
                sumR += r
                sumG += g
                sumB += b
                validCount += 1.0
            }
        }

        if validCount < 1.0 {
            for i in stride(from: 0, to: rawPixels.count, by: 4) {
                sumR += Double(rawPixels[i]) / 255.0
                sumG += Double(rawPixels[i + 1]) / 255.0
                sumB += Double(rawPixels[i + 2]) / 255.0
                validCount += 1.0
            }
        }

        let avgR = sumR / max(1.0, validCount)
        let avgG = sumG / max(1.0, validCount)
        let avgB = sumB / max(1.0, validCount)
        let luma = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB

        guard luma >= 0.12 else {
            return .failure(.sampleTooDark)
        }

        // 2. 計算取樣白點對應的 Core Image CITemperatureAndTint 色溫 (Kelvin) 與色調 (Tint)
        let safeG = max(0.12, avgG)
        let rbRatioDiff = min(max((avgR - avgB) / safeG, -0.60), 0.60)
        let gmRatioDiff = min(max((avgG - 0.5 * (avgR + avgB)) / safeG, -0.45), 0.45)

        // 在 CITemperatureAndTint 中：
        // inputNeutral 代表原圖白點的色溫與色調，inputTargetNeutral = (6500, 0) 為目標標準中性白
        let sampledTempK = min(max(6500.0 - rbRatioDiff * 4000.0, 2800.0), 10500.0)
        let sampledTint = min(max(gmRatioDiff * 135.0, -95.0), 95.0)

        let baseCI = CIImage(cgImage: cgImage)
        var workingCI = baseCI

        // (A) 主校正：Core Image 原生 CITemperatureAndTint (色溫 / 色調濾鏡)
        if let tempTintFilter = CIFilter(name: "CITemperatureAndTint") {
            tempTintFilter.setValue(workingCI, forKey: kCIInputImageKey)
            tempTintFilter.setValue(CIVector(x: CGFloat(sampledTempK), y: CGFloat(sampledTint)), forKey: "inputNeutral")
            tempTintFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            if let out = tempTintFilter.outputImage {
                workingCI = out.cropped(to: baseCI.extent)
            }
        }

        // (B) 殘差白點精準平衡：讀取 CITemperatureAndTint 後同位置的色偏殘差，以溫和的亮度守恆增益收斂至純淨白邊
        let sampleExtent = CGRect(x: minX, y: height - 1 - maxY, width: patchW, height: patchH)
            .intersection(workingCI.extent)
        if !sampleExtent.isEmpty,
           let areaAvg = CIFilter(name: "CIAreaAverage", parameters: [
               kCIInputImageKey: workingCI,
               kCIInputExtentKey: CIVector(cgRect: sampleExtent)
           ])?.outputImage {
            var px = [UInt8](repeating: 0, count: 4)
            sharedWhiteBalanceCIContext.render(
                areaAvg,
                toBitmap: &px,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: colorSpace
            )
            let postR = max(0.10, Double(px[0]) / 255.0)
            let postG = max(0.10, Double(px[1]) / 255.0)
            let postB = max(0.10, Double(px[2]) / 255.0)
            let postLuma = 0.2126 * postR + 0.7152 * postG + 0.0722 * postB

            // 限制殘差補償增益在 0.80 ~ 1.25 之間，確保人物膚色自然不失真
            let gainR = min(max(postLuma / postR, 0.80), 1.25)
            let gainG = min(max(postLuma / postG, 0.80), 1.25)
            let gainB = min(max(postLuma / postB, 0.80), 1.25)

            // 混合 75% 殘差收斂，讓拍立得白邊既乾淨又保留自然相紙質感
            let finalGainR = CGFloat(1.0 + (gainR - 1.0) * 0.75)
            let finalGainG = CGFloat(1.0 + (gainG - 1.0) * 0.75)
            let finalGainB = CGFloat(1.0 + (gainB - 1.0) * 0.75)

            if let matrixFilter = CIFilter(name: "CIColorMatrix") {
                matrixFilter.setValue(workingCI, forKey: kCIInputImageKey)
                matrixFilter.setValue(CIVector(x: finalGainR, y: 0, z: 0, w: 0), forKey: "inputRVector")
                matrixFilter.setValue(CIVector(x: 0, y: finalGainG, z: 0, w: 0), forKey: "inputGVector")
                matrixFilter.setValue(CIVector(x: 0, y: 0, z: finalGainB, w: 0), forKey: "inputBVector")
                matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                if let out = matrixFilter.outputImage {
                    workingCI = out.cropped(to: baseCI.extent)
                }
            }
        }

        guard let outCG = sharedWhiteBalanceCIContext.createCGImage(workingCI, from: baseCI.extent) else {
            return .failure(.invalidImage)
        }
        let calibratedUI = UIImage(cgImage: outCG, scale: normalizedUI.scale, orientation: .up)
        guard let jpegData = calibratedUI.jpegData(compressionQuality: 0.92) else {
            return .failure(.invalidImage)
        }

        return .success(
            AutoWhiteBalanceOutcome(
                calibratedImage: calibratedUI,
                calibratedJPEGData: jpegData,
                sampledTemperatureKelvin: sampledTempK,
                sampledTint: sampledTint
            )
        )
    }

    /// 將白平衡（色溫／色調）校正結果以非破壞性 `PHContentEditingOutput` + `PHAdjustmentData` 寫入 iOS 系統相簿紀錄
    @MainActor
    func syncWhiteBalanceEditToSystemPhotoLibrary(
        for item: ChekiItem,
        backside: Bool,
        outcome: AutoWhiteBalanceOutcome,
        normalizedTapPoint: CGPoint
    ) async -> Bool {
        let assetID = backside ? item.backAssetIdentifier : item.frontAssetIdentifier
        guard let assetID,
              !assetID.isEmpty,
              let existingAsset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return false
        }
        guard await requestAuthorization() else { return false }

        let payloadDict: [String: Any] = [
            "type": "whiteBalanceAndCrop",
            "sampledTemperatureKelvin": outcome.sampledTemperatureKelvin,
            "targetTemperatureKelvin": 6500.0,
            "deltaTemperatureKelvin": outcome.deltaTemperatureKelvin,
            "sampledTint": outcome.sampledTint,
            "deltaTint": outcome.deltaTint,
            "tapX": Double(normalizedTapPoint.x),
            "tapY": Double(normalizedTapPoint.y),
            "timestamp": Date().timeIntervalSince1970
        ]
        let payloadJSON = (try? JSONSerialization.data(withJSONObject: payloadDict))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "cheki-wb-\(outcome.deltaTemperatureKelvin)K-\(outcome.deltaTint)"

        // 若為免費版且系統相簿保留未裁切原圖，則對未裁切原圖套用相同色溫／色調校正後寫入系統相簿
        var imageForSystemAsset = outcome.calibratedImage
        if !Self.isProLifetimeUnlocked,
           let origData = (backside ? item.originalBackImageData : item.originalFrontImageData),
           let origUI = UIImage(data: origData),
           case .success(let origWB) = Self.applyAutoWhiteBalance(to: origUI, normalizedTapPoint: normalizedTapPoint) {
            imageForSystemAsset = origWB.calibratedImage
        }

        do {
            try await modifyAssetInPlace(
                asset: existingAsset,
                croppedImage: imageForSystemAsset,
                creationDate: nil,
                album: nil,
                adjustmentFormatIdentifier: "wangtc07.ChekiLens.whitebalance",
                adjustmentPayloadString: payloadJSON
            )
            return true
        } catch {
            logger.error("同步白平衡修改紀錄至系統相簿失敗：\(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - 免費版浮水印渲染器與視圖疊加元件 (Free Tier Watermark Overlay & Export Renderer)

/// 負責在「免費版 (`isProLifetimeUnlocked == false`)」且每日 1 張免費高畫質額度用罄後，
/// 將匯出/分享的裁切拍立得縮小為 SNS 夠用畫質（長邊上限 960px、JPEG 0.72 壓縮）並於右下角加上 `ChekiLens` 浮水印；
/// 若已解鎖 Pro 終身買斷版（或使用當日 1 張免費高畫質額度），則 100% 原圖 4K 無損直出、完全不加浮水印。
enum ChekiWatermarkRenderer {
    /// 免費版額度用完後的 SNS 輸出長邊像素上限（例如 Mini 約 603×960 px，勉強夠 SNS 分享）
    static let freeTierSNSMaxDimension: CGFloat = 960.0
    /// 免費版額度用完後的 JPEG 壓縮品質
    static let freeTierSNSJPEGQuality: CGFloat = 0.72

    static func applyWatermarkIfNeeded(to image: UIImage, downscaleForSNS: Bool = true) -> UIImage {
        guard !PhotoLibraryManager.isProLifetimeUnlocked else {
            return image
        }

        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 10, pixelHeight > 10 else { return image }

        // 1. 計算免費版 SNS 縮圖尺寸（長邊上限 960px，scale 固定為 1.0 確保實際輸出像素縮小）
        let targetSize: CGSize
        if downscaleForSNS {
            let maxSide = max(pixelWidth, pixelHeight)
            let ratio = maxSide > freeTierSNSMaxDimension ? (freeTierSNSMaxDimension / maxSide) : 1.0
            targetSize = CGSize(
                width: max(1, round(pixelWidth * ratio)),
                height: max(1, round(pixelHeight * ratio))
            )
        } else {
            targetSize = CGSize(width: pixelWidth, height: pixelHeight)
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        let watermarkedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
            let shortSide = min(targetSize.width, targetSize.height)

            // 右下角拍立得白邊品牌浮水印章 ("ChekiLens")
            let badgeFontSize = max(12, shortSide * 0.038)
            let badgeText = "ChekiLens"
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: badgeFontSize, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .kern: 0.6
            ]
            let attributedBadge = NSAttributedString(string: badgeText, attributes: badgeAttrs)
            let textSize = attributedBadge.size()
            let padX = badgeFontSize * 0.65
            let padY = badgeFontSize * 0.34
            let margin = max(10, shortSide * 0.036)

            let pillRect = CGRect(
                x: targetSize.width - textSize.width - padX * 2 - margin,
                y: targetSize.height - textSize.height - padY * 2 - margin,
                width: textSize.width + padX * 2,
                height: textSize.height + padY * 2
            )

            let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height / 2)
            UIColor.black.withAlphaComponent(0.42).setFill()
            pillPath.fill()

            UIColor.white.withAlphaComponent(0.28).setStroke()
            pillPath.lineWidth = max(1.0, shortSide * 0.0025)
            pillPath.stroke()

            attributedBadge.draw(
                at: CGPoint(
                    x: pillRect.minX + padX,
                    y: pillRect.minY + padY
                )
            )
        }

        // 2. 壓縮為 SNS 等級 JPEG，讓檔案大小與畫質僅勉強夠 SNS 分享使用
        if downscaleForSNS,
           let compressedData = watermarkedImage.jpegData(compressionQuality: freeTierSNSJPEGQuality),
           let compressedImage = UIImage(data: compressedData) {
            return compressedImage
        }
        return watermarkedImage
    }
}

/// App 內檢視裁切後拍立得時的非破壞性浮水印疊加層：
/// - 免費版 (`isProLifetimeUnlocked == false`)：在 App 內查看裁切後的拍立得照片時於右下角顯示浮水印。
/// - Pro 終身買斷版 (`isProLifetimeUnlocked == true`)：自動完全隱藏浮水印。
struct ChekiWatermarkOverlayView: View {
    @AppStorage("isProLifetimeUnlocked") private var isProLifetimeUnlocked: Bool = false

    /// 是否為網格縮圖緊湊模式
    var compact: Bool = false

    var body: some View {
        let fontSize: CGFloat = compact ? 8.5 : 11.5
        let hPad: CGFloat = compact ? 5.5 : 8.5
        let vPad: CGFloat = compact ? 2.0 : 3.5
        let outerPad: CGFloat = compact ? 5.0 : 10.0

        ZStack {
            if !isProLifetimeUnlocked {
                // 右下角品牌浮水印標記
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("ChekiLens")
                            .font(.system(size: fontSize, weight: .bold, design: .rounded))
                            .tracking(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .foregroundStyle(Color.white.opacity(0.90))
                            .padding(.horizontal, hPad)
                            .padding(.vertical, vPad)
                            .background(Color.black.opacity(0.42), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
                            )
                            .padding(outerPad)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}


