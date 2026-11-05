import Foundation
import CoreGraphics
import CryptoKit
import CoreML

// MARK: - Telemetry Payload & Outcome Types

nonisolated struct ChekiAlignmentTelemetryPayload: Codable, Equatable, Sendable {
    let sampleID: String
    let filename: String
    let method: String
    let points: [[Double]]
    let normalizedPoints: [[Double]]
    let width: Int
    let height: Int
    let filmFormat: String
    let cornerDisplacementPx: Double
    let redactedFaceCount: Int
    let createdAtISO8601: String
}

nonisolated enum TelemetryEnqueueOutcome: Equatable, Sendable {
    case enqueued(sampleID: String)
    case skippedSharingDisabled
    case skippedBelowDisplacementThreshold(maxDisplacement: Double)
    case rejectedInvalidGeometry(QuadValidationError)
}

nonisolated struct TelemetryFlushSummary: Equatable, Sendable {
    let uploadedCount: Int
    let failedCount: Int
    let remainingCount: Int
}

// MARK: - Transport Boundary

nonisolated protocol ChekiAlignmentTelemetryTransport: Sendable {
    func uploadSample(payload: ChekiAlignmentTelemetryPayload, jpegData: Data) async throws
}

nonisolated struct URLSessionTelemetryTransport: ChekiAlignmentTelemetryTransport {
    let endpointURL: URL?
    let session: URLSession

    init(endpointURL: URL? = nil, session: URLSession = .shared) {
        self.endpointURL = endpointURL
        self.session = session
    }

    func uploadSample(payload: ChekiAlignmentTelemetryPayload, jpegData: Data) async throws {
        guard let endpointURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct WireEnvelope: Encodable {
            let metadata: ChekiAlignmentTelemetryPayload
            let imageBase64: String
        }

        let envelope = WireEnvelope(
            metadata: payload,
            imageBase64: jpegData.base64EncodedString()
        )
        let body = try JSONEncoder().encode(envelope)
        let (_, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

// MARK: - OTA Model Manifest & Store

nonisolated struct ChekiOTAManifest: Codable, Equatable, Sendable {
    let version: String
    let sha256: String
    let downloadURL: String
    let promotedAtISO8601: String
    let goldenMeanCornerErrorPx: Double?
}

nonisolated enum ChekiOTAUpdateError: Error, Equatable, Sendable {
    case checksumMismatch(expected: String, actual: String)
    case invalidManifestVersion
}

nonisolated struct ChekiOTAModelStore: Sendable {
    let modelsDirectoryURL: URL

    static let compiledModelFolderName = "ChekiPoseNet.mlmodelc"
    static let activeVersionFileName = "active_model_version.txt"

    init(modelsDirectoryURL: URL? = nil) {
        if let modelsDirectoryURL {
            self.modelsDirectoryURL = modelsDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.modelsDirectoryURL = appSupport.appendingPathComponent("ChekiModels", isDirectory: true)
        }
    }

    func activeCompiledModelURL() -> URL? {
        let candidate = modelsDirectoryURL.appendingPathComponent(Self.compiledModelFolderName, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return candidate
    }

    func activeModelVersion() -> String? {
        let versionURL = modelsDirectoryURL.appendingPathComponent(Self.activeVersionFileName)
        guard let raw = try? String(contentsOf: versionURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyChecksum(data: Data, expectedSHA256: String) throws {
        let actual = sha256Hex(of: data).lowercased()
        let expected = expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard actual == expected else {
            throw ChekiOTAUpdateError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    /// Checks if the remote manifest offers a newer version than currently installed, verifies SHA256
    /// integrity on the downloaded payload, and atomically installs the unpacked model.
    @discardableResult
    func applyRemoteManifestIfNeeded(
        manifest: ChekiOTAManifest,
        downloadArchive: (String) async throws -> (archiveData: Data, unpackedModelURL: URL)
    ) async throws -> Bool {
        let targetVersion = manifest.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetVersion.isEmpty else {
            throw ChekiOTAUpdateError.invalidManifestVersion
        }
        if activeModelVersion() == targetVersion, activeCompiledModelURL() != nil {
            return false
        }

        let (archiveData, unpackedModelURL) = try await downloadArchive(manifest.downloadURL)
        try Self.verifyChecksum(data: archiveData, expectedSHA256: manifest.sha256)
        _ = try await installModel(from: unpackedModelURL, version: targetVersion)
        return true
    }

    /// Idempotently installs a compiled `.mlmodelc` or uncompiled `.mlpackage` / `.mlmodel` into the OTA directory.
    @discardableResult
    func installModel(from sourceURL: URL, version: String) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)

        let compiledSourceURL: URL
        if sourceURL.pathExtension == "mlpackage" || sourceURL.pathExtension == "mlmodel" {
            compiledSourceURL = try await MLModel.compileModel(at: sourceURL)
        } else {
            compiledSourceURL = sourceURL
        }

        let stagingURL = modelsDirectoryURL.appendingPathComponent("ChekiPoseNet_staging_\(UUID().uuidString).mlmodelc", isDirectory: true)
        let targetURL = modelsDirectoryURL.appendingPathComponent(Self.compiledModelFolderName, isDirectory: true)

        if fm.fileExists(atPath: stagingURL.path) {
            try? fm.removeItem(at: stagingURL)
        }
        try fm.copyItem(at: compiledSourceURL, to: stagingURL)

        if fm.fileExists(atPath: targetURL.path) {
            _ = try fm.replaceItemAt(targetURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: targetURL)
        }

        let versionURL = modelsDirectoryURL.appendingPathComponent(Self.activeVersionFileName)
        try version.data(using: .utf8)?.write(to: versionURL, options: .atomic)
        return targetURL
    }

    func removeOTAOverride() throws {
        let fm = FileManager.default
        let targetURL = modelsDirectoryURL.appendingPathComponent(Self.compiledModelFolderName, isDirectory: true)
        let versionURL = modelsDirectoryURL.appendingPathComponent(Self.activeVersionFileName)
        if fm.fileExists(atPath: targetURL.path) {
            try fm.removeItem(at: targetURL)
        }
        if fm.fileExists(atPath: versionURL.path) {
            try fm.removeItem(at: versionURL)
        }
    }
}

// MARK: - ChekiAlignmentTelemetryService

actor ChekiAlignmentTelemetryService {
    static let shared = ChekiAlignmentTelemetryService()

    private let queueDirectoryURL: URL
    private let privacyMaskService: ChekiPrivacyMaskService
    private let minimumPixelDelta: CGFloat

    init(
        queueDirectoryURL: URL? = nil,
        privacyMaskService: ChekiPrivacyMaskService = ChekiPrivacyMaskService(),
        minimumPixelDelta: CGFloat = 4.0
    ) {
        if let queueDirectoryURL {
            self.queueDirectoryURL = queueDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.queueDirectoryURL = appSupport.appendingPathComponent("ChekiTelemetryQueue", isDirectory: true)
        }
        self.privacyMaskService = privacyMaskService
        self.minimumPixelDelta = minimumPixelDelta
    }

    func enqueueIfEligible(
        sourceImage: CGImage,
        userCorners: [CGPoint],
        autoDetectedCorners: [CGPoint]?,
        filmFormat: ChekiFilmFormat = .mini,
        autoDetectionMethod: String = "manual_refined",
        isSharingEnabled: Bool,
        additionalFaceRects: [CGRect]? = nil
    ) -> TelemetryEnqueueOutcome {
        guard isSharingEnabled else {
            return .skippedSharingDisabled
        }

        let imageSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let userGeometry: QuadCornerGeometry
        switch QuadCornerGeometry.validate(corners: userCorners, in: imageSize) {
        case .failure(let error):
            return .rejectedInvalidGeometry(error)
        case .success(let valid):
            userGeometry = valid
        }

        let autoGeometry: QuadCornerGeometry?
        if let autoDetectedCorners,
           case .success(let validAuto) = QuadCornerGeometry.validate(corners: autoDetectedCorners, in: imageSize) {
            autoGeometry = validAuto
        } else {
            autoGeometry = nil
        }

        let displacement = Double(autoGeometry.map { userGeometry.maxCornerDisplacement(from: $0) } ?? 999.0)
        guard userGeometry.isMeaningfullyAdjusted(from: autoGeometry, minimumPixelDelta: minimumPixelDelta) else {
            return .skippedBelowDisplacementThreshold(maxDisplacement: displacement)
        }

        let redactedSample: PrivacyRedactedSample
        switch privacyMaskService.redactForTelemetry(
            sourceImage: sourceImage,
            corners: userGeometry.orderedCorners,
            additionalFaceRects: additionalFaceRects
        ) {
        case .failure(let error):
            return .rejectedInvalidGeometry(error)
        case .success(let sample):
            redactedSample = sample
        }

        let sampleID = Self.computeDeterministicSampleID(
            sourceSize: imageSize,
            normalizedCorners: redactedSample.normalizedCorners,
            filmFormat: filmFormat.rawValue
        )

        let payload = ChekiAlignmentTelemetryPayload(
            sampleID: sampleID,
            filename: "\(sampleID).jpg",
            method: autoDetectionMethod,
            points: redactedSample.pixelCorners,
            normalizedPoints: redactedSample.normalizedCorners,
            width: redactedSample.imageWidth,
            height: redactedSample.imageHeight,
            filmFormat: filmFormat.rawValue,
            cornerDisplacementPx: displacement,
            redactedFaceCount: redactedSample.redactedFaceCount,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date())
        )

        do {
            try persistSampleAtomically(payload: payload, jpegData: redactedSample.jpegData)
            return .enqueued(sampleID: sampleID)
        } catch {
            return .rejectedInvalidGeometry(.invalidImageDimensions(width: imageSize.width, height: imageSize.height))
        }
    }

    func pendingPayloads() -> [ChekiAlignmentTelemetryPayload] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: queueDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ChekiAlignmentTelemetryPayload.self, from: data)
            }
    }

    func flushPendingQueue(using transport: ChekiAlignmentTelemetryTransport) async -> TelemetryFlushSummary {
        let fm = FileManager.default
        let items = pendingPayloads()
        var uploaded = 0
        var failed = 0

        for payload in items {
            let jsonURL = queueDirectoryURL.appendingPathComponent("\(payload.sampleID).json")
            let jpgURL = queueDirectoryURL.appendingPathComponent(payload.filename)
            guard let jpegData = try? Data(contentsOf: jpgURL) else {
                try? fm.removeItem(at: jsonURL)
                continue
            }

            do {
                try await transport.uploadSample(payload: payload, jpegData: jpegData)
                try? fm.removeItem(at: jsonURL)
                try? fm.removeItem(at: jpgURL)
                uploaded += 1
            } catch {
                failed += 1
            }
        }

        let remaining = pendingPayloads().count
        return TelemetryFlushSummary(
            uploadedCount: uploaded,
            failedCount: failed,
            remainingCount: remaining
        )
    }

    // MARK: - Private Helpers

    private func persistSampleAtomically(payload: ChekiAlignmentTelemetryPayload, jpegData: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: queueDirectoryURL, withIntermediateDirectories: true)

        let jpgURL = queueDirectoryURL.appendingPathComponent(payload.filename)
        let jsonURL = queueDirectoryURL.appendingPathComponent("\(payload.sampleID).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(payload)

        try jpegData.write(to: jpgURL, options: .atomic)
        try jsonData.write(to: jsonURL, options: .atomic)
    }

    static func computeDeterministicSampleID(
        sourceSize: CGSize,
        normalizedCorners: [[Double]],
        filmFormat: String
    ) -> String {
        let coordsString = normalizedCorners
            .flatMap { $0 }
            .map { String(format: "%.4f", $0) }
            .joined(separator: ",")
        let canonical = "\(Int(sourceSize.width))x\(Int(sourceSize.height)):\(filmFormat):\(coordsString)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "comm_" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
