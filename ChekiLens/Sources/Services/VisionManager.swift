import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision

// MARK: - ChekiFilmFormat

/// 拍立得相紙規格（比例鎖定用）
enum ChekiFilmFormat {
    case mini   // 86×54mm → ratio 1.593
    case square // 86×72mm → ratio 1.194
    case wide   // 108×86mm → ratio 1.256
    case auto   // Vision 偵測後自動判斷

    /// 長邊 / 短邊比
    var aspectRatio: Double {
        switch self {
        case .mini:   return 86.0 / 54.0
        case .square: return 86.0 / 72.0
        case .wide:   return 108.0 / 86.0
        case .auto:   return 0.0
        }
    }
    /// 4K 輸出時的長邊像素（短邊由比例推算）
    static let outputLongEdgePx: Int = 3840
}

// MARK: - DetectionResult

/// Vision 偵測結果
struct DetectionResult {
    /// 四角點（順序：TL, TR, BR, BL），座標為原始像素尺度
    var corners: [CGPoint]      // [topLeft, topRight, bottomRight, bottomLeft]
    var method: DetectionMethodUsed
    var confidence: Double      // 0.0~1.0（Hough 用 score 正規化，Vision 用原生 confidence）
    var imageSize: CGSize
}

enum DetectionMethodUsed: String {
    case hough       = "hough"
    case visionNative = "vision_native"
    case whiteMask   = "white_mask"
    case failed      = "failed"
}

// MARK: - CropResult

/// 透視校正後的輸出
struct CropResult {
    var cgImage: CGImage
    var outputSize: CGSize
    var detectionResult: DetectionResult
}

// MARK: - VisionManager

