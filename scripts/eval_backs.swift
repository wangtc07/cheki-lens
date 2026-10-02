import Foundation
import Vision
import CoreGraphics
import ImageIO

let targetFiles = ["DSCF0024.JPG", "DSCF0026.JPG", "DSCF0034.JPG", "DSCF0032.JPG", "DSCF0042.JPG", "IMG_6529.jpeg"]
let imagesDir = "TestData/images"

for tf in targetFiles {
    let p = (imagesDir as NSString).appendingPathComponent(tf)
    let url = URL(fileURLWithPath: p)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("Could not load \(tf)")
        continue
    }
    
    let w = Double(cgImg.width)
    let h = Double(cgImg.height)
    
    let req = VNDetectRectanglesRequest()
    req.maximumObservations = 3
    req.minimumConfidence = 0.2
    req.minimumAspectRatio = 0.4
    req.maximumAspectRatio = 1.0
    
    let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
    try? handler.perform([req])
    
    print("\n--- Results for \(tf) (\(Int(w))x\(Int(h))) ---")
    if let results = req.results, !results.isEmpty {
        for (i, obs) in results.enumerated() {
            let conf = obs.confidence
            let tl = [obs.topLeft.x * w, (1.0 - obs.topLeft.y) * h]
            let br = [obs.bottomRight.x * w, (1.0 - obs.bottomRight.y) * h]
            let boxW = abs(br[0] - tl[0])
            let boxH = abs(br[1] - tl[1])
            let areaRatio = (boxW * boxH) / (w * h)
            print("  [#\(i)] conf=\(String(format: "%.2f", conf)), areaRatio=\(String(format: "%.1f%%", areaRatio * 100)), TL=\(tl), BR=\(br)")
        }
    } else {
        print("  ❌ No rectangles detected by Apple Vision")
    }
}
