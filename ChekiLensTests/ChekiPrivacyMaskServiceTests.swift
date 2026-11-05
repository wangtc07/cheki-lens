import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ChekiLens

final class ChekiPrivacyMaskServiceTests: XCTestCase {

    func testValidateOrdersUnorderedCornersAndComputesNormalizedPoints() throws {
        let imageSize = CGSize(width: 800, height: 600)
        let unordered = [
            CGPoint(x: 600, y: 500),
            CGPoint(x: 200, y: 100),
            CGPoint(x: 200, y: 500),
            CGPoint(x: 600, y: 100)
        ]

        let result = QuadCornerGeometry.validate(corners: unordered, in: imageSize)
        let geometry = try result.get()

        XCTAssertEqual(geometry.topLeft, CGPoint(x: 200, y: 100))
        XCTAssertEqual(geometry.topRight, CGPoint(x: 600, y: 100))
        XCTAssertEqual(geometry.bottomRight, CGPoint(x: 600, y: 500))
        XCTAssertEqual(geometry.bottomLeft, CGPoint(x: 200, y: 500))

        let normalized = geometry.normalizedPoints(in: imageSize)
        XCTAssertEqual(normalized[0][0], 0.25, accuracy: 1e-5)
        XCTAssertEqual(normalized[0][1], 100.0 / 600.0, accuracy: 1e-5)
        XCTAssertEqual(normalized[2][0], 0.75, accuracy: 1e-5)
        XCTAssertEqual(normalized[2][1], 500.0 / 600.0, accuracy: 1e-5)
    }

