import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Domain Types

nonisolated enum QuadValidationError: Error, Equatable, Sendable {
    case invalidCornerCount(Int)
    case invalidImageDimensions(width: Double, height: Double)
    case cornerOutOfBounds
    case nonConvexOrSelfIntersecting
    case degenerateArea(ratio: Double)
    case aspectRatioOutOfRange(ratio: Double)
}

/// Validated four-corner geometry in [topLeft, topRight, bottomRight, bottomLeft] order.
nonisolated struct QuadCornerGeometry: Equatable, Sendable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    var orderedCorners: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    static let minimumAreaRatio: Double = 0.02
    static let minimumAspectRatio: Double = 0.85
    static let maximumAspectRatio: Double = 2.60

    static func validate(
        corners: [CGPoint],
        in imageSize: CGSize,
        minAreaRatio: Double = Self.minimumAreaRatio
    ) -> Result<QuadCornerGeometry, QuadValidationError> {
        guard corners.count == 4 else {
            return .failure(.invalidCornerCount(corners.count))
        }
        guard imageSize.width > 1, imageSize.height > 1 else {
            return .failure(.invalidImageDimensions(width: imageSize.width, height: imageSize.height))
        }

        let ordered = orderClockwiseFromTopLeft(corners)
        let toleranceX = imageSize.width * 0.05
        let toleranceY = imageSize.height * 0.05
        let validBounds = CGRect(
            x: -toleranceX,
            y: -toleranceY,
            width: imageSize.width + toleranceX * 2,
            height: imageSize.height + toleranceY * 2
        )

        for pt in ordered {
            guard pt.x.isFinite, pt.y.isFinite, validBounds.contains(pt) else {
                return .failure(.cornerOutOfBounds)
            }
        }

        guard isStrictlyConvex(ordered) else {
            return .failure(.nonConvexOrSelfIntersecting)
        }

        let quadArea = polygonArea(ordered)
        let totalArea = Double(imageSize.width * imageSize.height)
        let areaRatio = quadArea / max(1.0, totalArea)
        guard areaRatio >= minAreaRatio else {
            return .failure(.degenerateArea(ratio: areaRatio))
        }

        let topEdge = hypot(ordered[1].x - ordered[0].x, ordered[1].y - ordered[0].y)
        let bottomEdge = hypot(ordered[2].x - ordered[3].x, ordered[2].y - ordered[3].y)
        let leftEdge = hypot(ordered[3].x - ordered[0].x, ordered[3].y - ordered[0].y)
        let rightEdge = hypot(ordered[2].x - ordered[1].x, ordered[2].y - ordered[1].y)

        let avgWidth = Double(topEdge + bottomEdge) * 0.5
        let avgHeight = Double(leftEdge + rightEdge) * 0.5
        let shortSide = max(1e-6, min(avgWidth, avgHeight))
        let longSide = max(avgWidth, avgHeight)
        let aspect = longSide / shortSide

        guard aspect >= minimumAspectRatio, aspect <= maximumAspectRatio else {
            return .failure(.aspectRatioOutOfRange(ratio: aspect))
        }

        return .success(
            QuadCornerGeometry(
                topLeft: ordered[0],
                topRight: ordered[1],
                bottomRight: ordered[2],
                bottomLeft: ordered[3]
            )
        )
    }

    func scaled(from sourceSize: CGSize, to targetSize: CGSize) -> QuadCornerGeometry {
        let sx = targetSize.width / max(1.0, sourceSize.width)
        let sy = targetSize.height / max(1.0, sourceSize.height)
        let scalePoint: (CGPoint) -> CGPoint = { pt in
            CGPoint(
                x: min(max(0.0, pt.x * sx), targetSize.width),
                y: min(max(0.0, pt.y * sy), targetSize.height)
            )
        }
        return QuadCornerGeometry(
            topLeft: scalePoint(topLeft),
            topRight: scalePoint(topRight),
            bottomRight: scalePoint(bottomRight),
            bottomLeft: scalePoint(bottomLeft)
        )
    }

    func pixelPoints() -> [[Double]] {
        orderedCorners.map { [Double($0.x), Double($0.y)] }
    }

    func normalizedPoints(in imageSize: CGSize) -> [[Double]] {
        let w = max(1.0, Double(imageSize.width))
        let h = max(1.0, Double(imageSize.height))
        return orderedCorners.map { pt in
            [
                min(max(0.0, Double(pt.x) / w), 1.0),
                min(max(0.0, Double(pt.y) / h), 1.0)
            ]
        }
    }

    /// Computes the interior polygon using bilinear interpolation so the outer border strip remains intact
    /// while the central portrait and signature region is masked out.
    func insetPolygon(insetRatio: CGFloat = 0.12) -> [CGPoint] {
        let clamped = min(max(insetRatio, 0.02), 0.45)
        let u0 = clamped
        let u1 = 1.0 - clamped
        let v0 = clamped
        let v1 = 1.0 - clamped

        return [
            bilinearPoint(u: u0, v: v0),
            bilinearPoint(u: u1, v: v0),
            bilinearPoint(u: u1, v: v1),
            bilinearPoint(u: u0, v: v1)
        ]
    }

    func maxCornerDisplacement(from other: QuadCornerGeometry) -> CGFloat {
        zip(orderedCorners, other.orderedCorners).reduce(0.0) { currentMax, pair in
            max(currentMax, hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y))
        }
    }

    func isMeaningfullyAdjusted(
        from autoDetected: QuadCornerGeometry?,
        minimumPixelDelta: CGFloat = 4.0
    ) -> Bool {
        guard let autoDetected else { return true }
        return maxCornerDisplacement(from: autoDetected) >= minimumPixelDelta
    }

    // MARK: - Private Geometry Helpers

    private func bilinearPoint(u: CGFloat, v: CGFloat) -> CGPoint {
        let topX = topLeft.x + (topRight.x - topLeft.x) * u
        let topY = topLeft.y + (topRight.y - topLeft.y) * u
        let bottomX = bottomLeft.x + (bottomRight.x - bottomLeft.x) * u
        let bottomY = bottomLeft.y + (bottomRight.y - bottomLeft.y) * u
        return CGPoint(
            x: topX + (bottomX - topX) * v,
            y: topY + (bottomY - topY) * v
        )
    }

    private static func orderClockwiseFromTopLeft(_ pts: [CGPoint]) -> [CGPoint] {
        let cx = pts.reduce(0.0) { $0 + $1.x } / CGFloat(pts.count)
        let cy = pts.reduce(0.0) { $0 + $1.y } / CGFloat(pts.count)

        let sortedByAngle = pts.sorted { a, b in
            atan2(a.y - cy, a.x - cx) < atan2(b.y - cy, b.x - cx)
        }

        guard let tlIndex = sortedByAngle.enumerated().min(by: {
            ($0.element.x + $0.element.y) < ($1.element.x + $1.element.y)
        })?.offset else {
            return pts
        }

        var ordered: [CGPoint] = []
        for i in 0..<4 {
            ordered.append(sortedByAngle[(tlIndex + i) % 4])
        }

        let cross = crossProduct(ordered[0], ordered[1], ordered[2])
        if cross < 0 {
            ordered.swapAt(1, 3)
        }
        return ordered
    }

    private static func isStrictlyConvex(_ pts: [CGPoint]) -> Bool {
        guard pts.count == 4 else { return false }
        var signs: [Bool] = []
        for i in 0..<4 {
            let a = pts[i]
            let b = pts[(i + 1) % 4]
            let c = pts[(i + 2) % 4]
            let cp = crossProduct(a, b, c)
            if abs(cp) < 1.0 {
                return false
            }
            signs.append(cp > 0)
        }
        return signs.allSatisfy({ $0 == signs[0] })
    }

    private static func crossProduct(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
    }

    private static func polygonArea(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<pts.count {
            let j = (i + 1) % pts.count
            sum += (pts[i].x * pts[j].y) - (pts[j].x * pts[i].y)
        }
        return Double(abs(sum)) * 0.5
    }
}

