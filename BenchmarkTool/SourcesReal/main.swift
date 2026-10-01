import Foundation
import CoreImage
import Vision
import UniformTypeIdentifiers

struct Annotation: Decodable {
    let filename: String
    let points: [[Double]]
    let width: Int
    let height: Int
}

func cornerRMSE(_ pred: [CGPoint], _ gt: [CGPoint], scaleX: Double, scaleY: Double) -> Double {
    let pairs = zip(pred, gt)
    let sumSq = pairs.reduce(0.0) { acc, pair in
        let dx = Double(pair.0.x) - pair.1.x * scaleX
        let dy = Double(pair.0.y) - pair.1.y * scaleY
        return acc + dx*dx + dy*dy
    }
    return sqrt(sumSq / Double(pred.count))
}

let testDataDir = URL(fileURLWithPath: "/Users/tcwang/Documents/ChekiLens/TestData")
let imagesDir = testDataDir.appendingPathComponent("images")
let annotFile = testDataDir.appendingPathComponent("cheki_annotations.jsonl")
let outputDir = testDataDir.appendingPathComponent("output_vision")

let annotLines = (try String(contentsOf: annotFile, encoding: .utf8)).components(separatedBy: .newlines).filter { !$0.isEmpty }
let annotations = annotLines.compactMap { line -> Annotation? in
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Annotation.self, from: data)
}

func run() async {
    print("Running real VisionManager benchmark (Vision + Conditional Hough)...")
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
    
    var hitCount = 0
    let manager = VisionManager()

    for a in annotations {
        let url = imagesDir.appendingPathComponent(a.filename)
        
        do {
            // manager.process does EVERYTHING (load, detect, crop)
            let result = try await manager.process(url: url, format: .auto, borderInset: 0.0)
            
            // To evaluate RMSE, we look at result.detectionResult
            let scaleX = Double(result.detectionResult.imageSize.width) / Double(a.width)
            let scaleY = Double(result.detectionResult.imageSize.height) / Double(a.height)
            let rmse = cornerRMSE(result.detectionResult.corners, a.points.map{CGPoint(x:$0[0], y:$0[1])}, scaleX: scaleX, scaleY: scaleY)
            let hit = rmse <= 15.0
            if hit { hitCount += 1 }
            
            let fn = a.filename.padding(toLength: 25, withPad: " ", startingAt: 0)
            let meth = result.detectionResult.method.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let rmseStr = String(format: "%7.1f", rmse)
            let icon = hit ? "✅" : "⚠️"
            print("\(fn) \(meth) \(rmseStr) \(icon)")
            
            // Save cropped image
            let outName = a.filename.replacingOccurrences(of: ".JPG", with: "_crop.jpg")
            let outURL = outputDir.appendingPathComponent(outName)
            if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, result.cgImage, nil)
                CGImageDestinationFinalize(dest)
            }
            
        } catch {
            print("\(a.filename) Failed: \(error)")
        }
    }
    print("Hit <= 15px: \(hitCount) / \(annotations.count) (\(Double(hitCount)/Double(annotations.count)*100)%)")
}

let sema = DispatchSemaphore(value: 0)
Task {
    await run()
    sema.signal()
}
sema.wait()
