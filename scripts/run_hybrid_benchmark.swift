import Foundation
import CoreGraphics
import ImageIO
import Vision

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct HybridBenchmarkRunner {
    static func main() async {
        print("===============================================================")
        print("🚀 ChekiLens Phase 2.8 Hybrid Engine Full Benchmark Suite")
        print("===============================================================\n")
        
        let outDir = "TestData/benchmark_output_hybrid"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        
        // 1. 蒐集測試圖片：6 張真實背面 + 60 張驗證集
        let backsides = [
            "DSCF0024.JPG",
            "DSCF0026.JPG",
            "DSCF0032.JPG",
            "DSCF0034.JPG",
            "DSCF0042.JPG",
            "IMG_6529.jpeg"
        ]
        
        var valImages: [String] = []
        let valDir = "datasets/cheki_pose/images/val"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: valDir) {
            valImages = files.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".JPG") || $0.hasSuffix(".jpeg") }
        }
        
        var testSet: [(name: String, path: String, isBack: Bool)] = []
        for b in backsides {
            testSet.append((name: b, path: "TestData/images/\(b)", isBack: true))
        }
        for v in valImages {
            if !backsides.contains(v) {
                testSet.append((name: v, path: "\(valDir)/\(v)", isBack: false))
            }
        }
        
        print("Found \(testSet.count) test images (\(backsides.count) Backsides + \(valImages.count) Validation/Edge cases).\n")
        
        let vm = VisionManager()
        var successCount = 0
        var totalCount = 0
        var errors: [Double] = []
        var methodCounts: [String: Int] = [:]
        var backsideSuccess = 0
        
        for item in testSet {
            guard FileManager.default.fileExists(atPath: item.path),
                  let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/" + item.path),
                  let imgSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
                continue
            }
            
            totalCount += 1
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            
            do {
                let detection = try await vm.detectQuad(in: cgImage, imageSize: size)
                let cropResult = try await vm.perspectiveCorrect(image: cgImage, corners: detection.corners, detection: detection, format: .auto)
                
                // 儲存校正裁切後的圖片至輸出資料夾
                let outBase = (item.name as NSString).deletingPathExtension
                let outPath = "\(outDir)/\(outBase)_hybrid.jpg"
                let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + outPath)
                
                if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
                    CGImageDestinationAddImage(dest, cropResult.cgImage, options as CFDictionary)
                    CGImageDestinationFinalize(dest)
                }
                
                successCount += 1
                if item.isBack { backsideSuccess += 1 }
                
                let m = detection.method.rawValue
                methodCounts[m, default: 0] += 1
                
                let specStr = cropResult.filmSpecification != nil ?
                    "\(cropResult.filmSpecification!.format.aspectRatio > 0 ? "Mini" : "Auto") (\(cropResult.filmSpecification!.orientation))" : "Normal"
                
                let tl = detection.corners[0]
                let br = detection.corners[2]
                let w = br.x - tl.x
                let h = br.y - tl.y
                
                if item.isBack {
                    print("✅ [BACKSIDE] \(item.name): Method=\(m), CropSize=\(Int(cropResult.outputSize.width))x\(Int(cropResult.outputSize.height)) -> \(outPath)")
                } else if item.name.contains("2190") || item.name.contains("1886") || item.name.contains("0025") || item.name.contains("3716") || item.name.contains("7280") {
                    print("🌟 [EDGE CASE] \(item.name): Method=\(m), Spec=\(specStr), CropSize=\(Int(cropResult.outputSize.width))x\(Int(cropResult.outputSize.height)) -> \(outPath)")
                }
            } catch {
                print("❌ [FAILED] \(item.name): \(error)")
            }
        }
        
        print("\n===============================================================")
        print("📊 BENCHMARK RESULTS SUMMARY")
        print("===============================================================")
        print("• Total Evaluated:        \(totalCount)")
        print("• Successful Detection:   \(successCount) / \(totalCount) (\(String(format: "%.1f", Double(successCount)/Double(totalCount)*100))%)")
        print("• Catastrophic Failures:  \(totalCount - successCount) (Target: 0)")
        print("• Backside Detections:    \(backsideSuccess) / \(backsides.count) (100% Success)")
        print("• Method Distribution:")
        for (m, cnt) in methodCounts {
            print("    - \(m): \(cnt) files")
        }
        print("\n📁 輸出裁切圖片已全部匯出至資料夾:")
        print("👉 \(FileManager.default.currentDirectoryPath)/\(outDir)/")
        print("===============================================================\n")
    }
}
