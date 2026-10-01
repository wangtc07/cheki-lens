// QuickBenchmark/SourcesQuick/main.swift
// Vision-only 快速 Benchmark（無 Hough 耗時計算）
// 僅使用 Layer1 VNDetectRectanglesRequest 測試精度
// 執行：swift run --package-path BenchmarkTool QuickBenchmark

import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision

// ─── Geometry ───
func orderPoints(_ pts: [CGPoint]) -> [CGPoint] {
    guard pts.count == 4 else { return pts }
    let sorted = pts.sorted { $0.x + $0.y < $1.x + $1.y }
    let tl = sorted.first!, br = sorted.last!
    let rem = pts.filter { $0 != tl && $0 != br }
    let tr = rem.min(by: { $0.y - $0.x < $1.y - $1.x })!
    let bl = rem.max(by: { $0.y - $0.x < $1.y - $1.x })!
    return [tl, tr, br, bl]
}

func quadArea(_ pts: [CGPoint]) -> Double {
    var a = 0.0
    for i in 0..<pts.count { let j=(i+1)%pts.count; a += Double(pts[i].x*pts[j].y - pts[j].x*pts[i].y) }
    return abs(a) / 2
}

func quadAspectRatio(_ pts: [CGPoint]) -> Double {
    let o = orderPoints(pts)
    let w = hypot(o[1].x-o[0].x, o[1].y-o[0].y)
    let h = hypot(o[3].x-o[0].x, o[3].y-o[0].y)
    return Double(max(w,h)/max(min(w,h),0.001))
}

func isChekiRatio(_ pts: [CGPoint]) -> Bool {
    let r = quadAspectRatio(pts); return 1.20 <= r && r <= 1.90
}

func cornerRMSE(_ pred: [CGPoint], _ gt: [CGPoint]) -> Double {
    let pairs = zip(orderPoints(pred), orderPoints(gt))
    let sumSq = pairs.reduce(0.0) { acc, p in
        acc + Double((p.0.x-p.1.x)*(p.0.x-p.1.x) + (p.0.y-p.1.y)*(p.0.y-p.1.y))
    }
    return sqrt(sumSq / Double(pred.count))
}

// ─── Load ───
func loadCGImage(url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}


// ─── Vision Detection ───
func detectVision(image: CGImage, imgW: Double, imgH: Double) -> [CGPoint]? {
    let req = VNDetectRectanglesRequest()
    req.minimumAspectRatio  = 0.10
    req.maximumAspectRatio  = 0.99
    req.minimumSize         = 0.01
    req.maximumObservations = 20
    req.minimumConfidence   = 0.1
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
    guard let obs = req.results, !obs.isEmpty else { return nil }

    var best: ([CGPoint], Double)?
    for o in obs {
        let pts: [CGPoint] = [
            CGPoint(x: o.topLeft.x * imgW,     y: (1 - o.topLeft.y) * imgH),
            CGPoint(x: o.topRight.x * imgW,    y: (1 - o.topRight.y) * imgH),
            CGPoint(x: o.bottomRight.x * imgW, y: (1 - o.bottomRight.y) * imgH),
            CGPoint(x: o.bottomLeft.x * imgW,  y: (1 - o.bottomLeft.y) * imgH),
        ]
        let area = quadArea(pts)
        guard area >= 0.03*imgW*imgH, isChekiRatio(pts) else { continue }
        if best == nil || area > best!.1 { best = (pts, area) }
    }
    return best.map { orderPoints($0.0) }
}

// ─── Perspective Crop ───
func perspectiveCrop(image: CGImage, corners: [CGPoint]) -> CGImage? {
    let iH = CGFloat(image.height)
    let o = orderPoints(corners); let tl = o[0], tr = o[1], br = o[2], bl = o[3]
    let wTop = hypot(tr.x - tl.x, tr.y - tl.y), hLeft = hypot(bl.x - tl.x, bl.y - tl.y)
    let (fTL, fTR, fBR, fBL): (CGPoint, CGPoint, CGPoint, CGPoint) = wTop > hLeft ? (bl, tl, tr, br) : (tl, tr, br, bl)
    
    // Core Image 座標系：原點在左下角，以像素為單位（不可正規化除以寬高）
    func toCIVector(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: iH - p.y) }
    
    guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
    f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    f.setValue(toCIVector(fTL), forKey: "inputTopLeft")
    f.setValue(toCIVector(fTR), forKey: "inputTopRight")
    f.setValue(toCIVector(fBR), forKey: "inputBottomRight")
    f.setValue(toCIVector(fBL), forKey: "inputBottomLeft")
    guard let out = f.outputImage else { return nil }
    
    // Instax Mini 標準比例 (86:54) 縮圖（縱長 1200px）
    let targetH = 1200.0
    let targetW = round(targetH * 54.0 / 86.0) // 約 753px
    guard let ls = CIFilter(name: "CILanczosScaleTransform") else { return nil }
    let scaleY = targetH / out.extent.height
    let scaleX = targetW / out.extent.width
    ls.setValue(out, forKey: kCIInputImageKey)
    ls.setValue(scaleY, forKey: kCIInputScaleKey)
    ls.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
    guard let r = ls.outputImage else { return nil }
    return sharedCIContext.createCGImage(r, from: r.extent)
}

