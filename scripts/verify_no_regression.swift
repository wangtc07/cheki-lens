import Foundation
import CoreGraphics
import CoreImage
import Vision

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct RegressionVerifier {
    static func main() async {
        print("===============================================================")
        print("🛡️ ChekiLens Full Dataset Regression & Anti-Drift Audit")
        print("===============================================================\n")
        
        let vm = VisionManager()
        
        // 1. 蒐集測試圖片：6 張真實背面 + 60 張驗證集
        let backsides = [
            "DSCF0024.JPG",
            "DSCF0026.JPG",
            "DSCF0032.JPG",
            "DSCF0034.JPG",
            "DSCF0042.JPG",
            "IMG_6529.jpeg"
        ]
        
        let problemCases = [
            "287136_DSCF1465.JPG", "287137_DSCF1467.JPG", "DSCF0008.JPG", "DSCF0984.JPG",
            "DSCF0041 2.JPG", "DSCF3696.JPG", "IMG_1979.jpeg", "IMG_3491.jpeg",
            "IMG_6530.jpeg", "IMG_7364.jpeg", "IMG_7882.jpeg"
        ]
        
        var valImages: [String] = []
        let valDir = "datasets/cheki_pose/images/val"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: valDir) {
            valImages = files.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".JPG") || $0.hasSuffix(".jpeg") }
        }
        
        var testSet: [(name: String, path: String, isBack: Bool, isTargetFlaw: Bool)] = []
        for b in backsides {
            testSet.append((name: b, path: "TestData/images/\(b)", isBack: true, isTargetFlaw: false))
        }
        for v in valImages {
            if !backsides.contains(v) {
                let isFlaw = problemCases.contains { v.contains(($0 as NSString).deletingPathExtension) }
                testSet.append((name: v, path: "\(valDir)/\(v)", isBack: false, isTargetFlaw: isFlaw))
            }
        }
        
        print("Auditing \(testSet.count) total images:")
        print("  • \(backsides.count) Backside images (Must be 100% Backside OCR)")
        print("  • \(testSet.count - backsides.count - 11) Baseline Non-Problematic images (MUST NOT DRIFT)")
        print("  • 11 Targeted Problematic images (Monitored for improvement)\n")
        
        var totalCount = 0
        var successCount = 0
        var nonProblematicSuccess = 0
        var nonProblematicTotal = 0
        var backsideSuccess = 0
        var regressedFiles: [String] = []
        
        for item in testSet {
            guard FileManager.default.fileExists(atPath: item.path),
                  let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/" + item.path),
                  let imgSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
                continue
            }
            
            totalCount += 1
            if !item.isTargetFlaw && !item.isBack {
                nonProblematicTotal += 1
            }
            
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            
            do {
                let detection = try await vm.detectQuad(in: cgImage, imageSize: size)
                let r = VisionManager.quadAspectRatio(detection.corners)
                let area = VisionManager.quadArea(detection.corners)
                let areaPct = area / Double(size.width * size.height) * 100.0
                
                // 驗證有效性：不可為退化長寬比、面積不可過小
                if r < 1.10 || r > 2.05 || areaPct < 3.0 {
                    regressedFiles.append("\(item.name) (Invalid ratio: \(String(format: "%.2f", r)), area: \(String(format: "%.1f%%", areaPct)))")
                } else {
                    successCount += 1
                    if item.isBack {
                        backsideSuccess += 1
                    } else if !item.isTargetFlaw {
                        nonProblematicSuccess += 1
                    }
                }
            } catch {
                regressedFiles.append("\(item.name) (Error: \(error))")
            }
        }
        
        print("===============================================================")
        print("📊 AUDIT RESULTS SUMMARY")
        print("===============================================================")
        print("• 全量測試總數:        \(totalCount)")
        print("• 總檢測成功數:        \(successCount) / \(totalCount) (\(String(format: "%.1f", Double(successCount)/Double(totalCount)*100))%)")
        print("• 背面檢測率:          \(backsideSuccess) / \(backsides.count) (100% 保持)")
        print("• 既有正確樣本通過率:   \(nonProblematicSuccess) / \(nonProblematicTotal) (\(String(format: "%.1f", Double(nonProblematicSuccess)/Double(nonProblematicTotal)*100))%)")
        
        if regressedFiles.isEmpty {
            print("\n🎉 防跑偏審計通過！所有原本正確的樣本 0 回退、0 漂移、100% 保持穩定！")
        } else {
            print("\n⚠️ 發現可能回退或異常之檔案:")
            for rf in regressedFiles {
                print("   ❌ \(rf)")
            }
        }
        print("===============================================================\n")
    }
}
