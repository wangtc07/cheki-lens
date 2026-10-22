import Foundation
import Photos
import OSLog

// MARK: - PhotoCloudIdentifierMappingProtocol

/// 相片本機識別碼 (localIdentifier) 與跨裝置通用雲端識別碼 (PHCloudIdentifier) 之雙向轉換協議
public protocol PhotoCloudIdentifierMappingProtocol: Sendable {

    /// 依據本機識別碼解析出跨裝置通用之 PHCloudIdentifier 字串
    func cloudIdentifier(forLocalIdentifier localIdentifier: String) -> String?

    /// 依據 PHCloudIdentifier 字串反查本機相片識別碼
    func localIdentifier(forCloudIdentifier cloudIdentifier: String) -> String?

    /// 批次將本機識別碼陣列轉為 [localIdentifier: cloudIdentifier] 字典
    func batchCloudIdentifiers(forLocalIdentifiers localIdentifiers: [String]) -> [String: String]

    /// 批次將雲端識別碼陣列轉為 [cloudIdentifier: localIdentifier] 字典
    func batchLocalIdentifiers(forCloudIdentifiers cloudIdentifiers: [String]) -> [String: String]

    /// 驗證本機相片是否存在於 iOS 原生系統相簿中
    func assetExists(forLocalIdentifier localIdentifier: String) -> Bool
}

// MARK: - PhotoCloudIdentifierMapper

/// 實作 Apple Photos Framework 之 PHCloudIdentifier 雙向映射引擎（軌道 1 跨裝置尋址核心）
public final class PhotoCloudIdentifierMapper: PhotoCloudIdentifierMappingProtocol, @unchecked Sendable {

    public static let shared = PhotoCloudIdentifierMapper()

    private let photoLibrary: PHPhotoLibrary
    private let logger = Logger(subsystem: "com.chekilens.app", category: "PhotoCloudIdentifierMapper")

    public init(photoLibrary: PHPhotoLibrary = .shared()) {
        self.photoLibrary = photoLibrary
    }

    public func cloudIdentifier(forLocalIdentifier localIdentifier: String) -> String? {
        let trimmed = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return batchCloudIdentifiers(forLocalIdentifiers: [trimmed])[trimmed]
    }

    public func localIdentifier(forCloudIdentifier cloudIdentifier: String) -> String? {
        let trimmed = cloudIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return batchLocalIdentifiers(forCloudIdentifiers: [trimmed])[trimmed]
    }

    public func batchCloudIdentifiers(forLocalIdentifiers localIdentifiers: [String]) -> [String: String] {
        let validIDs = localIdentifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !validIDs.isEmpty else { return [:] }
        let mappings = photoLibrary.cloudIdentifierMappings(forLocalIdentifiers: validIDs)
        var result: [String: String] = [:]

        for (localID, mappingResult) in mappings {
            switch mappingResult {
            case .success(let cloudID):
                result[localID] = cloudID.stringValue
            case .failure(let error):
                logger.debug("Local ID \(localID) 無法取得 CloudIdentifier: \(error.localizedDescription)")
            }
        }
        return result
    }

    public func batchLocalIdentifiers(forCloudIdentifiers cloudIdentifiers: [String]) -> [String: String] {
        let validIDs = cloudIdentifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !validIDs.isEmpty else { return [:] }
        let phCloudIDs = validIDs.map { PHCloudIdentifier(stringValue: $0) }
        let mappings = photoLibrary.localIdentifierMappings(for: phCloudIDs)
        var result: [String: String] = [:]

        for (cloudID, mappingResult) in mappings {
            switch mappingResult {
            case .success(let localID):
                result[cloudID.stringValue] = localID
            case .failure(let error):
                logger.debug("Cloud ID \(cloudID.stringValue) 無法解析為本機 Local ID: \(error.localizedDescription)")
            }
        }
        return result
    }

    public func assetExists(forLocalIdentifier localIdentifier: String) -> Bool {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return fetchResult.firstObject != nil
    }
}

// MARK: - MockPhotoCloudIdentifierMapper

/// 供單元測試與離線模擬環境使用之記憶體映射實作
public final class MockPhotoCloudIdentifierMapper: PhotoCloudIdentifierMappingProtocol, @unchecked Sendable {

    private var localToCloud: [String: String]
    private var cloudToLocal: [String: String]
    private var existingLocalIDs: Set<String>

    public init(
        mappings: [String: String] = [:],
        existingLocalIDs: Set<String> = []
    ) {
        self.localToCloud = mappings
        self.cloudToLocal = Dictionary(uniqueKeysWithValues: mappings.map { ($1, $0) })
        self.existingLocalIDs = existingLocalIDs.isEmpty ? Set(mappings.keys) : existingLocalIDs
    }

    public func register(localIdentifier: String, cloudIdentifier: String) {
        localToCloud[localIdentifier] = cloudIdentifier
        cloudToLocal[cloudIdentifier] = localIdentifier
        existingLocalIDs.insert(localIdentifier)
    }

    public func cloudIdentifier(forLocalIdentifier localIdentifier: String) -> String? {
        localToCloud[localIdentifier]
    }

    public func localIdentifier(forCloudIdentifier cloudIdentifier: String) -> String? {
        cloudToLocal[cloudIdentifier]
    }

    public func batchCloudIdentifiers(forLocalIdentifiers localIdentifiers: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for id in localIdentifiers {
            if let cloud = localToCloud[id] {
                result[id] = cloud
            }
        }
        return result
    }

    public func batchLocalIdentifiers(forCloudIdentifiers cloudIdentifiers: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for id in cloudIdentifiers {
            if let local = cloudToLocal[id] {
                result[id] = local
            }
        }
        return result
    }

    public func assetExists(forLocalIdentifier localIdentifier: String) -> Bool {
        existingLocalIDs.contains(localIdentifier)
    }
}
