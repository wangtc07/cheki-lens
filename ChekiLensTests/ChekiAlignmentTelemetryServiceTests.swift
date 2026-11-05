import XCTest
import CoreGraphics
@testable import ChekiLens

private actor MockTelemetryTransport: ChekiAlignmentTelemetryTransport {
    var shouldFail: Bool = false
    private(set) var receivedPayloads: [ChekiAlignmentTelemetryPayload] = []
    private(set) var receivedJPEGByteCounts: [Int] = []

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func uploadSample(payload: ChekiAlignmentTelemetryPayload, jpegData: Data) async throws {
        if shouldFail {
            throw URLError(.networkConnectionLost)
        }
        receivedPayloads.append(payload)
        receivedJPEGByteCounts.append(jpegData.count)
    }
}

final class ChekiAlignmentTelemetryServiceTests: XCTestCase {

    private var tempDirURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChekiTelemetryTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirURL, FileManager.default.fileExists(atPath: tempDirURL.path) {
            try? FileManager.default.removeItem(at: tempDirURL)
        }
        try super.tearDownWithError()
    }

    func testSkipsEnqueueWhenSharingDisabledOrBelowDisplacementThreshold() async throws {
        let service = ChekiAlignmentTelemetryService(queueDirectoryURL: tempDirURL)
        let image = try makeSyntheticImage(width: 800, height: 600)
        let autoCorners = [
            CGPoint(x: 200, y: 80),
            CGPoint(x: 600, y: 80),
            CGPoint(x: 600, y: 520),
            CGPoint(x: 200, y: 520)
        ]
        let slightCorners = [
            CGPoint(x: 201.5, y: 81.0),
            CGPoint(x: 600, y: 80),
            CGPoint(x: 600, y: 520),
            CGPoint(x: 200, y: 520)
        ]

        let disabledOutcome = await service.enqueueIfEligible(
            sourceImage: image,
            userCorners: [
                CGPoint(x: 225, y: 80),
                CGPoint(x: 600, y: 80),
                CGPoint(x: 600, y: 520),
                CGPoint(x: 200, y: 520)
            ],
            autoDetectedCorners: autoCorners,
            isSharingEnabled: false
        )
        XCTAssertEqual(disabledOutcome, .skippedSharingDisabled)
        let pendingAfterDisabled = await service.pendingPayloads()
        XCTAssertTrue(pendingAfterDisabled.isEmpty)

        let thresholdOutcome = await service.enqueueIfEligible(
            sourceImage: image,
            userCorners: slightCorners,
            autoDetectedCorners: autoCorners,
            isSharingEnabled: true
        )
        if case .skippedBelowDisplacementThreshold = thresholdOutcome {
        } else {
            XCTFail("Expected skippedBelowDisplacementThreshold, got \(thresholdOutcome)")
        }
        let pendingAfterThreshold = await service.pendingPayloads()
        XCTAssertTrue(pendingAfterThreshold.isEmpty)
    }

    func testIdempotentEnqueueAndFlushRetryLifecycle() async throws {
        let service = ChekiAlignmentTelemetryService(queueDirectoryURL: tempDirURL)
        let image = try makeSyntheticImage(width: 1200, height: 900)
        let autoCorners = [
            CGPoint(x: 300, y: 100),
            CGPoint(x: 900, y: 100),
            CGPoint(x: 900, y: 800),
            CGPoint(x: 300, y: 800)
        ]
        let adjustedCorners = [
            CGPoint(x: 318, y: 108),
            CGPoint(x: 892, y: 104),
            CGPoint(x: 895, y: 792),
            CGPoint(x: 305, y: 796)
        ]

        let firstOutcome = await service.enqueueIfEligible(
            sourceImage: image,
            userCorners: adjustedCorners,
            autoDetectedCorners: autoCorners,
            filmFormat: .mini,
            isSharingEnabled: true,
            additionalFaceRects: []
        )
        let secondOutcome = await service.enqueueIfEligible(
            sourceImage: image,
            userCorners: adjustedCorners,
            autoDetectedCorners: autoCorners,
            filmFormat: .mini,
            isSharingEnabled: true,
            additionalFaceRects: []
        )
        XCTAssertEqual(firstOutcome, secondOutcome)

        let pendingBeforeFlush = await service.pendingPayloads()
        XCTAssertEqual(pendingBeforeFlush.count, 1, "Duplicate adjustment saves must converge to a single queued sample")
        XCTAssertEqual(pendingBeforeFlush.first?.width, 640)
        XCTAssertEqual(pendingBeforeFlush.first?.height, 480)
        XCTAssertEqual(pendingBeforeFlush.first?.points.count, 4)

        let transport = MockTelemetryTransport()
        await transport.setShouldFail(true)

        let failedFlush = await service.flushPendingQueue(using: transport)
        XCTAssertEqual(failedFlush, TelemetryFlushSummary(uploadedCount: 0, failedCount: 1, remainingCount: 1))

        await transport.setShouldFail(false)
        let succeededFlush = await service.flushPendingQueue(using: transport)
        XCTAssertEqual(succeededFlush, TelemetryFlushSummary(uploadedCount: 1, failedCount: 0, remainingCount: 0))

        let received = await transport.receivedPayloads
        let byteCounts = await transport.receivedJPEGByteCounts
        XCTAssertEqual(received.count, 1)
        XCTAssertGreaterThan(byteCounts.first ?? 0, 500)
        let pendingAfterSuccess = await service.pendingPayloads()
        XCTAssertTrue(pendingAfterSuccess.isEmpty)
    }

    func testOTAModelStorePrioritizesInstalledModelAndFallsBackWhenRemoved() async throws {
        let otaDir = tempDirURL.appendingPathComponent("Models", isDirectory: true)
        let store = ChekiOTAModelStore(modelsDirectoryURL: otaDir)

        XCTAssertNil(store.activeCompiledModelURL())
        XCTAssertNil(store.activeModelVersion())

        let dummySourceModel = tempDirURL.appendingPathComponent("DummySource.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: dummySourceModel, withIntermediateDirectories: true)
        try Data("weights-v1".utf8).write(to: dummySourceModel.appendingPathComponent("model.mil"))

        let installedURL = try await store.installModel(from: dummySourceModel, version: "2026.11.05-v1")
        XCTAssertEqual(store.activeCompiledModelURL()?.standardizedFileURL, installedURL.standardizedFileURL)
        XCTAssertEqual(store.activeModelVersion(), "2026.11.05-v1")
        XCTAssertEqual(
            VisionManager.resolvePoseModelURL(otaStore: store)?.standardizedFileURL,
            installedURL.standardizedFileURL
        )

        // Idempotent second install updates version cleanly
        try Data("weights-v2".utf8).write(to: dummySourceModel.appendingPathComponent("model.mil"))
        let updatedURL = try await store.installModel(from: dummySourceModel, version: "2026.11.05-v2")
        XCTAssertEqual(updatedURL.standardizedFileURL, installedURL.standardizedFileURL)
        XCTAssertEqual(store.activeModelVersion(), "2026.11.05-v2")

        try store.removeOTAOverride()
        XCTAssertNil(store.activeCompiledModelURL())
        XCTAssertNil(store.activeModelVersion())
    }

    func testApplyRemoteManifestVerifiesSHA256AndSkipsSameVersion() async throws {
        let otaDir = tempDirURL.appendingPathComponent("RemoteOTA", isDirectory: true)
        let store = ChekiOTAModelStore(modelsDirectoryURL: otaDir)

        let unpackedSource = tempDirURL.appendingPathComponent("UnpackedRemote.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: unpackedSource, withIntermediateDirectories: true)
        let archiveBytes = Data("remote-compiled-model-archive-v1".utf8)
        try archiveBytes.write(to: unpackedSource.appendingPathComponent("model.mil"))

        let validHash = ChekiOTAModelStore.sha256Hex(of: archiveBytes)
        let manifestV1 = ChekiOTAManifest(
            version: "2026.11.05.1",
            sha256: validHash,
            downloadURL: "https://example.com/ChekiPoseNet.mlmodelc.zip",
            promotedAtISO8601: "2026-11-05T03:30:00Z",
            goldenMeanCornerErrorPx: 3.10
        )

        var downloadCallCount = 0
        let appliedFirst = try await store.applyRemoteManifestIfNeeded(manifest: manifestV1) { _ in
            downloadCallCount += 1
            return (archiveBytes, unpackedSource)
        }
        XCTAssertTrue(appliedFirst)
        XCTAssertEqual(downloadCallCount, 1)
        XCTAssertEqual(store.activeModelVersion(), "2026.11.05.1")

        // Second check with same version must be an idempotent no-op without downloading
        let appliedSecond = try await store.applyRemoteManifestIfNeeded(manifest: manifestV1) { _ in
            downloadCallCount += 1
            return (archiveBytes, unpackedSource)
        }
        XCTAssertFalse(appliedSecond)
        XCTAssertEqual(downloadCallCount, 1)

        // Corrupted download with wrong SHA256 must be rejected and preserve v1
        let badManifest = ChekiOTAManifest(
            version: "2026.11.05.2",
            sha256: String(repeating: "0", count: 64),
            downloadURL: "https://example.com/ChekiPoseNet.mlmodelc.zip",
            promotedAtISO8601: "2026-11-05T04:00:00Z",
            goldenMeanCornerErrorPx: 2.95
        )
        do {
            _ = try await store.applyRemoteManifestIfNeeded(manifest: badManifest) { _ in
                (archiveBytes, unpackedSource)
            }
            XCTFail("Expected checksumMismatch error")
        } catch let error as ChekiOTAUpdateError {
            if case .checksumMismatch = error {
            } else {
                XCTFail("Expected checksumMismatch, got \(error)")
            }
        }
        XCTAssertEqual(store.activeModelVersion(), "2026.11.05.1")
    }

    private func makeSyntheticImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        ctx.setFillColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }
}