    func testValidateRejectsInvalidAndDegenerateQuads() {
        let imageSize = CGSize(width: 800, height: 600)

        let threePoints = QuadCornerGeometry.validate(
            corners: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 100)],
            in: imageSize
        )
        XCTAssertEqual(threePoints, .failure(.invalidCornerCount(3)))

        let outOfBounds = QuadCornerGeometry.validate(
            corners: [
                CGPoint(x: -200, y: 100),
                CGPoint(x: 500, y: 100),
                CGPoint(x: 500, y: 400),
                CGPoint(x: 100, y: 400)
            ],
            in: imageSize
        )
        XCTAssertEqual(outOfBounds, .failure(.cornerOutOfBounds))

        let tinyQuad = QuadCornerGeometry.validate(
            corners: [
                CGPoint(x: 100, y: 100),
                CGPoint(x: 110, y: 100),
                CGPoint(x: 110, y: 115),
                CGPoint(x: 100, y: 115)
            ],
            in: imageSize
        )
        if case .failure(.degenerateArea) = tinyQuad {
        } else {
            XCTFail("Expected degenerateArea failure, got \(tinyQuad)")
        }

        let extremeAspect = QuadCornerGeometry.validate(
            corners: [
                CGPoint(x: 50, y: 100),
                CGPoint(x: 750, y: 100),
                CGPoint(x: 750, y: 180),
                CGPoint(x: 50, y: 180)
            ],
            in: imageSize
        )
        if case .failure(.aspectRatioOutOfRange) = extremeAspect {
        } else {
            XCTFail("Expected aspectRatioOutOfRange failure, got \(extremeAspect)")
        }
    }

    func testMeaningfulAdjustmentThreshold() throws {
        let imageSize = CGSize(width: 1000, height: 1000)
        let base = try QuadCornerGeometry.validate(
            corners: [
                CGPoint(x: 200, y: 150),
                CGPoint(x: 700, y: 150),
                CGPoint(x: 700, y: 850),
                CGPoint(x: 200, y: 850)
            ],
            in: imageSize
        ).get()

        let jittered = try QuadCornerGeometry.validate(
            corners: [
                CGPoint(x: 201.5, y: 151.0),
                CGPoint(x: 700, y: 150),
                CGPoint(x: 700, y: 850),
                CGPoint(x: 200, y: 850)
            ],
            in: imageSize
        ).get()

        let userCorrected = try QuadCornerGeometry.validate(
            corners: [
                CGPoint(x: 212.0, y: 150.0),
                CGPoint(x: 700, y: 150),
                CGPoint(x: 700, y: 850),
                CGPoint(x: 200, y: 850)
            ],
            in: imageSize
        ).get()

        XCTAssertFalse(jittered.isMeaningfullyAdjusted(from: base, minimumPixelDelta: 4.0))
        XCTAssertTrue(userCorrected.isMeaningfullyAdjusted(from: base, minimumPixelDelta: 4.0))
        XCTAssertTrue(jittered.isMeaningfullyAdjusted(from: nil, minimumPixelDelta: 4.0))
    }

    func testRedactForTelemetryMasksSubjectPreservesBorderDownscalesAndStripsExif() throws {
        let sourceWidth = 1600
        let sourceHeight = 1200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(
            CGContext(
                data: nil,
                width: sourceWidth,
                height: sourceHeight,
                bitsPerComponent: 8,
                bytesPerRow: sourceWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )

        // Fill desk background dark blue
        ctx.setFillColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))

        // Draw white Cheki frame at x: 400...1200, y(top-left): 120...1080 -> CoreGraphics y: 120...1080
        ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1.0)
        ctx.fill(CGRect(x: 400, y: 120, width: 800, height: 960))

        // Draw bright red portrait subject in the center of the Cheki frame
        ctx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 560, y: 300, width: 480, height: 600))

        let sourceCGImage = try XCTUnwrap(ctx.makeImage())
        let corners = [
            CGPoint(x: 400, y: 120),
            CGPoint(x: 1200, y: 120),
            CGPoint(x: 1200, y: 1080),
            CGPoint(x: 400, y: 1080)
        ]

        let service = ChekiPrivacyMaskService(
            targetMaxLongEdge: 640,
            borderPreserveInsetRatio: 0.12,
            jpegCompressionQuality: 0.85
        )
        let extraFaceRect = CGRect(x: 40, y: 40, width: 60, height: 60)
        let sample = try service.redactForTelemetry(
            sourceImage: sourceCGImage,
            corners: corners,
            additionalFaceRects: [extraFaceRect]
        ).get()

        XCTAssertEqual(sample.imageWidth, 640)
        XCTAssertEqual(sample.imageHeight, 480)
        XCTAssertEqual(sample.redactedFaceCount, 1)

        // Verify center portrait pixel (320, 240) is masked to neutral gray and no longer bright red
        let centerRGB = try pixelRGB(in: sample.redactedImage, x: 320, y: 240)
        XCTAssertLessThan(centerRGB.r, 160, "Interior red portrait must be masked out")
        XCTAssertGreaterThan(centerRGB.g, 100, "Interior should be filled with neutral gray mask")
        XCTAssertEqual(Double(centerRGB.r), Double(centerRGB.g), accuracy: 15.0)

        // Verify outer Cheki border strip pixel near top-left corner (170, 56) remains bright white
        let borderRGB = try pixelRGB(in: sample.redactedImage, x: 170, y: 56)
        XCTAssertGreaterThan(borderRGB.r, 220, "Outer border strip must remain preserved for corner learning")
        XCTAssertGreaterThan(borderRGB.g, 220)
        XCTAssertGreaterThan(borderRGB.b, 220)

        // Verify JPEG bytes contain no GPS/TIFF or sensitive EXIF tags (DateTimeOriginal, LensMake, UserComment)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(sample.jpegData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            XCTAssertNil(exifDict[kCGImagePropertyExifDateTimeOriginal])
            XCTAssertNil(exifDict[kCGImagePropertyExifDateTimeDigitized])
            XCTAssertNil(exifDict[kCGImagePropertyExifLensModel])
            XCTAssertNil(exifDict[kCGImagePropertyExifUserComment])
        }
    }

    private func pixelRGB(in image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = image.width
        let height = image.height
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(
            CGContext(
                data: &rawData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = (y * width + x) * 4
        return (rawData[offset], rawData[offset + 1], rawData[offset + 2])
    }
}
