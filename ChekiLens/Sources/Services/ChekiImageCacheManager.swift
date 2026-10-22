import Foundation
import UIKit
import ImageIO
import SwiftData

/// 拍立得影像類型列舉
public enum ChekiImageType: String, Sendable, CaseIterable {
    case thumbnail
    case front
    case back
    case originalFront
    case originalBack
}

/// 拍立得影像快取管理員
/// 提供記憶體與磁碟雙層快取、輕量縮圖生成、LRU 磁碟空間淘汰與一鍵清理功能
public final class ChekiImageCacheManager: @unchecked Sendable {

    public static let shared = ChekiImageCacheManager()

    /// 快取組態設定
    public struct Configuration: Sendable {
        public var maxMemoryCountLimit: Int
        public var maxMemoryCostBytes: Int
        public var maxDiskSizeBytes: Int64
        public var targetThumbnailPixelSize: CGFloat
        public var thumbnailCompressionQuality: CGFloat

        public init(
            maxMemoryCountLimit: Int = 300,
            maxMemoryCostBytes: Int = 100 * 1024 * 1024,
            maxDiskSizeBytes: Int64 = 250 * 1024 * 1024,
            targetThumbnailPixelSize: CGFloat = 300,
            thumbnailCompressionQuality: CGFloat = 0.75
        ) {
            self.maxMemoryCountLimit = maxMemoryCountLimit
            self.maxMemoryCostBytes = maxMemoryCostBytes
            self.maxDiskSizeBytes = maxDiskSizeBytes
            self.targetThumbnailPixelSize = targetThumbnailPixelSize
            self.thumbnailCompressionQuality = thumbnailCompressionQuality
        }
    }

    public let configuration: Configuration
    public let diskCacheURL: URL

    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager()
    private let ioQueue = DispatchQueue(label: "wangtc07.ChekiLens.ImageCacheIO", qos: .userInitiated)

    public init(
        configuration: Configuration = Configuration(),
        diskCacheURL: URL? = nil
    ) {
        self.configuration = configuration

        if let diskCacheURL {
            self.diskCacheURL = diskCacheURL
        } else {
            let baseDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.diskCacheURL = baseDir.appendingPathComponent("ChekiImageCache", isDirectory: true)
        }

        memoryCache.countLimit = configuration.maxMemoryCountLimit
        memoryCache.totalCostLimit = configuration.maxMemoryCostBytes

        createCacheDirectoryIfNeeded()
    }

    // MARK: - Key Generation

    public func cacheKey(for itemID: UUID, type: ChekiImageType) -> String {
        "\(itemID.uuidString)_\(type.rawValue)"
    }

    private func fileURL(for key: String) -> URL {
        let safeName = key.replacingOccurrences(of: "/", with: "_")
        return diskCacheURL.appendingPathComponent("\(safeName).cache")
    }

    // MARK: - Synchronous In-Memory Operations

    public func memoryImage(forKey key: String) -> UIImage? {
        memoryCache.object(forKey: key as NSString)
    }

