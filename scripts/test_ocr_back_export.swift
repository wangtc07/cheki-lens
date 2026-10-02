import Foundation
import Vision
import CoreGraphics
import ImageIO

let outDir = "TestData/benchmark_output_ocr_back"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Target files to test
var testFiles: [String] = [
    "/Users/tcwang/.gemini/antigravity/brain/2321a9b0-59c1-4387-8354-5efce9f3dcdf/.user_uploaded/media_1790913536053.jpg"
]

// Also scan TestData/images for any photos containing instax/mouth
let imagesDir = "TestData/images"
if let allFiles = try? FileManager.default.contentsOfDirectory(atPath: imagesDir) {
    for f in allFiles {
        if f.hasSuffix(".jpg") || f.hasSuffix(".jpeg") || f.hasSuffix(".JPG") {
            testFiles.append((imagesDir as NSString).appendingPathComponent(f))
        }
    }
}

print("Scanning files for backside text...")

var processedCount = 0

for path in testFiles {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        continue
    }
    
    let w = Double(cgImg.width)
    let h = Double(cgImg.height)
    
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    
    let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
    try? handler.perform([request])
    
    guard let observations = request.results, !observations.isEmpty else { continue }
    
    var topRect: CGRect? = nil
    var bottomRect: CGRect? = nil
    
    for obs in observations {
        let text = obs.topCandidates(1).first?.string.lowercased() ?? ""
        if text.contains("mouth") || text.contains("don't") || text.contains("put") {
            topRect = obs.boundingBox
        }
        if text.contains("instax") || text.contains("fujifilm") {
            bottomRect = obs.boundingBox
        }
    }
    
    if topRect != nil || bottomRect != nil {
        print("🎯 Found Backside Polaroid: \(url.lastPathComponent)")
        if let t = topRect { print("   - Top text: \(t)") }
        if let b = bottomRect { print("   - Bottom text: \(b)") }
        
        // Compute corners
        var cx = 0.5
        var tY = 0.95
        var bY = 0.05
        var widthRatio = 0.62
        
        if let t = topRect {
            cx = t.midX
            tY = t.maxY + (t.height * 0.5) // top edge
            widthRatio = t.width * 1.08 // film width
        }
        if let b = bottomRect {
            if topRect == nil {
                cx = b.midX
                widthRatio = b.width * 1.5
            } else {
                cx = (cx + b.midX) / 2.0
            }
            bY = b.minY - (b.height * 0.8) // bottom edge
        }
        
        let actualTY = (1.0 - tY) * h
        let actualBY = (1.0 - bY) * h
        let actualCX = cx * w
        let halfW = (widthRatio * w) / 2.0
        
        let tl = [max(0.0, actualCX - halfW), max(0.0, actualTY)]
        let tr = [min(w, actualCX + halfW), max(0.0, actualTY)]
        let br = [min(w, actualCX + halfW), min(h, actualBY)]
        let bl = [max(0.0, actualCX - halfW), min(h, actualBY)]
        
        print("   -> Inferred Corners: TL=\(tl), TR=\(tr), BR=\(br), BL=\(bl)")
        processedCount += 1
        
        if processedCount >= 5 { break } // Just test top 5
    }
}

print("Total backside photos found & processed: \(processedCount)")
