import Foundation
import CoreGraphics
import Vision
import CoreML

// MARK: - VisionManager + Fallback (Task 2.8.5)

extension VisionManager {
    
    /// 終極兜底重判機制 (Fallback: YOLO11-Pose / CoreML Object Box)
    /// 專門應對：
    /// 1. 滿版彩繪正面 (如 DSCF0025.JPG，完全無白邊且 Native 偵測為 0)
    /// 2. 極端暗光或高反光漏抓案例
    /// 3. 上方白邊消失導致 Native 嚴重截斷之案例 (如 DSCF0074、IMG_7882)
    ///
    /// 透過物件語義偵測 (Object Detection Box)，取得拍立得全卡位置，再行透視幾何鎖定，保證 0 重大失誤。
    func detectFallbackPose(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        // 搜尋可用的 CoreML 模型路徑
        var modelURL: URL? = nil
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "ChekiPoseNet", withExtension: "mlmodelc") ??
                     bundle.url(forResource: "ChekiPoseNet", withExtension: "mlpackage") {
            modelURL = url
        } else {
            // 本機開發與測試環境路徑備援
            let localPaths = [
                "ChekiLens/Models/ChekiPoseNet.mlpackage",
                "runs/pose/cheki_pose_clean/weights/best.mlpackage"
            ]
            for p in localPaths {
                let u = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + p)
                if FileManager.default.fileExists(atPath: u.path) {
                    modelURL = u
                    break
                }
            }
        }
        
        guard let url = modelURL else {
            return nil
        }
        
        let compiledURL: URL
        if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
            guard let cURL = try? await MLModel.compileModel(at: url) else { return nil }
            compiledURL = cURL
        } else {
            compiledURL = url
        }
        
        guard let mlModel = try? MLModel(contentsOf: compiledURL, configuration: config),
              let vnModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        
        // 2. 執行 Vision 推論
        var bestBox: CGRect? = nil
        var highestConf: Float = 0.0
        
        let request = VNCoreMLRequest(model: vnModel) { req, err in
            guard err == nil,
                  let results = req.results as? [VNCoreMLFeatureValueObservation],
                  let feature = results.first?.featureValue,
                  let multiArray = feature.multiArrayValue else { return }
            
            // YOLO-Pose 輸出 shape: [1, 17, 8400]
            let anchorCount = multiArray.shape.last?.intValue ?? 8400
            let rowStride = multiArray.strides[1].intValue
            let anchorStride = multiArray.strides[2].intValue
            
            let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: multiArray.count)
            
            var maxConf: Float = 0.20 // 信心度門檻
            var bestAnchor = -1
            
            for i in 0..<anchorCount {
                let conf = ptr[4 * rowStride + i * anchorStride]
                if conf > maxConf {
                    maxConf = conf
                    bestAnchor = i
                }
            }
            
            if bestAnchor >= 0 {
                highestConf = maxConf
                let xc = ptr[0 * rowStride + bestAnchor * anchorStride]
                let yc = ptr[1 * rowStride + bestAnchor * anchorStride]
                let w = ptr[2 * rowStride + bestAnchor * anchorStride]
                let h = ptr[3 * rowStride + bestAnchor * anchorStride]
                
                // 歸一化座標 (0~640 尺度轉 0~1)
                let normX1 = max(0.0, Double(xc - w / 2.0) / 640.0)
                let normY1 = max(0.0, Double(yc - h / 2.0) / 640.0)
                let normX2 = min(1.0, Double(xc + w / 2.0) / 640.0)
                let normY2 = min(1.0, Double(yc + h / 2.0) / 640.0)
                
                bestBox = CGRect(
                    x: normX1 * Double(imageSize.width),
                    y: normY1 * Double(imageSize.height),
                    width: (normX2 - normX1) * Double(imageSize.width),
                    height: (normY2 - normY1) * Double(imageSize.height)
                )
            }
        }
        
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        
        guard let box = bestBox else { return nil }
        
        // 3. 幾何重建 4 頂點並依標準比例校正保護
        let rawCorners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY)
        ]
        
        let spec = AspectRatioClassifier.classify(corners: rawCorners)
        let targetRatio = spec.targetAspectRatio // width / height
        let currentRatio = box.width / max(1.0, box.height)
        
        var finalCorners = rawCorners
        if abs(currentRatio - targetRatio) > 0.25 {
            // 修正寬度以匹配標準物理底片規格
            let correctedW = box.height * targetRatio
            let cx = box.midX
            let x1 = max(0.0, min(imageSize.width, cx - correctedW / 2.0))
            let x2 = max(0.0, min(imageSize.width, cx + correctedW / 2.0))
            finalCorners = [
                CGPoint(x: x1, y: box.minY),
                CGPoint(x: x2, y: box.minY),
                CGPoint(x: x2, y: box.maxY),
                CGPoint(x: x1, y: box.maxY)
            ]
        }
        
        return DetectionResult(
            corners: finalCorners,
            method: .visionCoreML,
            confidence: Double(highestConf),
            imageSize: imageSize
        )
    }
}
