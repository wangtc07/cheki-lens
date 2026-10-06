import Foundation
import CoreImage
import CoreGraphics
import Vision

// MARK: - VisionManager + Layer 1 (VNDetectRectanglesRequest)

extension VisionManager {

    // MARK: - Vision Native Detection (Two-Pass Query & Anti-Regression Scoring)

    /// 第一層偵測：Apple Vision ML 矩形識別 (Task 2.9.1 雙階段過濾升級)
    ///
    /// 升級策略：
    /// 1. Pass 1 (黃金比例窗)：設定 minimumAspectRatio = 0.45, maximumAspectRatio = 1.00,
    ///    minimumSize = 0.15, maximumObservations = 5，精確鎖定標準直式拍立得 (Mini 0.628, Square 0.837, Wide 0.796)，
    ///    徹底消除 IMG_7882 被 20 個碎雜訊文字條擠爆緩衝區的問題。
    /// 2. Pass 2 (廣角/橫向窗備援)：若 Pass 1 無候選，放寬至 minimumAspectRatio = 0.20 支援極端橫向或視角透視變形。
    /// 3. 規格吻合度與面積加權評分 (Score = Area * FormatMatch * Confidence)：
    ///    優先挑選與拍立得真實規格 (Mini/Square/Wide) 契合且面積最大者，杜絕 IMG_3491 誤抓 29% 局域反光導致截半之回退。
    func detectVisionNative(
        image: CGImage,
        imageSize: CGSize
    ) async throws -> DetectionResult {
        let imgW = Double(imageSize.width)
        let imgH = Double(imageSize.height)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Pass 1: 拍立得標準黃金比例窗聚焦搜尋
        let req1 = VNDetectRectanglesRequest()
        req1.minimumAspectRatio = 0.45
        req1.maximumAspectRatio = 1.00
        req1.minimumSize        = 0.15   // 排除佔比小於 15% 的零碎文字雜訊條
        req1.maximumObservations = 5     // 僅取前 5 大顯著矩形
        req1.minimumConfidence  = 0.25

        try handler.perform([req1])

        var observations = req1.results ?? []

        // Pass 2: 若黃金比例窗未命中，啟動廣角與橫向寬鬆搜尋
        if observations.isEmpty {
            let req2 = VNDetectRectanglesRequest()
            req2.minimumAspectRatio = 0.20
            req2.maximumAspectRatio = 1.00
            req2.minimumSize        = 0.05
            req2.maximumObservations = 10
            req2.minimumConfidence  = 0.15

            try handler.perform([req2])
            observations = req2.results ?? []
        }

        guard !observations.isEmpty else {
            throw VisionError.detectionFailed
        }

        // 綜合評分篩選：面積佔比 * 規格吻合度 * 信心度
        var best: (corners: [CGPoint], area: Double, confidence: Double, score: Double)?

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

            // 拍立得比例範圍驗證
            guard VisionManager.isChekiRatio(pts) else { continue }

            let ratio = VisionManager.quadAspectRatio(pts)

            // 與三大工業標準拍立得長短邊比例 (Mini 1.593, Square 1.194, Wide 1.256) 的最小距離
            let miniDist = abs(ratio - (86.0 / 54.0))
            let squareDist = abs(ratio - (86.0 / 72.0))
            let wideDist = abs(ratio - (108.0 / 86.0))
            let minDist = min(miniDist, min(squareDist, wideDist))

            // 規格契合度權重 (0.5 ~ 1.0)
            let formatMatch = max(0.5, 1.0 - minDist * 0.8)

            let confidence = Double(obs.confidence)
            let score = area * formatMatch * confidence

            if best == nil || score > best!.score {
                best = (pts, area, confidence, score)
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
