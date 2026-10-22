import XCTest
import UIKit
import SwiftData
@testable import ChekiLens

// MARK: - Mocks

private final class MockPhotoAssetDataLoader: PhotoAssetDataLoaderProtocol, @unchecked Sendable {
    var storedImages: [String: Data] = [:]
    var savedImages: [(image: UIImage, date: Date)] = []
    var nextGeneratedLocalID = "generated-local-id-123"

    func fetchImageData(forLocalIdentifier localIdentifier: String) async -> Data? {
        storedImages[localIdentifier]
    }

    func saveImageToSystemPhotoLibrary(_ image: UIImage, creationDate: Date) async throws -> String {
        savedImages.append((image, creationDate))
        storedImages[nextGeneratedLocalID] = image.jpegData(compressionQuality: 0.8)
        return nextGeneratedLocalID
    }
}

private final class MockCloudKitAssetFetcher: CloudKitAssetFetcherProtocol, @unchecked Sendable {
    var remoteAssets: [String: Data] = [:]
    var fetchCallCount: Int = 0

    func fetchAssetData(recordName: String, field: String) async throws -> Data? {
        fetchCallCount += 1
        try? await Task.sleep(nanoseconds: 20_000_000)
        return remoteAssets["\(recordName)_\(field)"]
    }
}

// MARK: - Tests

final class ChekiCloudAssetServiceTests: XCTestCase {

    private var tempDirectory: URL!
    private var mockMapper: MockPhotoCloudIdentifierMapper!
    private var mockPhotoLoader: MockPhotoAssetDataLoader!
    private var mockCloudFetcher: MockCloudKitAssetFetcher!
    private var testUserDefaults: UserDefaults!
    private var cacheManager: ChekiImageCacheManager!
    private var sut: ChekiCloudAssetService!
    private var modelContainer: ModelContainer!
    private var modelContext: ModelContext!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let config = ChekiImageCacheManager.Configuration(maxDiskSizeBytes: 10 * 1024 * 1024)
        cacheManager = ChekiImageCacheManager(configuration: config, diskCacheURL: tempDirectory)

        mockMapper = MockPhotoCloudIdentifierMapper()
        mockPhotoLoader = MockPhotoAssetDataLoader()
        mockCloudFetcher = MockCloudKitAssetFetcher()

        let userDefaultsSuiteName = "ChekiCloudAssetServiceTests_\(UUID().uuidString)"
        testUserDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!

        sut = ChekiCloudAssetService(
            mapper: mockMapper,
            cacheManager: cacheManager,
            photoLoader: mockPhotoLoader,
            cloudFetcher: mockCloudFetcher,
            userDefaults: testUserDefaults
        )

        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try! ModelContainer(for: ChekiItem.self, configurations: modelConfig)
        modelContext = ModelContext(modelContainer)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        cacheManager = nil
        sut = nil
        modelContainer = nil
        modelContext = nil
        super.tearDown()
    }

    private func makeTestImage(color: UIColor = .systemBlue, size: CGSize = CGSize(width: 200, height: 300)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Test Cases

    func test_resolveImage_directData() async throws {
        let testImage = makeTestImage()
        let jpegData = testImage.jpegData(compressionQuality: 0.85)!

        let item = ChekiItem(frontImageData: jpegData)
        modelContext.insert(item)

        let resolved = try await sut.resolveImage(for: item, side: .front)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.source, .directData)
    }

    func test_resolveImage_diskCache() async throws {
        let testImage = makeTestImage()
        let item = ChekiItem()
        modelContext.insert(item)

        let key = cacheManager.cacheKey(for: item.id, type: .front)
        try await cacheManager.store(image: testImage, forKey: key)
        cacheManager.clearMemoryCache()

        let resolved = try await sut.resolveImage(for: item, side: .front)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.source, .diskCache)
    }

    func test_resolveImage_track1_photosLibraryDirectLookup() async throws {
        let testImage = makeTestImage()
        let jpegData = testImage.jpegData(compressionQuality: 0.85)!
        let cloudID = "cloud-asset-uuid-1"
        let localID = "local-photos-asset-id-1"

        mockMapper.register(localIdentifier: localID, cloudIdentifier: cloudID)
        mockPhotoLoader.storedImages[localID] = jpegData

        let item = ChekiItem(cloudIdentifier: cloudID)
        modelContext.insert(item)

        let resolved = try await sut.resolveImage(for: item, side: .front)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.source, .localPhotosLibrary(localIdentifier: localID))
        XCTAssertEqual(item.frontAssetIdentifier, localID)
    }

    func test_resolveImage_track2A_cloudKitAsset_withoutPhotoSync() async throws {
        let testImage = makeTestImage()
        let jpegData = testImage.jpegData(compressionQuality: 0.85)!

        let item = ChekiItem()
        modelContext.insert(item)

        mockCloudFetcher.remoteAssets["\(item.id.uuidString)_frontImageData"] = jpegData
        testUserDefaults.set(false, forKey: "autoSyncToPhotosLibrary")

        let resolved = try await sut.resolveImage(for: item, side: .front)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.source, .cloudKitAsset)
        XCTAssertEqual(mockPhotoLoader.savedImages.count, 0, "Should not save to local photos when sync is disabled")
    }

    func test_resolveImage_track2B_cloudKitAsset_withPhotoSync_autoExportsToPhotos() async throws {
        let testImage = makeTestImage()
        let jpegData = testImage.jpegData(compressionQuality: 0.85)!

        let item = ChekiItem()
        modelContext.insert(item)

        mockCloudFetcher.remoteAssets["\(item.id.uuidString)_frontImageData"] = jpegData
        testUserDefaults.set(true, forKey: "autoSyncToPhotosLibrary")

        let resolved = try await sut.resolveImage(for: item, side: .front)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.source, .cloudKitAsset)
        XCTAssertEqual(mockPhotoLoader.savedImages.count, 1, "Should auto-export to local photos")
        XCTAssertEqual(item.frontAssetIdentifier, "generated-local-id-123")
        XCTAssertTrue(item.isSyncedToPhotoLibrary)
    }

    func test_resolveImage_concurrentRequestsDeduplicated() async throws {
        let testImage = makeTestImage()
        let jpegData = testImage.jpegData(compressionQuality: 0.85)!

        let item = ChekiItem()
        modelContext.insert(item)

        mockCloudFetcher.remoteAssets["\(item.id.uuidString)_frontImageData"] = jpegData

        async let call1 = sut.resolveImage(for: item, side: .front)
        async let call2 = sut.resolveImage(for: item, side: .front)

        let (res1, res2) = try await (call1, call2)
        XCTAssertNotNil(res1)
        XCTAssertNotNil(res2)
        XCTAssertEqual(mockCloudFetcher.fetchCallCount, 1, "Concurrent requests should be deduplicated to 1 call")
    }

    func test_resolveImage_fallbackToThumbnail() async throws {
        let thumbImage = makeTestImage(size: CGSize(width: 80, height: 120))
        let thumbData = thumbImage.jpegData(compressionQuality: 0.8)!

        let item = ChekiItem(thumbnailData: thumbData)
        modelContext.insert(item)

        let resolved = try await sut.resolveImage(for: item, side: .front)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.source, .fallbackThumbnail)
    }
}
