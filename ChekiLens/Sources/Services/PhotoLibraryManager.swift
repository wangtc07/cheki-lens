import Foundation
import Photos
import UIKit
import OSLog

@Observable
final class PhotoLibraryManager {
    static let shared = PhotoLibraryManager()
    
    var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private let logger = Logger(subsystem: "com.chekilens.app", category: "PhotoLibrary")
    
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
        
        // 2. 尋找現有相簿
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
        
        let collections: PHFetchResult<PHAssetCollection>
        if let folder = targetFolder {
            // 從指定資料夾內尋找相簿
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
            // 從根目錄尋找
            collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
            if let album = collections.firstObject {
                return album
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
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", folderName)
        
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: fetchOptions)
        if let folder = folders.firstObject {
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
    
    // MARK: - Save Image
    
    /// 將影像存入指定相簿，並強制修改相機時間 (EXIF 建立時間)
    /// - Parameters:
    ///   - image: 要儲存的影像
    ///   - creationDate: 強制指定的拍攝時間 (這也是 Task 3.3 與 3.4 的核心)
    ///   - album: 目標相簿 (可為 nil，代表只存入相機膠卷)
    /// - Returns: 儲存後的 Asset Local Identifier
    func saveImage(_ image: UIImage, creationDate: Date, to album: PHAssetCollection? = nil) async throws -> String {
        guard await requestAuthorization() else {
            throw NSError(domain: "PhotoLibraryManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "無相簿權限"])
        }
        
        var placeholderId: String?
        
        try await PHPhotoLibrary.shared().performChanges {
            // 建立新增照片的 Request
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: image.jpegData(compressionQuality: 0.9)!, options: nil)
            
            // 強制覆寫照片的拍攝時間 (EXIF)
            creationRequest.creationDate = creationDate
            
            // 如果有指定相簿，加進相簿裡
            if let album = album, let placeholder = creationRequest.placeholderForCreatedAsset {
                let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                albumChangeRequest?.addAssets([placeholder] as NSArray)
            }
            
            placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
        }
        
        guard let id = placeholderId else {
            throw NSError(domain: "PhotoLibraryManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "儲存照片失敗"])
        }
        
        return id
    }
}
