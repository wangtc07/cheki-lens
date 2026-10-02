import Foundation
import CoreGraphics
import CoreImage
import Vision
import ImageIO

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct BenchmarkSyncer {
    static func main() async {
        let cases = [
            "287136_DSCF1465.JPG",
            "287137_DSCF1467.JPG",
            "DSCF0008.JPG",
            "DSCF0984.JPG",
            "DSCF0041 2.JPG",
            "DSCF3696.JPG",
            "IMG_1979.jpeg",
            "IMG_3491.jpeg",
            "IMG_7364.jpeg",
            "IMG_7882.jpeg"
        ]
        let vm = VisionManager()
        
        let probDir = "TestData/benchmark_output_problematic_cases"
        let hybridDir = "TestData/benchmark_output_hybrid"
        try? FileManager.default.createDirectory(atPath: probDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: hybridDir, withIntermediateDirectories: true)
        
        for name in cases {
            var path = "TestData/images/\(name)"
            if !FileManager.default.fileExists(atPath: path) {
                path = "datasets/cheki_pose/images/val/\(name)"
            }
            guard let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/" + path),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                  
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            do {
                let det = try await vm.detectQuad(in: cgImage, imageSize: size)
                let crop = try await vm.perspectiveCorrect(image: cgImage, corners: det.corners, detection: det, format: .auto)
                
                let base = (name as NSString).deletingPathExtension
                
                // 1. 輸出至專屬排錯驗證資料夾
                let p1 = "\(probDir)/\(base)_fixed.jpg"
                let u1 = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + p1)
                if let dest1 = CGImageDestinationCreateWithURL(u1 as CFURL, "public.jpeg" as CFString, 1, nil) {
                    let opt: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
                    CGImageDestinationAddImage(dest1, crop.cgImage, opt as CFDictionary)
                    CGImageDestinationFinalize(dest1)
                    print("✅ Exported: \(p1)")
                }
                
                // 2. 同步更新 hybrid 資料夾，避免用戶開啟舊檔誤解
                let p2 = "\(hybridDir)/\(base)_hybrid.jpg"
                let u2 = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + p2)
                if let dest2 = CGImageDestinationCreateWithURL(u2 as CFURL, "public.jpeg" as CFString, 1, nil) {
                    let opt: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
                    CGImageDestinationAddImage(dest2, crop.cgImage, opt as CFDictionary)
                    CGImageDestinationFinalize(dest2)
                    print("✅ Updated: \(p2)")
                }
            } catch {
                print("❌ Failed: \(name): \(error)")
            }
        }
    }
}
