import Foundation
import CoreGraphics

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct FrameExtrapolatorTests {
    static func main() {
        print("=== Running FrameExtrapolator Direct Tests ===")
        
        // 1. DSCF3716: Real inner frame coordinates detected by Apple Vision
        // TL=(1301.6, 755.8), TR=(3762.7, 755.8), BR=(3762.7, 4083.8), BL=(1301.6, 4083.8)
        let dscf3716Inner = [
            CGPoint(x: 1301.6, y: 755.8),
            CGPoint(x: 3762.7, y: 755.8),
            CGPoint(x: 3762.7, y: 4083.8),
            CGPoint(x: 1301.6, y: 4083.8)
        ]
        let imgSize3716 = CGSize(width: 5000, height: 5000)
        let res3716 = FrameExtrapolator.checkAndExtrapolate(corners: dscf3716Inner, imageSize: imgSize3716)
        
        assert(res3716.isInnerFrame, "DSCF3716 should be identified as Inner Frame")
        assert(res3716.detectedFormat == .mini, "DSCF3716 format should be Mini")
        
        // Check that extrapolated corners are wider and taller than inner corners
        let ex3716 = res3716.extrapolatedCorners
        assert(ex3716[0].x < dscf3716Inner[0].x, "Top-left X should expand left")
        assert(ex3716[0].y < dscf3716Inner[0].y, "Top-left Y should expand up")
        assert(ex3716[2].x > dscf3716Inner[2].x, "Bottom-right X should expand right")
        assert(ex3716[2].y > dscf3716Inner[2].y, "Bottom-right Y should expand down (chin)")
        print("✅ [PASS] DSCF3716 inner frame successfully identified and extrapolated to full card!")
        print("   -> Inner:  TL=\(dscf3716Inner[0]), BR=\(dscf3716Inner[2])")
        print("   -> Outer:  TL=\(ex3716[0]), BR=\(ex3716[2])")
        
        // 2. IMG_7280: Real inner frame coordinates
        let img7280Inner = [
            CGPoint(x: 1000.0, y: 800.0),
            CGPoint(x: 2662.4, y: 800.0),
            CGPoint(x: 2662.4, y: 3127.9),
            CGPoint(x: 1000.0, y: 3127.9)
        ]
        let res7280 = FrameExtrapolator.checkAndExtrapolate(corners: img7280Inner, imageSize: CGSize(width: 4000, height: 4000))
        assert(res7280.isInnerFrame, "IMG_7280 should be identified as Inner Frame")
        print("✅ [PASS] IMG_7280 inner frame successfully identified and extrapolated!")
        
        // 3. Normal full card (ratio = 1.593) should NOT be identified as inner frame
        let normalMiniCard = [
            CGPoint(x: 500.0, y: 500.0),
            CGPoint(x: 1580.0, y: 500.0),
            CGPoint(x: 1580.0, y: 2220.0),
            CGPoint(x: 500.0, y: 2220.0)
        ]
        let resNormal = FrameExtrapolator.checkAndExtrapolate(corners: normalMiniCard, imageSize: CGSize(width: 3000, height: 3000))
        assert(!resNormal.isInnerFrame, "Normal full card should NOT be treated as inner frame")
        assert(resNormal.extrapolatedCorners == resNormal.originalCorners, "Corners should remain untouched")
        print("✅ [PASS] Normal full Polaroid card correctly preserved without modification!")
        
        print("\n🎉 ALL FRAME EXTRAPOLATOR TESTS PASSED WITH 100% SUCCESS!")
    }
}
