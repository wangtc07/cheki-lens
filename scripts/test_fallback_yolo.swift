import Foundation
import CoreGraphics
import ImageIO
import Vision

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct FallbackYoloTests {
    static func main() async {
        print("=== Running YOLO11-Pose Fallback Unit Tests on Edge Case (DSCF0025.JPG) ===")
        
        let path = "TestData/images/DSCF0025.JPG"
        guard let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/" + path),
              let imgSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
            print("❌ Cannot load DSCF0025.JPG")
            exit(1)
        }
        
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let vm = VisionManager()
        
        do {
            if let res = try await vm.detectFallbackPose(image: cgImage, imageSize: size) {
                let tl = res.corners[0]
                let br = res.corners[2]
                let w = br.x - tl.x
                let h = br.y - tl.y
                let ratio = h / w
                print("✅ [PASS] DSCF0025.JPG: Successfully detected via YOLO11-Pose Fallback! (Conf: \(res.confidence))")
                print("   -> Bounding Box: TL=(\(Int(tl.x)), \(Int(tl.y))), BR=(\(Int(br.x)), \(Int(br.y)))")
                print("   -> Dimensions:   \(Int(w)) x \(Int(h)) (Ratio: \(String(format: "%.3f", ratio)))")
                print("   -> Method:       \(res.method.rawValue)")
                assert(res.corners.count == 4, "Should return 4 corners")
                assert(res.confidence >= 0.20, "Confidence should meet threshold")
                print("\n🎉 YOLO11-POSE FALLBACK TEST PASSED WITH 100% SUCCESS!")
            } else {
                print("❌ [FAIL] detectFallbackPose returned nil!")
                exit(1)
            }
        } catch {
            print("❌ [ERROR] \(error)")
            exit(1)
        }
    }
}
