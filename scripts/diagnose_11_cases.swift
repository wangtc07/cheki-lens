import Foundation
import CoreGraphics
import CoreImage
import Vision

extension VisionManager {
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? { nil }
}

@main
struct DiagnoseRunner {
    static func main() async {
        let cases = [
            "287136_DSCF1465.JPG",
            "287137_DSCF1467.JPG",
            "DSCF0008.JPG",
            "DSCF0984.JPG",
            "DSCF0041 2.JPG",
            "DSCF3696.JPG",
            "IMG_1979.jpeg",
            "IMG_3491.jpeg",
            "IMG_6530.jpeg",
            "IMG_7364.jpeg",
            "IMG_7882.jpeg"
        ]

        let vm = VisionManager()

        for name in cases {
            print("\n=======================================================")
            print("🔍 DIAGNOSING: \(name)")
            print("=======================================================")
            
            var path = "TestData/images/\(name)"
            if !FileManager.default.fileExists(atPath: path) {
                path = "datasets/cheki_pose/images/val/\(name)"
            }
            if !FileManager.default.fileExists(atPath: path) {
                let base = (name as NSString).deletingPathExtension
                path = "datasets/cheki_pose/images/val/\(base).jpg"
            }
            guard FileManager.default.fileExists(atPath: path),
                  let url = URL(string: "file://" + FileManager.default.currentDirectoryPath + "/" + path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                print("❌ Cannot load image at \(path)")
                continue
            }
            
            let size = CGSize(width: cgImage.width, height: cgImage.height)
            print("Image Size: \(cgImage.width) x \(cgImage.height)")
            
            // 1. Layer 0: Backside OCR
            let isBack = (try? await vm.detectBacksideCorners(in: cgImage, imageSize: size)) != nil
            print("Layer 0 Backside: \(isBack ? "DETECTED" : "None")")
            
            // 2. Layer 1: Native Vision
            var vRes: DetectionResult? = nil
            do {
                vRes = try await vm.detectVisionNative(image: cgImage, imageSize: size)
                let r = VisionManager.quadAspectRatio(vRes!.corners)
                let area = VisionManager.quadArea(vRes!.corners)
                print("Layer 1 Vision Native: FOUND! Area=\(Int(area)) (\(String(format: "%.1f%%", area / Double(size.width * size.height) * 100))), Ratio=\(String(format: "%.3f", r))")
                print("  Corners: \(vRes!.corners.map { "(\(Int($0.x)), \(Int($0.y)))" })")
            } catch {
                print("Layer 1 Vision Native: FAILED (\(error))")
            }
            
            // 3. Layer 1.5: CIDetector
            let ciCtx = CIContext()
            var cRes: DetectionResult? = nil
            if let ciImage = CIImage(cgImage: cgImage).copy() as? CIImage {
                let detector = CIDetector(ofType: CIDetectorTypeRectangle, context: ciCtx, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
                if let features = detector?.features(in: ciImage) as? [CIRectangleFeature] {
                    var bestCArea = 0.0
                    var bestCPts: [CGPoint]? = nil
                    let iW = Double(size.width), iH = Double(size.height)
                    for f in features {
                        let pts = [
                            CGPoint(x: f.topLeft.x, y: iH - f.topLeft.y),
                            CGPoint(x: f.topRight.x, y: iH - f.topRight.y),
                            CGPoint(x: f.bottomRight.x, y: iH - f.bottomRight.y),
                            CGPoint(x: f.bottomLeft.x, y: iH - f.bottomLeft.y)
                        ]
                        let area = VisionManager.quadArea(pts)
                        if VisionManager.isChekiRatio(pts) && area >= 0.03 * iW * iH {
                            if area > bestCArea {
                                bestCArea = area
                                bestCPts = pts
                            }
                        }
                    }
                    if let pts = bestCPts {
                        cRes = DetectionResult(corners: VisionManager.orderPoints(pts), method: .visionNative, confidence: 1.0, imageSize: size)
                        let r = VisionManager.quadAspectRatio(pts)
                        print("Layer 1.5 CIDetector: FOUND! Area=\(Int(bestCArea)), Ratio=\(String(format: "%.3f", r))")
                    } else {
                        print("Layer 1.5 CIDetector: None")
                    }
                }
            }
            
            // Combined Native
            var bestNative: DetectionResult? = nil
            if let v = vRes, let c = cRes {
                let vArea = VisionManager.quadArea(v.corners)
                let cArea = VisionManager.quadArea(c.corners)
                bestNative = (cArea > vArea * 1.05) ? c : v
            } else if let v = vRes {
                bestNative = v
            } else if let c = cRes {
                bestNative = c
            }
            
            if let best = bestNative {
                // FrameExtrapolator check
                let extra = FrameExtrapolator.checkAndExtrapolate(corners: best.corners, imageSize: size)
                print("FrameExtrapolator: isInnerFrame=\(extra.isInnerFrame), detectedFormat=\(extra.detectedFormat)")
                if extra.isInnerFrame {
                    print("  Extrapolated: \(extra.extrapolatedCorners.map { "(\(Int($0.x)), \(Int($0.y)))" })")
                }
                
                // Refinement check
                let ref = VisionManager.refineQuadrilateral(corners: best.corners, imageSize: size)
                print("Refinement: wasRefined=\(ref.wasRefined), anomIdx=\(String(describing: ref.anomalousCornerIndex)), hSkew=\(String(format: "%.2f°", ref.horizontalSkewAngle)), vSkew=\(String(format: "%.2f°", ref.verticalSkewAngle))")
                if ref.wasRefined {
                    print("  Refined: \(ref.corners.map { "(\(Int($0.x)), \(Int($0.y)))" })")
                }
            }
            
            // Layer 1.8: Fallback YOLO
            if let fallback = try? await vm.detectFallbackPose(image: cgImage, imageSize: size) {
                let r = VisionManager.quadAspectRatio(fallback.corners)
                let area = VisionManager.quadArea(fallback.corners)
                print("Layer 1.8 Fallback YOLO: FOUND! Conf=\(String(format: "%.3f", fallback.confidence)), Area=\(Int(area)), Ratio=\(String(format: "%.3f", r))")
                print("  Corners: \(fallback.corners.map { "(\(Int($0.x)), \(Int($0.y)))" })")
            } else {
                print("Layer 1.8 Fallback YOLO: None")
            }
            
            // Final detectQuad result
            do {
                let finalDet = try await vm.detectQuad(in: cgImage, imageSize: size)
                let spec = AspectRatioClassifier.classify(corners: finalDet.corners)
                print("🎯 FINAL DETECT: Method=\(finalDet.method.rawValue), Spec=\(spec.format)(\(spec.orientation)), OutputSize=\(spec.standardOutputSize)")
                print("  Final Corners: \(finalDet.corners.map { "(\(Int($0.x)), \(Int($0.y)))" })")
            } catch {
                print("🎯 FINAL DETECT: FAILED (\(error))")
            }
        }
    }
}
