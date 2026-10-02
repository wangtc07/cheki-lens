import Foundation
import CoreGraphics
import ImageIO
import Vision

@main
struct BacksideDetectorTests {
    static func main() async {
        print("=== Running BacksideDetector End-to-End Tests on 6 Real Backsides ===")
        
        let targetFiles = [
            "DSCF0024.JPG",
            "DSCF0026.JPG",
            "DSCF0032.JPG",
            "DSCF0034.JPG",
            "DSCF0042.JPG",
            "IMG_6529.jpeg"
        ]
        
        var allPassed = true
        var detectedCount = 0
        
        for tf in targetFiles {
            let path = "TestData/images/\(tf)"
            guard let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/" + path),
                  let imgSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
                print("❌ Cannot load \(tf)")
                allPassed = false
                continue
            }
            
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            do {
                if let res = try await BacksideDetector.detect(in: cgImage, imageSize: size) {
                    detectedCount += 1
                    let tl = res.corners[0]
                    let br = res.corners[2]
                    let w = br.x - tl.x
                    let h = br.y - tl.y
                    let ratio = h / w
                    print("✅ [PASS] \(tf): 100% Detected as Backside (Conf: \(res.confidence))")
                    print("   -> Bounding Box: TL=(\(Int(tl.x)), \(Int(tl.y))), BR=(\(Int(br.x)), \(Int(br.y)))")
                    print("   -> Dimensions:   \(Int(w)) x \(Int(h)) (Ratio: \(String(format: "%.3f", ratio)))")
                } else {
                    print("❌ [FAIL] \(tf): Failed to detect backside!")
                    allPassed = false
                }
            } catch {
                print("❌ [ERROR] \(tf): \(error)")
                allPassed = false
            }
        }
        
        print("\n--- Summary ---")
        print("Detected: \(detectedCount) / \(targetFiles.count) (100% Target: \(detectedCount == targetFiles.count))")
        if allPassed && detectedCount == targetFiles.count {
            print("🎉 ALL 6 REAL BACKSIDE DETECTIONS PASSED WITH 100% SUCCESS!")
        } else {
            exit(1)
        }
    }
}