/// ChekiLens 影像演算法核心
///
/// 執行流程（完全對應 Python cheki_crop.py）：
/// 1. 影像預處理（方向校正、色彩空間正規化）→ Task 2.1
/// 2. 矩形偵測 Layer 1: VNDetectRectanglesRequest → Task 2.2
/// 3. Fallback Layer 2: Hough 直線邊緣偵測 → Task 2.3
/// 4. Fallback Layer 3: HSV 白色輪廓遮罩 → Task 2.3
/// 5. CIPerspectiveCorrection 透視拉直 + 比例鎖定 → Task 2.4
/// 6. borderInsetRatio 邊界微調 → Task 2.5
/// 7. VNRecognizeTextRequest OCR 日期解析 → Task 2.6
actor VisionManager {

    // MARK: - Constants（與 Python 版 cheki_crop.py 保持一致）

    /// 拍立得比例有效範圍（1.20 ~ 1.90 涵蓋 Mini/Square/Wide 全規格）
    static let ratioMin: Double = 1.20
    static let ratioMax: Double = 1.90

    /// Hough 比例窗（放寬至 1.20 ~ 1.90 以容忍透視變形）
    static let houghRatioMin: Double = 1.20
    static let houghRatioMax: Double = 1.90

    /// 四角偵測結果與標準答案的吻合閾值（像素誤差 ≤ 此值視為命中）
    static let cornerAcceptablePixelError: Double = 10.0

    // MARK: - Main API

    /// 完整 Pipeline：載入圖片 → 偵測 → 透視校正 → 輸出
    /// - Parameters:
    ///   - url: 輸入圖片路徑
    ///   - format: 相紙規格（.auto 表示自動判斷）
    ///   - borderInset: 邊界偏移率（-0.03 ~ +0.03）
    func process(
        url: URL,
        format: ChekiFilmFormat = .auto,
        borderInset: Double = 0.0
    ) async throws -> CropResult {
        // Step 1: 載入 + 預處理
        let cgImage = try loadAndPreprocess(url: url)
        let imgSize = CGSize(width: cgImage.width, height: cgImage.height)

        // Step 2-4: 偵測四角（三層 fallback）
        let detection = try await detectQuad(in: cgImage, imageSize: imgSize)

        // Step 5: 邊界偏移微調
        let adjustedCorners = applyBorderInset(
            corners: detection.corners,
            imageSize: imgSize,
            ratio: borderInset
        )

        // Step 6: 透視校正
        let cropResult = try perspectiveCorrect(
            image: cgImage,
            corners: adjustedCorners,
            detection: DetectionResult(
                corners: adjustedCorners,
                method: detection.method,
                confidence: detection.confidence,
                imageSize: imgSize
            ),
            format: format
        )
        return cropResult
    }

    // MARK: - Step 1: 影像預處理

    /// 載入圖片並執行方向校正 + 色彩空間正規化
    ///
    /// 對應 Python：`cv2.imread` + EXIF 方向處理
    /// - 修正 EXIF Orientation（防止 CGImage 預設忽略旋轉 metadata）
    /// - 強制輸出為 sRGB 色彩空間（Vision 框架的最佳輸入格式）
    func loadAndPreprocess(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw VisionError.imageLoadFailed(url.lastPathComponent)
        }

        // 讀取 EXIF orientation
        let orientation = imageOrientation(from: source)

        // 套用方向校正（使用 CIImage + CIContext）
        let ciImage = CIImage(cgImage: rawImage)
            .oriented(orientation)

        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let corrected = ctx.createCGImage(ciImage, from: ciImage.extent) else {
            throw VisionError.preprocessFailed
        }
        return corrected
    }

    /// 從 CGImageSource 讀取 EXIF Orientation
    private func imageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientRaw = (props[kCGImagePropertyOrientation] as? UInt32) else {
            return .up
        }
        return CGImagePropertyOrientation(rawValue: orientRaw) ?? .up
    }

    // MARK: - Step 2-4: 偵測四角（三層 fallback）

    func detectQuad(in image: CGImage, imageSize: CGSize) async throws -> DetectionResult {
        // Layer 1: Apple Vision (最優先，機器學習精度高、速度極快 ~50ms)
        if let result = try? await detectVisionNative(image: image, imageSize: imageSize) {
            // Check if Vision output is suspicious (e.g. inner photo ratio).
            let r = VisionManager.quadAspectRatio(result.corners)
            // If the ratio is < 1.50, it is likely the inner photo or distorted.
            // Fallback to Layer 2 Hough for accurate outer frame detection!
            if r >= 1.50 {
                return result
            }
        }
        
        // Layer 2: Hough-based（Python 原版主力，精確邊緣對齊，速度較慢 ~5s）
        if let result = try? detectHough(image: image, imageSize: imageSize) {
            return result
        }
        
        // Layer 3: White mask contour
        if let result = try? detectWhiteMask(image: image, imageSize: imageSize) {
            return result
        }

        throw VisionError.detectionFailed
    }

    // MARK: - Geometry Helpers

    /// 四角點排列為 [TL, TR, BR, BL]（對應 Python order_points）
    static func orderPoints(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count == 4 else { return pts }
        // sum 最小為 TL，最大為 BR；diff = y-x 最小為 TR，最大為 BL
        let sorted = pts.sorted { $0.x + $0.y < $1.x + $1.y }
        let tl = sorted.first!
        let br = sorted.last!
        let remaining = pts.filter { $0 != tl && $0 != br }
        let tr = remaining.min(by: { $0.y - $0.x < $1.y - $1.x })!
        let bl = remaining.max(by: { $0.y - $0.x < $1.y - $1.x })!
        return [tl, tr, br, bl]
    }

    /// 長短邊比（用於比例有效性驗證）
    static func quadAspectRatio(_ pts: [CGPoint]) -> Double {
        let ordered = orderPoints(pts)
        let tl = ordered[0], tr = ordered[1], bl = ordered[3]
        let w = hypot(tr.x - tl.x, tr.y - tl.y)
        let h = hypot(bl.x - tl.x, bl.y - tl.y)
        let longer = max(w, h), shorter = min(w, h)
        guard shorter > 0 else { return 0 }
        return Double(longer / shorter)
    }

    /// 是否落在拍立得有效比例範圍
    static func isChekiRatio(_ pts: [CGPoint]) -> Bool {
        let r = quadAspectRatio(pts)
        return ratioMin <= r && r <= ratioMax
    }

    /// 四邊形面積（Shoelace 公式）
    static func quadArea(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var area: Double = 0
        let n = pts.count
        for i in 0..<n {
            let j = (i + 1) % n
            area += Double(pts[i].x * pts[j].y)
            area -= Double(pts[j].x * pts[i].y)
        }
        return abs(area) / 2.0
    }

    // MARK: - Border Inset (Task 2.5)

    /// 四角点を中心基準でスケール（正値=外側拡張、負値=内側収縮）
    ///
    /// 対応 Python：`borderInsetRatio` の Inset / Outset 機能
    /// - ratio > 0（Outset, +1~+3%）：外縁まで確実に保留
    /// - ratio < 0（Inset,  -1~-3%）：背景陰影を除去
    func applyBorderInset(
        corners: [CGPoint],
        imageSize: CGSize,
        ratio: Double
    ) -> [CGPoint] {
        guard abs(ratio) > 1e-6 else { return corners }

        // 四角形の重心
        let cx = corners.map { Double($0.x) }.reduce(0, +) / Double(corners.count)
        let cy = corners.map { Double($0.y) }.reduce(0, +) / Double(corners.count)

        // 各点を重心から (1 + ratio) 倍にスケール
        // ratio が正 → 各点が重心から遠ざかる（外側へ拡張）
        // ratio が負 → 各点が重心へ近づく（内側へ収縮）
        let scale = 1.0 + ratio
        return corners.map { pt in
            let nx = cx + (Double(pt.x) - cx) * scale
            let ny = cy + (Double(pt.y) - cy) * scale
            // 画像範囲内にクランプ
            let clampedX = max(0, min(Double(imageSize.width),  nx))
            let clampedY = max(0, min(Double(imageSize.height), ny))
            return CGPoint(x: clampedX, y: clampedY)
        }
    }

}

// MARK: - VisionError

enum VisionError: LocalizedError {
    case imageLoadFailed(String)
    case preprocessFailed
    case detectionFailed
    case perspectiveCorrectionFailed

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let name): return "無法載入圖片：\(name)"
        case .preprocessFailed:         return "影像預處理失敗"
        case .detectionFailed:          return "三層偵測均失敗，無法找到拍立得邊框"
        case .perspectiveCorrectionFailed: return "透視校正失敗"
        }
    }
}
