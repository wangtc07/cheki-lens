import Foundation
import CoreGraphics
import ImageIO
import Vision

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct ComparisonExporter {
    static func main() async {
        let args = CommandLine.arguments
        let suffix = args.count > 1 ? args[1] : "_current"
        
        let outDir = "TestData/benchmark_comparison"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        
        let backsides = [
            "DSCF0024.JPG", "DSCF0026.JPG", "DSCF0032.JPG",
            "DSCF0034.JPG", "DSCF0042.JPG", "IMG_6529.jpeg"
        ]
        
        var valImages: [String] = []
        let valDir = "datasets/cheki_pose/images/val"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: valDir) {
            valImages = files.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".JPG") || $0.hasSuffix(".jpeg") }.sorted()
        }
        
        var testSet: [(name: String, path: String, isBack: Bool)] = []
        for b in backsides {
            testSet.append((name: b, path: "TestData/images/\(b)", isBack: true))
        }
        for v in valImages {
            let base = (v as NSString).deletingPathExtension
            if !backsides.contains(where: { ($0 as NSString).deletingPathExtension == base }) {
                var chosenPath = "\(valDir)/\(v)"
                for ext in ["JPG", "jpeg", "jpg", "PNG", "png"] {
                    let cand = "TestData/images/\(base).\(ext)"
                    if FileManager.default.fileExists(atPath: cand) {
                        chosenPath = cand
                        break
                    }
                }
                testSet.append((name: v, path: chosenPath, isBack: false))
            }
        }
        
        print("Exporting \(testSet.count) test images with suffix '\(suffix)' to \(outDir)...")
        let vm = VisionManager()
        var successCount = 0
        
        for (i, item) in testSet.enumerated() {
            let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + item.path)
            guard FileManager.default.fileExists(atPath: item.path),
                  let cgImage = try? await vm.loadAndPreprocess(url: fileURL) else {
                print("[\(i + 1)/\(testSet.count)] ❌ Cannot load: \(item.name)")
                continue
            }
            
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            do {
                let detection = try await vm.detectQuad(in: cgImage, imageSize: size)
                let cropResult = try await vm.perspectiveCorrect(image: cgImage, corners: detection.corners, detection: detection, format: .auto)
                
                let outBase = (item.name as NSString).deletingPathExtension
                let outPath = "\(outDir)/\(outBase)\(suffix).jpg"
                let outURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + outPath)
                
                if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
                    CGImageDestinationAddImage(dest, cropResult.cgImage, options as CFDictionary)
                    CGImageDestinationFinalize(dest)
                }
                successCount += 1
            } catch {
                print("[\(i + 1)/\(testSet.count)] ❌ Detection failed for \(item.name): \(error)")
            }
        }
        print("✅ Finished exporting \(successCount)/\(testSet.count) images with suffix '\(suffix)'!\n")
    }
}
