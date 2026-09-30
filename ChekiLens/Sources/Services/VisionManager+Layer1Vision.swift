import Foundation
import CoreImage
import CoreGraphics
import Vision

// MARK: - VisionManager + Layer 1 (VNDetectRectanglesRequest)

extension VisionManager {

    // MARK: - Vision Native Detection

    /// 第一層偵測：Apple Vision ML 矩形識別
    ///
    /// 對應 Python `find_cheki_quad_vision()`：
    /// - minAspectRatio/maxAspectRatio 設為寬鬆範圍，由自訂邏輯過濾拍立得比例
    /// - 取所有候選中「符合拍立得比例 + 面積最大」的矩形
    /// - Vision 座標系：原點左下角 (y 軸向上) → 需要翻轉 y
    func detectVisionNative(
        image: CGImage,
        imageSize: CGSize
    ) async throws -> DetectionResult {
        let imgW = Double(imageSize.width)
        let imgH = Double(imageSize.height)

        // Vision request 設定（與 Python 版參數一致）
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.10   // 寬鬆，讓所有候選進來再自己過濾
        request.maximumAspectRatio = 0.99
        request.minimumSize        = 0.01   // 最小面積（相對於圖片）
        request.maximumObservations = 20    // 取最多 20 個候選
        request.minimumConfidence  = 0.1

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw VisionError.detectionFailed
        }

        // 篩選：拍立得比例有效 + 最大面積優先
        var best: (corners: [CGPoint], area: Double, confidence: Double)?

        for obs in observations {
            // Vision 座標系：正規化 [0,1]，原點左下 → 翻轉 y
            let pts: [CGPoint] = [
                CGPoint(x: obs.topLeft.x     * imgW, y: (1 - obs.topLeft.y)     * imgH),
                CGPoint(x: obs.topRight.x    * imgW, y: (1 - obs.topRight.y)    * imgH),
                CGPoint(x: obs.bottomRight.x * imgW, y: (1 - obs.bottomRight.y) * imgH),
                CGPoint(x: obs.bottomLeft.x  * imgW, y: (1 - obs.bottomLeft.y)  * imgH),
            ]

            let area = VisionManager.quadArea(pts)

            // 面積過濾：至少佔圖片 3%
            guard area >= 0.03 * imgW * imgH else { continue }

            // 比例過濾
            guard VisionManager.isChekiRatio(pts) else { continue }

            let confidence = Double(obs.confidence)
            if best == nil || area > best!.area {
                best = (pts, area, confidence)
            }
        }

        guard let result = best else {
            throw VisionError.detectionFailed
        }

        // 排序為標準 [TL, TR, BR, BL]
        let ordered = VisionManager.orderPoints(result.corners)

        return DetectionResult(
            corners: ordered,
            method: .visionNative,
            confidence: result.confidence,
            imageSize: imageSize
        )
    }
}
