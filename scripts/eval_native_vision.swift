import Foundation
import Vision
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count > 1 else {
    print("{}")
    exit(0)
}

let imagesDir = CommandLine.arguments[1]
let fm = FileManager.default
guard let files = try? fm.contentsOfDirectory(atPath: imagesDir) else {
    print("{}")
    exit(0)
}

var results: [String: [[Double]]] = [:]

for file in files {
    let lower = file.lowercased()
    guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") else { continue }
    let path = (imagesDir as NSString).appendingPathComponent(file)
    let url = URL(fileURLWithPath: path)
    
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        continue
    }
    
    let w = Double(cgImage.width)
    let h = Double(cgImage.height)
    
    let request = VNDetectRectanglesRequest()
    request.maximumObservations = 1
    request.minimumConfidence = 0.4
    request.minimumAspectRatio = 0.4
    request.maximumAspectRatio = 1.0
    
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])
    
    if let obs = request.results?.first as? VNRectangleObservation {
        // VNRectangleObservation coordinates are normalized with origin at bottom-left
        let tl = [obs.topLeft.x * w, (1.0 - obs.topLeft.y) * h]
        let tr = [obs.topRight.x * w, (1.0 - obs.topRight.y) * h]
        let br = [obs.bottomRight.x * w, (1.0 - obs.bottomRight.y) * h]
        let bl = [obs.bottomLeft.x * w, (1.0 - obs.bottomLeft.y) * h]
        results[file] = [tl, tr, br, bl]
    }
}

if let data = try? JSONSerialization.data(withJSONObject: results, options: []) {
    if let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}
