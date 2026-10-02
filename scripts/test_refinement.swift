import Foundation
import CoreGraphics

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct RefinementTests {
    static func main() {
        print("=== Running VisionManager+Refinement Direct Tests ===")
        
        // 1. 287136_DSCF1465: Real corner coordinates from Apple Vision with distorted TR (15.4° skew)
        let dscf1465Skewed = [
            CGPoint(x: 326.6, y: 159.4),   // TL
            CGPoint(x: 1060.0, y: 350.0),  // TR (drifted by ~69px down/right)
            CGPoint(x: 1120.4, y: 1398.2), // BR
            CGPoint(x: 329.8, y: 1395.0)   // BL
        ]
        let imgSize = CGSize(width: 1500, height: 1500)
        let resSkewed = VisionManager.refineQuadrilateral(corners: dscf1465Skewed, imageSize: imgSize)
        
        assert(resSkewed.wasRefined, "DSCF1465 skewed corners should be refined")
        assert(resSkewed.anomalousCornerIndex == 1, "Anomalous corner should be TR (index 1)")
        assert(resSkewed.horizontalSkewAngle >= 4.0, "Horizontal skew should be detected as >= 4.0°")
        
        let refinedTR = resSkewed.corners[1]
        print("✅ [PASS] 287136 distorted TR successfully detected and refined!")
        print("   -> Detected Horizontal Skew: \(String(format: "%.1f°", resSkewed.horizontalSkewAngle))")
        print("   -> Raw TR:     \(dscf1465Skewed[1])")
        print("   -> Refined TR: \(refinedTR)")
        
        // 2. Normal clean rectangle
        let cleanCard = [
            CGPoint(x: 200.0, y: 200.0),
            CGPoint(x: 800.0, y: 200.0),
            CGPoint(x: 800.0, y: 1160.0),
            CGPoint(x: 200.0, y: 1160.0)
        ]
        let resClean = VisionManager.refineQuadrilateral(corners: cleanCard, imageSize: imgSize)
        assert(!resClean.wasRefined, "Clean card should not be modified")
        assert(resClean.horizontalSkewAngle < 1.0, "Skew angle should be close to 0")
        print("✅ [PASS] Clean card correctly preserved without modification (skew: \(String(format: "%.2f°", resClean.horizontalSkewAngle)))")
        
        print("\n🎉 ALL CORNER REFINEMENT TESTS PASSED WITH 100% SUCCESS!")
    }
}
