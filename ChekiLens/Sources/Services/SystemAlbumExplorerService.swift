import Foundation
import Photos
import UIKit
import SwiftData

// MARK: - SystemPhotoAlbumNode

/// 代表 iOS 系統相簿中的一本使用者相簿（對應 ChekiLens 的「成員相冊」）
nonisolated struct SystemPhotoAlbumNode: Identifiable, Equatable, Hashable, Sendable {
    /// 對應 `PHAssetCollection.localIdentifier`
    let id: String
    /// 相簿標題（預設對應成員名稱 `stageName`）
    var title: String
    /// 所屬父資料夾之 `PHCollectionList.localIdentifier`（若為根目錄獨立相簿則為 `nil`）
    var parentFolderID: String?
    /// 所屬父資料夾名稱（預設對應團體名稱 `IdolGroup.name`；若為根目錄獨立相簿則為 `nil`）
    var parentFolderTitle: String?
    /// 相簿內所有影像 `PHAsset.localIdentifier`（依相簿順序排列；初始輕量掃描階段可為空，待進入工作台時延遲解析）
    var assetIdentifiers: [String]
    /// 封面預覽縮圖使用的 `PHAsset.localIdentifier`
    var coverAssetIdentifier: String?
    /// 此相簿匯入時是否執行拍立得四角邊緣偵測與透視裁切（預設 `true`；若原圖已裁切可關閉）
    var enableEdgeDetection: Bool
    /// 相簿內影像總數（若已載入 assetIdentifiers 則以其實際長度為準，否則以初次輕量掃描計數為準）
    private var explicitAssetCount: Int?

    var assetCount: Int {
        if !assetIdentifiers.isEmpty {
            return assetIdentifiers.count
        }
        return explicitAssetCount ?? 0
    }

    init(
        id: String,
        title: String,
        parentFolderID: String? = nil,
        parentFolderTitle: String? = nil,
        assetIdentifiers: [String] = [],
        coverAssetIdentifier: String? = nil,
        enableEdgeDetection: Bool = true,
        assetCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.parentFolderID = parentFolderID
        self.parentFolderTitle = parentFolderTitle
        self.assetIdentifiers = assetIdentifiers
        self.coverAssetIdentifier = coverAssetIdentifier ?? assetIdentifiers.first
        self.enableEdgeDetection = enableEdgeDetection
        self.explicitAssetCount = assetCount ?? (assetIdentifiers.isEmpty ? nil : assetIdentifiers.count)
    }
}

// MARK: - SystemPhotoFolderNode

/// 代表 iOS 系統相簿中的一個使用者資料夾（對應 ChekiLens 的「團體分類」）
nonisolated struct SystemPhotoFolderNode: Identifiable, Equatable, Hashable, Sendable {
    /// 對應 `PHCollectionList.localIdentifier`
    let id: String
    /// 資料夾標題（預設對應團體名稱 `IdolGroup.name`）
    var title: String
    /// 資料夾直接包含的相簿清單
    var albums: [SystemPhotoAlbumNode]
    /// 巢狀子資料夾清單
    var subfolders: [SystemPhotoFolderNode]

    init(
        id: String,
        title: String,
        albums: [SystemPhotoAlbumNode] = [],
        subfolders: [SystemPhotoFolderNode] = []
    ) {
        self.id = id
        self.title = title
        self.albums = albums
        self.subfolders = subfolders
    }

    /// 遞迴攤平此資料夾與所有子資料夾內的相簿
    var allAlbums: [SystemPhotoAlbumNode] {
        var result = albums
        for subfolder in subfolders {
            result.append(contentsOf: subfolder.allAlbums)
        }
        return result
    }

    /// 資料夾與子資料夾內所有相簿的相片總數
    var totalAssetCount: Int {
        allAlbums.reduce(0) { $0 + $1.assetCount }
    }
}

// MARK: - SystemPhotoLibraryHierarchy