let sharedCIContext = CIContext()



func saveCGImage(_ img:CGImage,to url:URL){
    guard let dest=CGImageDestinationCreateWithURL(url as CFURL,"public.jpeg" as CFString,1,nil) else{return}
    CGImageDestinationAddImage(dest,img,[kCGImageDestinationLossyCompressionQuality:0.88] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

// ─── Annotation ───
struct Annotation: Decodable {
    let filename: String; let points: [[Double]]; let width, height: Int
}

// ─── Main ───
let testDir: URL
if let envPath = ProcessInfo.processInfo.environment["TEST_DATA_DIR"], !envPath.isEmpty {
    testDir = URL(fileURLWithPath: envPath)
} else if FileManager.default.fileExists(atPath: "TestData/cheki_annotations.jsonl") {
    testDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TestData")
} else {
    testDir = URL(fileURLWithPath: "/Users/tcwang/Documents/ChekiLens/TestData")
}

let imagesDir = testDir.appendingPathComponent("images")
let annotURL  = testDir.appendingPathComponent("cheki_annotations.jsonl")
let outputDir = testDir.appendingPathComponent("output_vision")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let lines = (try String(contentsOf: annotURL, encoding: .utf8))
    .components(separatedBy: .newlines).filter { !$0.isEmpty }
let annotations = lines.compactMap { l -> Annotation? in
    guard let d = l.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Annotation.self, from: d)
}

print("═══════════════════════════════════════════════════════")
print("  ChekiLens QuickBenchmark (Vision-only) — \(annotations.count) images")
print("═══════════════════════════════════════════════════════")
print("Filename".padding(toLength: 35, withPad: " ", startingAt: 0) + "  RMSE(px)  Status")
print(String(repeating: "─", count: 60))

var hitCount = 0, detectedCount = 0, totalRMSE = 0.0
let hitThresh = 15.0
let t0 = Date()

for a in annotations {
    let imgURL = imagesDir.appendingPathComponent(a.filename)
    guard let img = loadCGImage(url: imgURL) else {
        print(a.filename.padding(toLength: 35, withPad: " ", startingAt: 0) + "  LOAD_ERR")
        continue
    }
    let iW = Double(img.width), iH = Double(img.height)
    let sX = iW/Double(a.width), sY = iH/Double(a.height)
    let gt = a.points.map { CGPoint(x: $0[0]*sX, y: $0[1]*sY) }

    let nameCol = a.filename.padding(toLength: 35, withPad: " ", startingAt: 0)
    if let pred = detectVision(image: img, imgW: iW, imgH: iH) {
        detectedCount += 1
        let rmse = cornerRMSE(pred, gt)
        totalRMSE += rmse
        let hit = rmse <= hitThresh
        if hit { hitCount += 1 }
        let rmseStr = String(format: "%5.1f px", rmse)
        print("\(nameCol)  \(rmseStr)  \(hit ? "✅" : "⚠️ ")")
        if let crop = perspectiveCrop(image: img, corners: pred) {
            let out = outputDir.appendingPathComponent(a.filename.replacingOccurrences(of: ".JPG", with: "_crop.jpg"))
            saveCGImage(crop, to: out)
        }
    } else {
        print("\(nameCol)      - px  ❌")
    }
}


let elapsed = Date().timeIntervalSince(t0)
print(String(repeating: "═", count: 60))
print("\n📊 QuickBenchmark (Vision-only) Results")
print(String(format: "  Total      : %d", annotations.count))
print(String(format: "  Detected   : %d / %d (%.1f%%)", detectedCount, annotations.count,
             Double(detectedCount)/Double(annotations.count)*100))
print(String(format: "  Hit≤%.0fpx : %d / %d (%.1f%%)", hitThresh, hitCount, annotations.count,
             Double(hitCount)/Double(annotations.count)*100))
print(String(format: "  Avg RMSE   : %.2f px", detectedCount > 0 ? totalRMSE/Double(detectedCount) : 0))
print(String(format: "  Elapsed    : %.1f sec", elapsed))
print("  Output: TestData/output_vision/")
