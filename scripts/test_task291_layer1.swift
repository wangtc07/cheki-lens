import Foundation
import CoreGraphics
import CoreImage
import Vision

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct Task291Tester {
    static func main() async {
        print("===============================================================")
        print("🧪 Testing Task 2.9.1: Two-Pass Native Vision & Anti-Regression")
        print("===============================================================\n")

        let vm = VisionManager()
        
        let testCases: [(name: String, minExpectedAreaPct: Double, expectedFormat: String)] = [
            ("IMG_7882.jpeg", 40.0, "Mini Portrait (IMG_7882 - Previously Failed!)"),
            ("IMG_3491.jpeg", 50.0, "Mini Portrait (IMG_3491 - Full Card instead of 29% cut)"),
            ("287136_DSCF1465.JPG", 25.0, "Mini Portrait"),
            ("DSCF0008.JPG", 80.0, "Mini Landscape")
        ]
        
        var passed = 0
        
        for tc in testCases {
            var path = "TestData/images/\(tc.name)"
            if !FileManager.default.fileExists(atPath: path) {
                path = "datasets/cheki_pose/images/val/\(tc.name)"
            }
            guard let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/" + path),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                print("❌ Cannot load \(tc.name)")
                exit(1)
            }
            
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            let totalArea = Double(size.width * size.height)
            
            do {
                let det = try await vm.detectVisionNative(image: cgImage, imageSize: size)
                let area = VisionManager.quadArea(det.corners)
                let areaPct = (area / totalArea) * 100.0
                let ratio = VisionManager.quadAspectRatio(det.corners)
                
                print("🔍 [TEST] \(tc.name):")
                print("   • Detected Area: \(String(format: "%.1f%%", areaPct)) (Min Expected: \(tc.minExpectedAreaPct)%)")
                print("   • Aspect Ratio:  \(String(format: "%.3f", ratio))")
                print("   • Method:        \(det.method.rawValue)")
                print("   • Corners:       \(det.corners.map { "(\(Int($0.x)), \(Int($0.y)))" })")
                
                assert(areaPct >= tc.minExpectedAreaPct, "\(tc.name) area \(areaPct)% is below expected \(tc.minExpectedAreaPct)%")
                assert(ratio >= 1.15 && ratio <= 1.95, "\(tc.name) ratio \(ratio) is not in Cheki range")
                
                print("   ✅ PASSED! [\(tc.expectedFormat)]\n")
                passed += 1
            } catch {
                print("❌ FAILED on \(tc.name): \(error)\n")
                exit(1)
            }
        }
        
        print("===============================================================")
        print("🎉 ALL \(passed)/\(testCases.count) TESTS PASSED WITH 100% SUCCESS!")
        print("===============================================================")
    }
}