    public func setMemoryImage(_ image: UIImage, forKey key: String, cost: Int = 0) {
        let actualCost = cost > 0 ? cost : Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: actualCost)
    }

    public func removeMemoryImage(forKey key: String) {
        memoryCache.removeObject(forKey: key as NSString)
    }

    // MARK: - Asynchronous Operations

    public func store(
        image: UIImage,
        data: Data? = nil,
        forKey key: String
    ) async throws {
        setMemoryImage(image, forKey: key)

        let targetData: Data?
        if let data {
            targetData = data
        } else {
            targetData = image.jpegData(compressionQuality: 0.85)
        }

        guard let targetData else { return }

        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    self.createCacheDirectoryIfNeeded()
                    let url = self.fileURL(for: key)
                    try targetData.write(to: url, options: .atomic)
                    self.touchFile(at: url)
                    self.pruneDiskCacheIfNeeded()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func storeRawData(_ data: Data, forKey key: String) async throws {
        if let image = UIImage(data: data) {
            setMemoryImage(image, forKey: key)
        }

        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    self.createCacheDirectoryIfNeeded()
                    let url = self.fileURL(for: key)
                    try data.write(to: url, options: .atomic)
                    self.touchFile(at: url)
                    self.pruneDiskCacheIfNeeded()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func image(forKey key: String) async -> UIImage? {
        if let memoryHit = memoryImage(forKey: key) {
            return memoryHit
        }

        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let url = self.fileURL(for: key)
                guard self.fileManager.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url),
                      let decoded = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }

                self.touchFile(at: url)
                self.setMemoryImage(decoded, forKey: key, cost: data.count)
                continuation.resume(returning: decoded)
            }
        }
    }

    public func data(forKey key: String) async -> Data? {
        await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let url = self.fileURL(for: key)
                guard self.fileManager.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.touchFile(at: url)
                continuation.resume(returning: data)
            }
        }
    }

    public func remove(forKey key: String) async {
        removeMemoryImage(forKey: key)

        await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                let url = self.fileURL(for: key)
                try? self.fileManager.removeItem(at: url)
                continuation.resume()
            }
        }
    }

    /// 同步自記憶體與磁碟移除指定快取鍵之圖檔
    public func removeSync(forKey key: String) {
        removeMemoryImage(forKey: key)
        ioQueue.sync { [weak self] in
            guard let self else { return }
            let url = self.fileURL(for: key)
            try? self.fileManager.removeItem(at: url)
        }
    }

    /// 移除指定拍立得 UUID 之所有快取類型（縮圖、正面、背面、原始圖）
    public func removeAllImages(for itemID: UUID) async {
        for type in ChekiImageType.allCases {
            let key = cacheKey(for: itemID, type: type)
            await remove(forKey: key)
        }
    }

    /// 同步移除指定拍立得 UUID 之所有快取類型
    public func removeAllImagesSync(for itemID: UUID) {
        for type in ChekiImageType.allCases {
            let key = cacheKey(for: itemID, type: type)
            removeSync(forKey: key)
        }
    }

    // MARK: - Thumbnail Generation

    public func generateThumbnailData(
        from sourceData: Data,
        maxPixelSize: CGFloat? = nil,
        compressionQuality: CGFloat? = nil
    ) -> Data? {
        let maxPixel = maxPixelSize ?? configuration.targetThumbnailPixelSize
        let quality = compressionQuality ?? configuration.thumbnailCompressionQuality

        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: quality)
    }

    public func generateThumbnailImage(
        from sourceData: Data,
        maxPixelSize: CGFloat? = nil
    ) -> UIImage? {
        guard let thumbData = generateThumbnailData(from: sourceData, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return UIImage(data: thumbData)
    }

    // MARK: - ChekiItem High-Level Resolvers

    func syncThumbnail(for item: ChekiItem) -> UIImage? {
        guard !item.isDeleted && item.modelContext != nil else { return nil }
        let key = cacheKey(for: item.id, type: .thumbnail)

        if let cached = memoryImage(forKey: key) {
            return cached
        }

        if let thumbnailData = item.thumbnailData, let image = UIImage(data: thumbnailData) {
            setMemoryImage(image, forKey: key, cost: thumbnailData.count)
            return image
        }

        if let frontData = item.frontImageData, let image = generateThumbnailImage(from: frontData) {
            setMemoryImage(image, forKey: key)
            return image
        }

        return nil
    }

    func resolveThumbnail(for item: ChekiItem) async -> UIImage? {
        guard !item.isDeleted && item.modelContext != nil else { return nil }
        let key = cacheKey(for: item.id, type: .thumbnail)

        if let memoryHit = memoryImage(forKey: key) {
            return memoryHit
        }

        if let thumbnailData = item.thumbnailData, let image = UIImage(data: thumbnailData) {
            setMemoryImage(image, forKey: key, cost: thumbnailData.count)
            return image
        }

        if let diskImage = await self.image(forKey: key) {
            return diskImage
        }

        guard let frontData = item.frontImageData else { return nil }

        if let generated = generateThumbnailData(from: frontData),
           let thumbImage = UIImage(data: generated) {
            try? await store(image: thumbImage, data: generated, forKey: key)
            return thumbImage
        }

        return nil
    }

    // MARK: - Disk Management & LRU Eviction

    public func diskUsageBytes() async -> Int64 {
        await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: 0)
                    return
                }
                let total = self.calculateDiskUsage()
                continuation.resume(returning: total)
            }
        }
    }

    public func formattedDiskUsage() async -> String {
        let bytes = await diskUsageBytes()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public func pruneDiskCache(targetBytes: Int64? = nil) async {
        await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.performLRUPruning(targetLimit: targetBytes)
                continuation.resume()
            }
        }
    }

    public func clearDiskCache() async throws {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    if self.fileManager.fileExists(atPath: self.diskCacheURL.path) {
                        try self.fileManager.removeItem(at: self.diskCacheURL)
                    }
                    self.createCacheDirectoryIfNeeded()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    public func clearAll() async throws {
        clearMemoryCache()
        try await clearDiskCache()
    }

    // MARK: - Private Helpers

    private func createCacheDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: diskCacheURL.path) {
            try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        }
    }

    private func touchFile(at url: URL) {
        let attributes = [FileAttributeKey.modificationDate: Date()]
        try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private func calculateDiskUsage() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: diskCacheURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func pruneDiskCacheIfNeeded() {
        let currentSize = calculateDiskUsage()
        if currentSize > configuration.maxDiskSizeBytes {
            let target = Int64(Double(configuration.maxDiskSizeBytes) * 0.75)
            performLRUPruning(targetLimit: target)
        }
    }

    private func performLRUPruning(targetLimit: Int64?) {
        let limit = targetLimit ?? Int64(Double(configuration.maxDiskSizeBytes) * 0.75)

        guard let enumerator = fileManager.enumerator(
            at: diskCacheURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct CachedFileInfo {
            let url: URL
            let date: Date
            let size: Int64
        }

        var files: [CachedFileInfo] = []
        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let size = values.fileSize {
                let date = values.contentModificationDate ?? Date.distantPast
                let info = CachedFileInfo(url: fileURL, date: date, size: Int64(size))
                files.append(info)
                totalSize += Int64(size)
            }
        }

        guard totalSize > limit else { return }

        files.sort { $0.date < $1.date }

        for file in files {
            try? fileManager.removeItem(at: file.url)
            totalSize -= file.size
            if totalSize <= limit {
                break
            }
        }
    }
}

