import Foundation
import UIKit
import Photos
import CloudKit
import SwiftData

/// 拍立得卡片面別列舉
public enum ChekiCardSide: String, Sendable, CaseIterable {
    case front
    case back
    case originalFront
    case originalBack

    public var fieldName: String {
        switch self {
        case .front: return "frontImageData"
        case .back: return "backImageData"
        case .originalFront: return "originalFrontImageData"
        case .originalBack: return "originalBackImageData"
        }
    }

    public var imageType: ChekiImageType {
        switch self {
        case .front: return .front
        case .back: return .back
        case .originalFront: return .originalFront
        case .originalBack: return .originalBack
        }
    }
}

/// 資源來源解析標籤
public enum AssetSource: Sendable, Equatable {
    case directData
    case diskCache
    case localPhotosLibrary(localIdentifier: String)
    case cloudKitAsset
    case fallbackThumbnail
}

/// 解析後的影像實體包裝
public struct ResolvedAsset: Sendable {
    public let image: UIImage
    public let data: Data?
    public let source: AssetSource

    public init(image: UIImage, data: Data?, source: AssetSource) {
        self.image = image
        self.data = data
        self.source = source
    }
}

// MARK: - Protocols for Decoupling & Testability

/// 本機相簿資料載入器協議
public protocol PhotoAssetDataLoaderProtocol: Sendable {
    func fetchImageData(forLocalIdentifier localIdentifier: String) async -> Data?
    func saveImageToSystemPhotoLibrary(_ image: UIImage, creationDate: Date) async throws -> String
}

/// 預設本機相片載入器
public final class DefaultPhotoAssetDataLoader: PhotoAssetDataLoaderProtocol {
    public init() {}

    public func fetchImageData(forLocalIdentifier localIdentifier: String) async -> Data? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }

        return await withCheckedContinuation { continuation in
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

    public func saveImageToSystemPhotoLibrary(_ image: UIImage, creationDate: Date) async throws -> String {
        try await PhotoLibraryManager.shared.saveImage(image, creationDate: creationDate)
    }
}

/// CloudKit 遠端 Asset 下載器協議
public protocol CloudKitAssetFetcherProtocol: Sendable {
    func fetchAssetData(recordName: String, field: String) async throws -> Data?
}

/// 預設 CloudKit 遠端 Asset 下載器
public final class DefaultCloudKitAssetFetcher: CloudKitAssetFetcherProtocol {
    private let container: CKContainer

    public init(container: CKContainer = .default()) {
        self.container = container
    }

