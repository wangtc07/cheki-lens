import XCTest
import UIKit
import SwiftData
@testable import ChekiLens

final class ChekiImageCacheManagerTests: XCTestCase {

    private var tempDirectory: URL!
    private var sut: ChekiImageCacheManager!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let config = ChekiImageCacheManager.Configuration(
            maxMemoryCountLimit: 50,
            maxMemoryCostBytes: 10 * 1024 * 1024,
            maxDiskSizeBytes: 20 * 1024 * 1024,
            targetThumbnailPixelSize: 150,
            thumbnailCompressionQuality: 0.8
        )
        sut = ChekiImageCacheManager(configuration: config, diskCacheURL: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func makeTestImage(size: CGSize = CGSize(width: 400, height: 600), color: UIColor = .systemBlue) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Test Cases

    func test_storeAndRetrieveImage_memoryAndDisk() async throws {
        let image = makeTestImage()
        let key = "test_item_front"

        try await sut.store(image: image, forKey: key)

        let memoryHit = sut.memoryImage(forKey: key)
        XCTAssertNotNil(memoryHit)

        sut.clearMemoryCache()
        let memoryMiss = sut.memoryImage(forKey: key)
        XCTAssertNil(memoryMiss)

        let diskHit = await sut.image(forKey: key)
        XCTAssertNotNil(diskHit)

        let memoryRepopulated = sut.memoryImage(forKey: key)
        XCTAssertNotNil(memoryRepopulated)
    }

    func test_generateThumbnail_scalesDown() {
        let largeImage = makeTestImage(size: CGSize(width: 1000, height: 1600))
        guard let largeData = largeImage.jpegData(compressionQuality: 0.9) else {
            XCTFail("Failed to encode test image")
            return
        }

        let thumbData = sut.generateThumbnailData(from: largeData, maxPixelSize: 200)
        XCTAssertNotNil(thumbData)

        if let thumbData, let thumbImage = UIImage(data: thumbData) {
            let maxDimension = max(thumbImage.size.width, thumbImage.size.height)
            XCTAssertLessThanOrEqual(maxDimension, 201)
            XCTAssertGreaterThan(thumbData.count, 0)
            XCTAssertLessThan(thumbData.count, largeData.count)
        }
    }

    func test_lruPruning_removesOldestFiles() async throws {
        let smallConfig = ChekiImageCacheManager.Configuration(
            maxDiskSizeBytes: 3000
        )
        let lruManager = ChekiImageCacheManager(configuration: smallConfig, diskCacheURL: tempDirectory)

        let data1 = Data(repeating: 0xAA, count: 1200)
        let data2 = Data(repeating: 0xBB, count: 1200)
        let data3 = Data(repeating: 0xCC, count: 1200)

        try await lruManager.storeRawData(data1, forKey: "key1")
        try await Task.sleep(nanoseconds: 10_000_000)

        try await lruManager.storeRawData(data2, forKey: "key2")
        try await Task.sleep(nanoseconds: 10_000_000)

        try await lruManager.storeRawData(data3, forKey: "key3")

        await lruManager.pruneDiskCache(targetBytes: 1500)

        let item1 = await lruManager.data(forKey: "key1")
        let item3 = await lruManager.data(forKey: "key3")

        XCTAssertNil(item1, "Oldest item1 should be pruned")
        XCTAssertNotNil(item3, "Newest item3 should be retained")
    }

    func test_clearAll_wipesMemoryAndDisk() async throws {
        let image = makeTestImage()
        try await sut.store(image: image, forKey: "wipe_test")

        let usageBefore = await sut.diskUsageBytes()
        XCTAssertGreaterThan(usageBefore, 0)

        try await sut.clearAll()

        let usageAfter = await sut.diskUsageBytes()
        XCTAssertEqual(usageAfter, 0)
        XCTAssertNil(sut.memoryImage(forKey: "wipe_test"))
        let formatted = await sut.formattedDiskUsage()
        XCTAssertTrue(formatted.contains("0") || formatted.contains("Zero"))
    }

    func test_resolveThumbnail_forChekiItem_usesThumbnailDataFirst() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ChekiItem.self, configurations: config)
        let context = ModelContext(container)

        let thumbImage = makeTestImage(size: CGSize(width: 80, height: 120), color: .green)
        let thumbData = thumbImage.jpegData(compressionQuality: 0.8)!

        let item = ChekiItem(
            thumbnailData: thumbData
        )
        context.insert(item)

        let resolved = await sut.resolveThumbnail(for: item)
        XCTAssertNotNil(resolved)

        let cached = sut.syncThumbnail(for: item)
        XCTAssertNotNil(cached)
    }

    func test_resolveThumbnail_forChekiItem_generatesFromFrontData() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ChekiItem.self, configurations: config)
        let context = ModelContext(container)

        let frontImage = makeTestImage(size: CGSize(width: 800, height: 1200), color: .red)
        let frontData = frontImage.jpegData(compressionQuality: 0.85)!

        let item = ChekiItem(
            frontImageData: frontData
        )
        context.insert(item)

        let resolved = await sut.resolveThumbnail(for: item)
        XCTAssertNotNil(resolved)

        let key = sut.cacheKey(for: item.id, type: .thumbnail)
        let diskCached = await sut.image(forKey: key)
        XCTAssertNotNil(diskCached)
    }

    func test_replaceDisplayedImages_dropsPreviousAutoCrop() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ChekiItem.self, configurations: config)
        let context = ModelContext(container)

        let first = makeTestImage(size: CGSize(width: 80, height: 120), color: .blue)
        let firstData = try XCTUnwrap(first.jpegData(compressionQuality: 0.9))
        let item = ChekiItem(frontImageData: firstData, backImageData: firstData)
        context.insert(item)

        let frontKey = sut.cacheKey(for: item.id, type: .front)
        let backKey = sut.cacheKey(for: item.id, type: .back)
        sut.setMemoryImage(first, forKey: frontKey)
        sut.setMemoryImage(first, forKey: backKey)

        let revised = makeTestImage(size: CGSize(width: 90, height: 140), color: .red)
        let revisedData = try XCTUnwrap(revised.jpegData(compressionQuality: 0.9))
        item.frontImageData = revisedData
        item.backImageData = revisedData
        sut.replaceDisplayedImages(for: item)

        let cachedFront = try XCTUnwrap(sut.memoryImage(forKey: frontKey))
        let cachedBack = try XCTUnwrap(sut.memoryImage(forKey: backKey))
        XCTAssertEqual(cachedFront.cgImage?.width, revised.cgImage?.width, "正面應換成重新裁切後的圖")
        XCTAssertEqual(cachedBack.cgImage?.width, revised.cgImage?.width, "背面應換成重新裁切後的圖")
        XCTAssertNotEqual(cachedFront.cgImage?.width, first.cgImage?.width)
        XCTAssertNotNil(item.thumbnailData)
    }
}
