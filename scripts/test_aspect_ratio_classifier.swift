import Foundation
import CoreGraphics

// Test runner directly verifying AspectRatioClassifier logic
extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct StandaloneClassifierTest {
    static func main() {
        print("=== Running AspectRatioClassifier Direct Validation ===")
        
        // 1. DSCF2190: Instax Mini Landscape (W: ~4132, H: ~2596 -> W/H: ~1.592)
        let miniLandscapeCorners = [
            CGPoint(x: 100.0, y: 100.0),
            CGPoint(x: 4232.0, y: 100.0),
            CGPoint(x: 4232.0, y: 2696.0),
            CGPoint(x: 100.0, y: 2696.0)
        ]
        let spec1 = AspectRatioClassifier.classify(corners: miniLandscapeCorners)
        assert(spec1.format == .mini, "Expected Mini")
        assert(spec1.orientation == .landscape, "Expected Landscape")
        assert(spec1.standardOutputSize.width == 3840, "Expected Long Edge on Width (3840)")
        assert(spec1.standardOutputSize.height == 2411, "Expected Short Edge on Height (2411)")
        print("✅ [PASS] DSCF2190 classified as Mini Landscape (3840 x 2411)")
        
        // 2. IMG_1886: Instax Wide Landscape (W: ~3206, H: ~2554 -> W/H: ~1.256)
        let wideLandscapeCorners = [
            CGPoint(x: 100.0, y: 100.0),
            CGPoint(x: 3306.0, y: 100.0),
            CGPoint(x: 3306.0, y: 2654.0),
            CGPoint(x: 100.0, y: 2654.0)
        ]
        let spec2 = AspectRatioClassifier.classify(corners: wideLandscapeCorners)
        assert(spec2.format == .wide, "Expected Wide")
        assert(spec2.orientation == .landscape, "Expected Landscape")
        assert(spec2.standardOutputSize.width == 3840, "Expected Long Edge on Width (3840)")
        assert(spec2.standardOutputSize.height == 3058, "Expected Height 3058 (108:86)")
        print("✅ [PASS] IMG_1886 classified as Wide Landscape (3840 x 3058)")
        
        // 3. Standard Mini Portrait (H: ~1720, W: ~1080 -> H/W: ~1.593)
        let miniPortraitCorners = [
            CGPoint(x: 100.0, y: 100.0),
            CGPoint(x: 1180.0, y: 100.0),
            CGPoint(x: 1180.0, y: 1820.0),
            CGPoint(x: 100.0, y: 1820.0)
        ]
        let spec3 = AspectRatioClassifier.classify(corners: miniPortraitCorners)
        assert(spec3.format == .mini, "Expected Mini")
        assert(spec3.orientation == .portrait, "Expected Portrait")
        assert(spec3.standardOutputSize.width == 2411, "Expected Width 2411")
        assert(spec3.standardOutputSize.height == 3840, "Expected Height 3840")
        print("✅ [PASS] Standard Mini classified as Mini Portrait (2411 x 3840)")
        
        // 4. Instax Square Portrait (H: ~1720, W: ~1440 -> H/W: ~1.194)
        let squarePortraitCorners = [
            CGPoint(x: 100.0, y: 100.0),
            CGPoint(x: 1540.0, y: 100.0),
            CGPoint(x: 1540.0, y: 1820.0),
            CGPoint(x: 100.0, y: 1820.0)
        ]
        let spec4 = AspectRatioClassifier.classify(corners: squarePortraitCorners)
        assert(spec4.format == .square, "Expected Square")
        assert(spec4.orientation == .portrait, "Expected Portrait")
        assert(spec4.standardOutputSize.width == 3215, "Expected Width 3215")
        assert(spec4.standardOutputSize.height == 3840, "Expected Height 3840")
        print("✅ [PASS] Square classified as Square Portrait (3215 x 3840)")
        
        print("\n🎉 ALL 4 CLASSIFICATION ASSERTIONS PASSED WITH 100% ACCURACY!")
    }
}