    public func fetchAssetData(recordName: String, field: String) async throws -> Data? {
        let recordID = CKRecord.ID(recordName: recordName)
        let database = container.privateCloudDatabase

        do {
            let record = try await database.record(for: recordID)
            if let asset = record[field] as? CKAsset, let fileURL = asset.fileURL {
                return try? Data(contentsOf: fileURL)
            }
            if let directData = record[field] as? Data {
                return directData
            }
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - ChekiCloudAssetService Core

/// 雙軌圖片管理與隨選快取管線服務
/// 負責優先尋址本機相簿（零網路流量），若無則走 CloudKit 隨選快取並支援自動寫入相簿
public final class ChekiCloudAssetService: @unchecked Sendable {

    public static let shared = ChekiCloudAssetService()

    private let mapper: PhotoCloudIdentifierMappingProtocol
    private let cacheManager: ChekiImageCacheManager
    private let photoLoader: PhotoAssetDataLoaderProtocol
    private let cloudFetcher: CloudKitAssetFetcherProtocol
    private let userDefaults: UserDefaults

    private let taskLock = NSLock()
    private var inFlightTasks: [String: Task<ResolvedAsset?, Error>] = [:]

    public init(
        mapper: PhotoCloudIdentifierMappingProtocol = PhotoCloudIdentifierMapper(),
        cacheManager: ChekiImageCacheManager = .shared,
        photoLoader: PhotoAssetDataLoaderProtocol = DefaultPhotoAssetDataLoader(),
        cloudFetcher: CloudKitAssetFetcherProtocol = DefaultCloudKitAssetFetcher(),
        userDefaults: UserDefaults = .standard
    ) {
        self.mapper = mapper
        self.cacheManager = cacheManager
        self.photoLoader = photoLoader
        self.cloudFetcher = cloudFetcher
        self.userDefaults = userDefaults
    }

    // MARK: - Synchronous In-Memory Lookups

    /// 同步快速檢查記憶體快取或 SwiftData 內嵌圖檔
    func synchronousImage(for item: ChekiItem, side: ChekiCardSide = .front) -> UIImage? {
        guard !item.isDeleted && item.modelContext != nil else { return nil }
        let key = cacheManager.cacheKey(for: item.id, type: side.imageType)

        if let memoryHit = cacheManager.memoryImage(forKey: key) {
            return memoryHit
        }

        let directData: Data? = {
            switch side {
            case .front: return item.frontImageData
            case .back: return item.backImageData
            case .originalFront: return item.originalFrontImageData
            case .originalBack: return item.originalBackImageData
            }
        }()

        if let directData, let image = UIImage(data: directData) {
            cacheManager.setMemoryImage(image, forKey: key, cost: directData.count)
            return image
        }

        if side == .front {
            return cacheManager.syncThumbnail(for: item)
        }

        return nil
    }

    // MARK: - Dual-Track Asynchronous Resolution

    /// 解析指定拍立得影像（支援並行任務去重、本機相簿零流量直讀與 CloudKit 隨選下載）
    func resolveImage(
        for item: ChekiItem,
        side: ChekiCardSide = .front
    ) async throws -> ResolvedAsset? {
        guard !item.isDeleted && item.modelContext != nil else { return nil }
        let key = cacheManager.cacheKey(for: item.id, type: side.imageType)

        taskLock.lock()
        if let ongoing = inFlightTasks[key] {
            taskLock.unlock()
            return try await ongoing.value
        }

        let task = Task<ResolvedAsset?, Error> {
            defer {
                self.taskLock.lock()
                self.inFlightTasks.removeValue(forKey: key)
                self.taskLock.unlock()
            }
            return try await self.executeResolve(for: item, side: side, key: key)
        }

        inFlightTasks[key] = task
        taskLock.unlock()

        return try await task.value
    }

    private func executeResolve(
        for item: ChekiItem,
        side: ChekiCardSide,
        key: String
    ) async throws -> ResolvedAsset? {
        // 1. 記憶體快取
        if let memoryHit = cacheManager.memoryImage(forKey: key) {
            return ResolvedAsset(image: memoryHit, data: nil, source: .directData)
        }

        // 2. 實體內建資料 (SwiftData Direct)
        let directData: Data? = {
            switch side {
            case .front: return item.frontImageData
            case .back: return item.backImageData
            case .originalFront: return item.originalFrontImageData
            case .originalBack: return item.originalBackImageData
            }
        }()

        if let directData, let image = UIImage(data: directData) {
            cacheManager.setMemoryImage(image, forKey: key, cost: directData.count)
            return ResolvedAsset(image: image, data: directData, source: .directData)
        }

        // 3. 磁碟快取
        if let diskData = await cacheManager.data(forKey: key),
           let diskImage = UIImage(data: diskData) {
            cacheManager.setMemoryImage(diskImage, forKey: key, cost: diskData.count)
            return ResolvedAsset(image: diskImage, data: diskData, source: .diskCache)
        }

        // 4. 軌道 1：零流量本機系統相簿直讀 (PHCloudIdentifier Lookup)
        let targetCloudID: String? = {
            switch side {
            case .front, .originalFront: return item.cloudIdentifier
            case .back, .originalBack: return item.backCloudIdentifier
            }
        }()

        if let targetCloudID, !targetCloudID.isEmpty {
            if let localID = mapper.localIdentifier(forCloudIdentifier: targetCloudID) {
                if let photoData = await photoLoader.fetchImageData(forLocalIdentifier: localID),
                   let photoImg = UIImage(data: photoData) {
                    try? await cacheManager.store(image: photoImg, data: photoData, forKey: key)
                    if side == .front && item.frontAssetIdentifier == nil {
                        item.frontAssetIdentifier = localID
                    } else if side == .back && item.backAssetIdentifier == nil {
                        item.backAssetIdentifier = localID
                    }
                    return ResolvedAsset(image: photoImg, data: photoData, source: .localPhotosLibrary(localIdentifier: localID))
                }
            }
        }

        // 5. 軌道 2A / 2B：CloudKit 遠端 Asset 隨選下載
        if let cloudData = try await cloudFetcher.fetchAssetData(recordName: item.id.uuidString, field: side.fieldName),
           let cloudImg = UIImage(data: cloudData) {
            try? await cacheManager.store(image: cloudImg, data: cloudData, forKey: key)

            // 軌道 2B：若本機啟用「相簿同步」且該照片尚未於本機相簿建檔，下載後自動存入本機相簿
            let autoSyncPhotos = userDefaults.bool(forKey: "autoSyncToPhotosLibrary")
            let hasLocalAsset = (side == .front ? item.frontAssetIdentifier : item.backAssetIdentifier) != nil

            if autoSyncPhotos && !hasLocalAsset {
                if let savedID = try? await photoLoader.saveImageToSystemPhotoLibrary(cloudImg, creationDate: item.capturedAt) {
                    if side == .front {
                        item.frontAssetIdentifier = savedID
                        item.isSyncedToPhotoLibrary = true
                    } else if side == .back {
                        item.backAssetIdentifier = savedID
                    }
                }
            }

            return ResolvedAsset(image: cloudImg, data: cloudData, source: .cloudKitAsset)
        }

        // 6. 兜底降級策略：退回輕量縮圖
        if side == .front, let thumb = await cacheManager.resolveThumbnail(for: item) {
            return ResolvedAsset(image: thumb, data: item.thumbnailData, source: .fallbackThumbnail)
        }

        return nil
    }
}