// MARK: - Redacted Output Payload

nonisolated struct PrivacyRedactedSample: Sendable {
    let redactedImage: CGImage
    let jpegData: Data
    let imageWidth: Int
    let imageHeight: Int
    let scaledGeometry: QuadCornerGeometry
    let pixelCorners: [[Double]]
    let normalizedCorners: [[Double]]
    let redactedFaceCount: Int
}

// MARK: - ChekiPrivacyMaskService

nonisolated struct ChekiPrivacyMaskService: Sendable {
    var targetMaxLongEdge: Int = 640
    var borderPreserveInsetRatio: CGFloat = 0.12
    var jpegCompressionQuality: CGFloat = 0.82

    init(
        targetMaxLongEdge: Int = 640,
        borderPreserveInsetRatio: CGFloat = 0.12,
        jpegCompressionQuality: CGFloat = 0.82
    ) {
        self.targetMaxLongEdge = max(128, targetMaxLongEdge)
        self.borderPreserveInsetRatio = min(max(borderPreserveInsetRatio, 0.05), 0.40)
        self.jpegCompressionQuality = min(max(jpegCompressionQuality, 0.40), 0.95)
    }

    /// Validates user-adjusted corners, downscales the image to training size, masks out the interior
    /// portrait region and any detected faces, and produces EXIF-stripped JPEG bytes.
    func redactForTelemetry(
        sourceImage: CGImage,
        corners: [CGPoint],
        additionalFaceRects: [CGRect]? = nil
    ) -> Result<PrivacyRedactedSample, QuadValidationError> {
        let sourceSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        switch QuadCornerGeometry.validate(corners: corners, in: sourceSize) {
        case .failure(let error):
            return .failure(error)
        case .success(let validGeometry):
            let targetSize = Self.computeDownscaledSize(from: sourceSize, maxLongEdge: targetMaxLongEdge)
            let scaledGeometry = validGeometry.scaled(from: sourceSize, to: targetSize)

            guard let downscaled = Self.renderDownscaledImage(sourceImage, targetSize: targetSize) else {
                return .failure(.invalidImageDimensions(width: targetSize.width, height: targetSize.height))
            }

            let detectedFaceRects = additionalFaceRects ?? Self.detectFaceBoundingBoxes(in: downscaled, imageSize: targetSize)
            guard let redactedCGImage = Self.applyPrivacyMask(
                to: downscaled,
                geometry: scaledGeometry,
                insetRatio: borderPreserveInsetRatio,
                faceRects: detectedFaceRects
            ),
            let cleanJPEG = Self.encodeExifStrippedJPEG(from: redactedCGImage, quality: jpegCompressionQuality) else {
                return .failure(.invalidImageDimensions(width: targetSize.width, height: targetSize.height))
            }

            let sample = PrivacyRedactedSample(
                redactedImage: redactedCGImage,
                jpegData: cleanJPEG,
                imageWidth: redactedCGImage.width,
                imageHeight: redactedCGImage.height,
                scaledGeometry: scaledGeometry,
                pixelCorners: scaledGeometry.pixelPoints(),
                normalizedCorners: scaledGeometry.normalizedPoints(in: targetSize),
                redactedFaceCount: detectedFaceRects.count
            )
            return .success(sample)
        }
    }

    // MARK: - Internal Rendering & Stripping

    static func computeDownscaledSize(from sourceSize: CGSize, maxLongEdge: Int) -> CGSize {
        let maxEdge = CGFloat(max(64, maxLongEdge))
        let currentLongEdge = max(sourceSize.width, sourceSize.height)
        guard currentLongEdge > maxEdge else {
            return CGSize(width: max(1, round(sourceSize.width)), height: max(1, round(sourceSize.height)))
        }
        let scale = maxEdge / currentLongEdge
        return CGSize(
            width: max(1, round(sourceSize.width * scale)),
            height: max(1, round(sourceSize.height * scale))
        )
    }

    static func renderDownscaledImage(_ image: CGImage, targetSize: CGSize) -> CGImage? {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func detectFaceBoundingBoxes(in image: CGImage, imageSize: CGSize) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let results = request.results else { return [] }
            return results.map { observation in
                let box = observation.boundingBox
                return CGRect(
                    x: box.origin.x * imageSize.width,
                    y: (1.0 - box.origin.y - box.height) * imageSize.height,
                    width: box.width * imageSize.width,
                    height: box.height * imageSize.height
                ).insetBy(dx: -4, dy: -4)
            }
        } catch {
            return []
        }
    }

    static func applyPrivacyMask(
        to image: CGImage,
        geometry: QuadCornerGeometry,
        insetRatio: CGFloat,
        faceRects: [CGRect]
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CoreGraphics has origin at bottom-left, whereas image pixel coordinates have origin at top-left.
        let flipPoint: (CGPoint) -> CGPoint = { pt in
            CGPoint(x: pt.x, y: CGFloat(height) - pt.y)
        }

        let innerPts = geometry.insetPolygon(insetRatio: insetRatio).map(flipPoint)
        if innerPts.count == 4 {
            ctx.saveGState()
            ctx.beginPath()
            ctx.move(to: innerPts[0])
            for i in 1..<4 {
                ctx.addLine(to: innerPts[i])
            }
            ctx.closePath()
            ctx.setFillColor(red: 0.48, green: 0.49, blue: 0.52, alpha: 1.0)
            ctx.fillPath()
            ctx.restoreGState()
        }

        if !faceRects.isEmpty {
            ctx.saveGState()
            ctx.setFillColor(red: 0.35, green: 0.36, blue: 0.38, alpha: 1.0)
            for rect in faceRects {
                let flippedRect = CGRect(
                    x: rect.origin.x,
                    y: CGFloat(height) - rect.origin.y - rect.height,
                    width: rect.width,
                    height: rect.height
                )
                ctx.fill(flippedRect)
            }
            ctx.restoreGState()
        }

        return ctx.makeImage()
    }

    static func encodeExifStrippedJPEG(from image: CGImage, quality: CGFloat) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }
}