/// 使用者系統相簿的完整樹狀結構（包含「資料夾 → 相簿」與「根目錄獨立相簿」）
nonisolated struct SystemPhotoLibraryHierarchy: Equatable, Sendable {
    var folders: [SystemPhotoFolderNode]
    var standaloneAlbums: [SystemPhotoAlbumNode]

    init(
        folders: [SystemPhotoFolderNode] = [],
        standaloneAlbums: [SystemPhotoAlbumNode] = []
    ) {
        self.folders = folders
        self.standaloneAlbums = standaloneAlbums
    }

    /// 攤平所有資料夾內的相簿與獨立相簿（依相簿 ID 保持唯一順序）
    var allAlbums: [SystemPhotoAlbumNode] {
        var seen = Set<String>()
        var result: [SystemPhotoAlbumNode] = []
        for folder in folders {
            for album in folder.allAlbums where seen.insert(album.id).inserted {
                result.append(album)
            }
        }
        for album in standaloneAlbums where seen.insert(album.id).inserted {
            result.append(album)
        }
        return result
    }

    var isEmpty: Bool {
        allAlbums.isEmpty
    }

    /// 取得指定資料夾（包含其子資料夾）內所有相簿的 ID 集合
    func albumIDs(inFolder folderID: String) -> Set<String> {
        guard let folder = findFolder(withID: folderID, in: folders) else {
            return []
        }
        return Set(folder.allAlbums.map(\.id))
    }

    /// 判斷指定資料夾內的所有相簿是否已全部被選取
    func isFolderFullySelected(_ folderID: String, selectedAlbumIDs: Set<String>) -> Bool {
        let ids = albumIDs(inFolder: folderID)
        guard !ids.isEmpty else { return false }
        return ids.isSubset(of: selectedAlbumIDs)
    }

    /// 判斷指定資料夾是否處於「部分選取」狀態
    func isFolderPartiallySelected(_ folderID: String, selectedAlbumIDs: Set<String>) -> Bool {
        let ids = albumIDs(inFolder: folderID)
        guard !ids.isEmpty else { return false }
        let intersection = ids.intersection(selectedAlbumIDs)
        return !intersection.isEmpty && intersection.count < ids.count
    }

    /// 切換整個資料夾的選取狀態：若已全選則取消該資料夾內所有相簿，否則全選該資料夾內所有相簿
    func togglingFolder(_ folderID: String, in selectedAlbumIDs: Set<String>) -> Set<String> {
        let ids = albumIDs(inFolder: folderID)
        guard !ids.isEmpty else { return selectedAlbumIDs }
        var updated = selectedAlbumIDs
        if ids.isSubset(of: selectedAlbumIDs) {
            updated.subtract(ids)
        } else {
            updated.formUnion(ids)
        }
        return updated
    }

    /// 根據選取的相簿 ID 與個別相簿的邊緣偵測設定，輸出準備送入工作台的相簿清單
    func resolvedSelectedAlbums(
        selectedAlbumIDs: Set<String>,
        edgeDetectionOverrides: [String: Bool],
        defaultEdgeDetection: Bool = true
    ) -> [SystemPhotoAlbumNode] {
        allAlbums.compactMap { album in
            guard selectedAlbumIDs.contains(album.id) else { return nil }
            var copy = album
            copy.enableEdgeDetection = edgeDetectionOverrides[album.id] ?? defaultEdgeDetection
            return copy
        }
    }

    private func findFolder(withID targetID: String, in list: [SystemPhotoFolderNode]) -> SystemPhotoFolderNode? {
        for folder in list {
            if folder.id == targetID {
                return folder
            }
            if let found = findFolder(withID: targetID, in: folder.subfolders) {
                return found
            }
        }
        return nil
    }
}

// MARK: - SystemImportedAssetPayload

