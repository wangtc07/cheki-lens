import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

enum ChekiSampleCategory: String {
    case paintedFront = "滿版塗鴉正面"
    case backside     = "拍立得反面"
    case standardFront = "拍立得正面"
}

struct BenchmarkSample {
    let name: String
    let category: ChekiSampleCategory
}

@main
struct Benchmark60PaintedAndPairs {
    static func main() async {
        print("==========================================================================")
        print("🎯 ChekiLens 60-Image Benchmark (正面 42 張 + 反面 6 張 + 滿版塗鴉正面 12 張)")
        print("   資料來源: /Users/tcwang/Documents/ChekiLens/TestData/images")
        print("==========================================================================\n")

        let samples: [BenchmarkSample] = [
            // 1. 滿版塗鴉正面 (12 張)
            BenchmarkSample(name: "DSCF0012.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0025.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0029.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0031.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0033.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0036.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0037.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0038.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0039.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0040.JPG", category: .paintedFront),
            BenchmarkSample(name: "DSCF0073.JPG", category: .paintedFront),
            BenchmarkSample(name: "IMG_6530.jpeg", category: .paintedFront),

            // 2. 拍立得反面 (6 張)
            BenchmarkSample(name: "DSCF0024.JPG", category: .backside),
            BenchmarkSample(name: "DSCF0026.JPG", category: .backside),
            BenchmarkSample(name: "DSCF0032.JPG", category: .backside),
            BenchmarkSample(name: "DSCF0034.JPG", category: .backside),
            BenchmarkSample(name: "DSCF0042.JPG", category: .backside),
            BenchmarkSample(name: "IMG_6529.jpeg", category: .backside),

            // 3. 一般與簽名拍立得正面 (42 張)
            BenchmarkSample(name: "DSCF0003.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0004.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0005.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0006.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0007.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0008.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0009.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0010.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0011.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0013.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0014.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0015.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0016.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0017.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0018.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0019.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0020.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0021.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0023.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0041.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0043.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0044.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0045.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0046.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0047.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0048.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0050.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0051.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0053.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0054.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0056.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0057.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0058.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0059.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0060.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0062.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0065.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0068.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0069.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0070.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0072.JPG", category: .standardFront),
            BenchmarkSample(name: "DSCF0074.JPG", category: .standardFront)
        ]

        let vm = VisionManager()
        let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/TestData/benchmark_60_painted_and_pairs")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var passedTotal = 0
        var paintedPassed = 0
        var backsidePassed = 0
        var standardPassed = 0
        var failures: [String] = []

        for (idx, item) in samples.enumerated() {
            let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/TestData/images/" + item.name)
            do {
                let res = try await vm.process(url: fileURL)
                let size = res.detectionResult.imageSize
                let canvasArea = Double(size.width * size.height)
                let areaPct = VisionManager.quadArea(res.detectionResult.corners) / max(1.0, canvasArea) * 100.0
                let r = VisionManager.quadAspectRatio(res.detectionResult.corners)

                // 驗證面積佔比 (>= 22%) 與拍立得有效比例 (1.18 ~ 1.70)
                let isValid = areaPct >= 22.0 && r >= 1.18 && r <= 1.70
                let statusIcon = isValid ? "✅" : "❌"
                print(String(format: "[%02d/60] %@ [%@] %-14@ | Area: %5.1f%% | Ratio: %.3f | Corners: %@",
                             idx + 1,
                             statusIcon,
                             item.category.rawValue,
                             (item.name as NSString),
                             areaPct,
                             r,
                             res.detectionResult.corners.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " ") as NSString))

                if isValid {
                    passedTotal += 1
                    switch item.category {
                    case .paintedFront: paintedPassed += 1
                    case .backside:     backsidePassed += 1
                    case .standardFront: standardPassed += 1
                    }
                } else {
                    failures.append("\(item.name) [\(item.category.rawValue)] Area=\(String(format: "%.1f%%", areaPct)), Ratio=\(String(format: "%.3f", r))")
                }

                let outURL = outDir.appendingPathComponent("crop_\(item.name)")
                if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, res.cgImage, nil)
                    CGImageDestinationFinalize(dest)
                }
            } catch {
                print(String(format: "[%02d/60] ❌ [%@] %-14@ | ERROR: %@",
                             idx + 1,
                             item.category.rawValue,
                             (item.name as NSString),
                             "\(error)" as NSString))
                failures.append("\(item.name) [\(item.category.rawValue)] Error=\(error)")
            }
        }

        print("\n==========================================================================")
        print("📊 60 張綜合基準測試結果摘要 (Benchmark Summary)")
        print("==========================================================================")
        print("• 滿版塗鴉正面 (Painted Front): \(paintedPassed) / 12 (\(String(format: "%.1f%%", Double(paintedPassed) / 12.0 * 100.0)))")
        print("• 拍立得反面   (Backside):      \(backsidePassed) / 6  (\(String(format: "%.1f%%", Double(backsidePassed) / 6.0 * 100.0)))")
        print("• 拍立得正面   (Standard Front):\(standardPassed) / 42 (\(String(format: "%.1f%%", Double(standardPassed) / 42.0 * 100.0)))")
        print("• 總計通過率   (Total Pass):    \(passedTotal) / \(samples.count) (\(String(format: "%.1f%%", Double(passedTotal) / Double(samples.count) * 100.0)))")
        print("• 裁切成果輸出目錄: TestData/benchmark_60_painted_and_pairs/")
        if failures.isEmpty {
            print("\n🎉 60/60 全數通過（含 DSCF0029 滿版塗鴉正面、全部正反面與一般拍立得）！")
        } else {
            print("\n⚠️ 異常項目:")
            for f in failures { print("  - \(f)") }
        }
        print("==========================================================================\n")
    }
}
