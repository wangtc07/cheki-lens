import Foundation
import CoreGraphics
import CoreImage
import Vision
import ImageIO

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct Task292Tester {
    static func main() async {
        print("===============================================================")
        print("🧪 Testing Task 2.9.2: FrameExtrapolator Contrast Gate & Scaling")
        print("===============================================================\n")

        let vm = VisionManager()
        
        let probDir = "TestData/benchmark_output_problematic_cases"
        let hybridDir = "TestData/benchmark_output_hybrid"
        try? FileManager.default.createDirectory(atPath: probDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: hybridDir, withIntermediateDirectories: true)

        let testCases: [(name: String, shouldExtrapolate: Bool, desc: String)] = [
            ("287136_DSCF1465.JPG", false, "287136: Outer card with black desk must NOT extrapolate"),
            ("IMG_7882.jpeg", false, "IMG_7882: Full card must NOT extrapolate to canvas boundaries"),
            ("DSCF3716.jpg", true, "DSCF3716: Real inner photo MUST extrapolate outward to card edges"),
            ("DSCF0041 2.JPG", false, "DSCF0041 2: Full card must NOT distort into Square")
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

            do {
                let detNative = try await vm.detectVisionNative(image: cgImage, imageSize: size)
                let extra = FrameExtrapolator.checkAndExtrapolate(corners: detNative.corners, imageSize: size, image: cgImage)

                print("🔍 [TEST] \(tc.name):")
                print("   • isInnerFrame: \(extra.isInnerFrame) (Expected: \(tc.shouldExtrapolate))")
                print("   • Native Ratio: \(String(format: "%.3f", VisionManager.quadAspectRatio(detNative.corners)))")
                
                assert(extra.isInnerFrame == tc.shouldExtrapolate, "\(tc.name) extrapolation mismatch: expected \(tc.shouldExtrapolate), got \(extra.isInnerFrame)")
                
                let finalDet = try await vm.detectQuad(in: cgImage, imageSize: size)
                let crop = try await vm.perspectiveCorrect(image: cgImage, corners: finalDet.corners, detection: finalDet, format: .auto)
                let spec = AspectRatioClassifier.classify(corners: finalDet.corners)
                
                print("   • Final Method: \(finalDet.method.rawValue)")
                print("   • Final Spec:   \(spec.format) (\(spec.orientation))")
                print("   • Output Size:  \(Int(crop.outputSize.width)) x \(Int(crop.outputSize.height))")
                print("   • Corners:      \(finalDet.corners.map { "(\(Int($0.x)), \(Int($0.y)))" })")

                // Export to both benchmark folders
                let base = (tc.name as NSString).deletingPathExtension
                let pProb = "\(probDir)/\(base)_fixed.jpg"
                let pHybrid = "\(hybridDir)/\(base)_hybrid.jpg"
                
                for outPath in [pProb, pHybrid] {
                    let u = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + outPath)
                    if let dest = CGImageDestinationCreateWithURL(u as CFURL, "public.jpeg" as CFString, 1, nil) {
                        let opt: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
                        CGImageDestinationAddImage(dest, crop.cgImage, opt as CFDictionary)
                        CGImageDestinationFinalize(dest)
                    }
                }
                print("   💾 Exported to: \(pProb) & \(pHybrid)")
                print("   ✅ PASSED! [\(tc.desc)]\n")
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