/// 從系統相簿單張 `PHAsset` 讀取出的完整影像與中繼資料封包
struct SystemImportedAssetPayload: @unchecked Sendable {
    let assetIdentifier: String
    let imageData: Data
    let uiImage: UIImage
    let creationDate: Date?
    let pixelSize: CGSize

    /// 當關閉邊緣偵測（相片已事先裁切）時，依原圖長寬比自動推斷最匹配的拍立得相紙規格
    var inferredFilmFormat: FilmFormat {
        SystemAlbumExplorerService.inferFilmFormat(for: pixelSize)
    }
}

// MARK: - SystemAlbumExplorerService

/// 負責探索 iOS 系統相簿階層（資料夾 → 相簿）、載入縮圖與原圖、以及檢驗重複 Asset 之服務核心
final class SystemAlbumExplorerService: Sendable {
    static let shared = SystemAlbumExplorerService()

    init() {}

    private final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var _isCancelled = false
        var isCancelled: Bool {
            get { lock.withLock { _isCancelled } }
            set { lock.withLock { _isCancelled = newValue } }
        }
    }

    // MARK: - 1. 取得系統資料夾與相簿階層樹狀結構

    /// 掃描使用者系統相簿中的頂層資料夾與獨立相簿，建構 `SystemPhotoLibraryHierarchy`
    /// - Parameter includeEmptyAlbums: 是否保留相片數為 0 的空相簿與空資料夾（預設 `false`）
    func fetchHierarchy(includeEmptyAlbums: Bool = false) async -> SystemPhotoLibraryHierarchy {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let hasPermission: Bool
        if status == .authorized || status == .limited {
            hasPermission = true
        } else {
            hasPermission = await PhotoLibraryManager.shared.requestAuthorization()
        }
        guard hasPermission, !Task.isCancelled else {
            return SystemPhotoLibraryHierarchy()
        }

        let token = CancelToken()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Self.buildHierarchySynchronously(
                    includeEmptyAlbums: includeEmptyAlbums,
                    shouldCancel: { token.isCancelled }
                )
            }.value
        } onCancel: {
            token.isCancelled = true
        }
    }

    private static func buildHierarchySynchronously(
        includeEmptyAlbums: Bool,
        shouldCancel: (() -> Bool)? = nil
    ) -> SystemPhotoLibraryHierarchy {
        if shouldCancel?() == true { return SystemPhotoLibraryHierarchy() }
        let topLevelCollections = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        var folders: [SystemPhotoFolderNode] = []
        var standaloneAlbums: [SystemPhotoAlbumNode] = []

        topLevelCollections.enumerateObjects { collection, _, stop in
            if shouldCancel?() == true {
                stop.pointee = true
                return
            }
            if let folder = collection as? PHCollectionList {
                if let folderNode = parseFolder(
                    folder,
                    inheritedGroupName: nil,
                    includeEmptyAlbums: includeEmptyAlbums,
                    shouldCancel: shouldCancel
                ) {
                    folders.append(folderNode)
                }
            } else if let album = collection as? PHAssetCollection {
                if let albumNode = parseAlbum(
                    album,
                    parentFolderID: nil,
                    parentFolderTitle: nil,
                    includeEmptyAlbums: includeEmptyAlbums
                ) {
                    standaloneAlbums.append(albumNode)
                }
            }
        }

        if shouldCancel?() == true { return SystemPhotoLibraryHierarchy() }

        return SystemPhotoLibraryHierarchy(
            folders: folders,
            standaloneAlbums: standaloneAlbums
        )
    }

    private static func parseFolder(
        _ folder: PHCollectionList,
        inheritedGroupName: String?,
        includeEmptyAlbums: Bool,
        shouldCancel: (() -> Bool)? = nil
    ) -> SystemPhotoFolderNode? {
        if shouldCancel?() == true { return nil }
        let rawTitle = (folder.localizedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folderTitle = rawTitle.isEmpty ? L10n.tr("未命名資料夾", "名称未設定フォルダ") : rawTitle

        // 若頂層資料夾名為 "ChekiLens"（App 自動同步建立之根容器），其直接子相簿不強制視為名為 ChekiLens 的團體
        let effectiveGroupTitle: String? = {
            if normalizedNameKey(folderTitle) == normalizedNameKey("ChekiLens") {
                return inheritedGroupName
            }
            return folderTitle
        }()

        let childCollections = PHCollectionList.fetchCollections(in: folder, options: nil)
        var childAlbums: [SystemPhotoAlbumNode] = []
        var childSubfolders: [SystemPhotoFolderNode] = []

        childCollections.enumerateObjects { child, _, stop in
            if shouldCancel?() == true {
                stop.pointee = true
                return
            }
            if let subfolder = child as? PHCollectionList {
                if let subNode = parseFolder(
                    subfolder,
                    inheritedGroupName: effectiveGroupTitle,
                    includeEmptyAlbums: includeEmptyAlbums,
                    shouldCancel: shouldCancel
                ) {
                    childSubfolders.append(subNode)
                }
            } else if let album = child as? PHAssetCollection {
                if let albumNode = parseAlbum(
                    album,
                    parentFolderID: folder.localIdentifier,
                    parentFolderTitle: effectiveGroupTitle,
                    includeEmptyAlbums: includeEmptyAlbums
                ) {
                    childAlbums.append(albumNode)
                }
            }
        }

        if !includeEmptyAlbums && childAlbums.isEmpty && childSubfolders.isEmpty {
            return nil
        }

        return SystemPhotoFolderNode(
            id: folder.localIdentifier,
            title: folderTitle,
            albums: childAlbums,
            subfolders: childSubfolders
        )
    }

    private static func parseAlbum(
        _ album: PHAssetCollection,
        parentFolderID: String?,
        parentFolderTitle: String?,
        includeEmptyAlbums: Bool
    ) -> SystemPhotoAlbumNode? {
        let rawTitle = (album.localizedTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let albumTitle = rawTitle.isEmpty ? L10n.tr("未命名相簿", "名称未設定アルバム") : rawTitle

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let assetsResult = PHAsset.fetchAssets(in: album, options: fetchOptions)
        let count = assetsResult.count

        if !includeEmptyAlbums && count == 0 {
            return nil
        }

        // 極速輕量掃描：僅取得封面小圖之 localIdentifier，不在此處枚舉數千張 Asset
        let coverID = assetsResult.lastObject?.localIdentifier ?? assetsResult.firstObject?.localIdentifier

        return SystemPhotoAlbumNode(
            id: album.localIdentifier,
            title: albumTitle,
            parentFolderID: parentFolderID,
            parentFolderTitle: parentFolderTitle,
            assetIdentifiers: [],
            coverAssetIdentifier: coverID,
            enableEdgeDetection: true,
            assetCount: count
        )
    }

    // MARK: - 延遲解析選定相簿之相片 Identifiers

    /// 根據相簿 Collection ID 查詢並取得其內部所有影像之 localIdentifier 清單
    static func resolveAssetIdentifiers(for albumID: String) -> [String] {
        guard !albumID.isEmpty,
              let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID],
                options: nil
              ).firstObject else {
            return []
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assetsResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
        var assetIDs: [String] = []
        assetIDs.reserveCapacity(assetsResult.count)
        assetsResult.enumerateObjects { asset, _, _ in
            assetIDs.append(asset.localIdentifier)
        }
        return assetIDs
    }

    /// 若相簿的 `assetIdentifiers` 尚未載入（延遲模式），為其補齊完整清單
    static func populateAssetIdentifiers(for albums: [SystemPhotoAlbumNode]) -> [SystemPhotoAlbumNode] {
        albums.map { album in
            var node = album
            if node.assetIdentifiers.isEmpty && node.assetCount > 0 {
                let resolvedIDs = resolveAssetIdentifiers(for: node.id)
                node.assetIdentifiers = resolvedIDs
                if node.coverAssetIdentifier == nil {
                    node.coverAssetIdentifier = resolvedIDs.last ?? resolvedIDs.first
                }
            }
            return node
        }
    }

    // MARK: - 2. 載入縮圖與完整影像資料

    /// 讀取指定 `PHAsset.localIdentifier` 的快速縮圖（供相簿選擇清單與工作台預覽磚顯示）
    func requestThumbnail(
        for assetIdentifier: String,
        targetSize: CGSize = CGSize(width: 240, height: 240)
    ) async -> UIImage? {
        guard !assetIdentifier.isEmpty,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !didResume else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    /// 讀取指定 `PHAsset.localIdentifier` 的完整渲染影像與 EXIF 建立時間
    func loadFullImagePayload(for assetIdentifier: String) async -> SystemImportedAssetPayload? {
        guard !assetIdentifier.isEmpty,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            return nil
        }

        let rawData: Data? = await withCheckedContinuation { continuation in
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

        guard let rawData,
              let rawImage = UIImage(data: rawData) else {
            return nil
        }

        let normalizedImage = rawImage.normalizedImage
        let jpegData = normalizedImage.jpegData(compressionQuality: 0.92) ?? rawData
        let pixelSize: CGSize = {
            if let cgImage = normalizedImage.cgImage {
                return CGSize(width: cgImage.width, height: cgImage.height)
            }
            return normalizedImage.size
        }()

        return SystemImportedAssetPayload(
            assetIdentifier: asset.localIdentifier,
            imageData: jpegData,
            uiImage: normalizedImage,
            creationDate: asset.creationDate,
            pixelSize: pixelSize
        )
    }

    // MARK: - 3. 重複 Asset 檢驗與同名正規化比對核心

    /// 從既有 `ChekiItem` 清單收集所有已匯入過的系統相簿 `PHAsset.localIdentifier`（包含正面與背面）
    static func collectExistingAssetIdentifiers(from items: [ChekiItem]) -> Set<String> {
        var identifiers = Set<String>()
        for item in items {
            if let frontID = item.frontAssetIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !frontID.isEmpty {
                identifiers.insert(frontID)
            }
            if let backID = item.backAssetIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !backID.isEmpty {
                identifiers.insert(backID)
            }
        }
        return identifiers
    }

    /// 過濾相簿內的 `assetIdentifiers`，剔除已存在於資料庫或同批次已出現過的重複項目
    /// - Returns: `newIdentifiers` 為尚未匯入的唯一 Asset ID 清單；`skippedDuplicateCount` 為略過的重複張數
    static func filterNewAssetIdentifiers(
        _ candidates: [String],
        excluding existingIdentifiers: Set<String>
    ) -> (newIdentifiers: [String], skippedDuplicateCount: Int) {
        var seen = existingIdentifiers
        var newIdentifiers: [String] = []
        var skippedCount = 0

        for rawID in candidates {
            let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                newIdentifiers.append(trimmed)
            } else {
                skippedCount += 1
            }
        }

        return (newIdentifiers, skippedCount)
    }

    /// 將團體或成員名稱正規化為比對鍵（去除前後空白、統一大小寫與全半形相容分解），供同名自動合併判斷
    nonisolated static func normalizedNameKey(_ rawName: String) -> String {
        rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
    }

    nonisolated static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedNameKey(lhs) == normalizedNameKey(rhs)
    }

    /// 當關閉邊緣偵測（相片已事先裁切）時，依影像像素尺寸推斷拍立得相紙規格（`Mini` / `Square` / `Wide`）
    nonisolated static func inferFilmFormat(for imageSize: CGSize) -> FilmFormat {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return .mini
        }
        return FilmFormat.resolvedConcreteFormat(
            preferred: .auto,
            specName: nil,
            outputSize: imageSize
        )
    }
}
