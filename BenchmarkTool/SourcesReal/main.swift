import Foundation
import CoreImage
import Vision

// We will test detectQuad directly

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

let annotLines = (try String(contentsOf: annotFile, encoding: .utf8)).components(separatedBy: .newlines).filter { !$0.isEmpty }
let annotations = annotLines.compactMap { line -> Annotation? in
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Annotation.self, from: data)
}

let sharedCIContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

func run() async {
    print("Running real VisionManager benchmark...")
    var hitCount = 0
    let manager = VisionManager()

    for a in annotations {
        let url = imagesDir.appendingPathComponent(a.filename)
        
        // Use loadAndPreprocess which correctly handles sRGB and EXIF!
        guard let cgImg = try? await manager.loadAndPreprocess(url: url) else {
            print("\(a.filename) Load failed")
            continue
        }
        
        // detectQuad
        let size = CGSize(width: cgImg.width, height: cgImg.height)
        if let res = try? await manager.detectQuad(in: cgImg, imageSize: size) {
            let scaleX = Double(cgImg.width) / Double(a.width)
            let scaleY = Double(cgImg.height) / Double(a.height)
            let rmse = cornerRMSE(res.corners, a.points.map{CGPoint(x:$0[0], y:$0[1])}, scaleX: scaleX, scaleY: scaleY)
            let hit = rmse <= 15.0
            if hit { hitCount += 1 }
            let fn = a.filename.padding(toLength: 25, withPad: " ", startingAt: 0)
            let meth = res.method.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let rmseStr = String(format: "%7.1f", rmse)
            let icon = hit ? "✅" : "⚠️"
            print("\(fn) \(meth) \(rmseStr) \(icon)")
        } else {
            print("\(a.filename) detectQuad failed")
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
