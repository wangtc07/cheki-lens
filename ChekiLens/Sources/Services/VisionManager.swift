import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision

// MARK: - ChekiFilmFormat

/// 拍立得相紙規格（比例鎖定用）
nonisolated enum ChekiFilmFormat: String, Sendable {
    case mini   = "mini"   // 86×54mm → ratio 1.593
    case square = "square" // 86×72mm → ratio 1.194
    case wide   = "wide"   // 108×86mm → ratio 1.256
    case auto   = "auto"   // Vision 偵測後自動判斷

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
nonisolated struct DetectionResult: Sendable {
    /// 四角點（順序：TL, TR, BR, BL），座標為原始像素尺度
    var corners: [CGPoint]      // [topLeft, topRight, bottomRight, bottomLeft]
    var method: DetectionMethodUsed
    var confidence: Double      // 0.0~1.0（Hough 用 score 正規化，Vision 用原生 confidence）
    var imageSize: CGSize
}

nonisolated enum DetectionMethodUsed: String, Sendable {
    case hough       = "hough"
    case visionNative = "vision_native"
    case whiteMask   = "white_mask"
    case visionCoreML = "coreml"
    case failed      = "failed"
}

// MARK: - CropResult

/// 透視校正後的輸出
nonisolated struct CropResult: Sendable {
    var cgImage: CGImage
    var outputSize: CGSize
    var detectionResult: DetectionResult
    var filmSpecification: FilmSpecification? = nil
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
        let ciCtx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        
// --- Layer 0: 背面專用 OCR 優先判定 ---
        // 拍立得背面完全沒有邊界，傳統 AI 容易誤判。
        // 我們直接先用極速的 OCR 掃描，如果有找到 instax 等字樣，代表這「絕對是背面」，直接反推座標，略過 AI。
        if let ocrRes = try? await detectBacksideCorners(in: image, imageSize: imageSize) {
            return ocrRes
        }
        
        // --- Layer 1: Apple Vision Native & CIDetector ---
        var vRes: DetectionResult? = nil
        do {
            vRes = try await detectVisionNative(image: image, imageSize: imageSize)
        } catch {}
        
        // --- Layer 1.5: CIDetector (Classic CV) ---
        var cRes: DetectionResult? = nil
        if let ciImage = CIImage(cgImage: image).copy() as? CIImage {
            let detector = CIDetector(ofType: CIDetectorTypeRectangle, context: ciCtx, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            if let features = detector?.features(in: ciImage) as? [CIRectangleFeature] {
                var bestCArea = 0.0
                var bestCPts: [CGPoint]? = nil
                
                let iW = Double(imageSize.width)
                let iH = Double(imageSize.height)
                
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
                    cRes = DetectionResult(
                        corners: VisionManager.orderPoints(pts),
                        method: .visionNative,
                        confidence: 1.0,
                        imageSize: imageSize
                    )
                }
            }
        }
        
        // Combine Layer 1 and 1.5: Pick the one with the largest area
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
        
        if var best = bestNative {
            // Task 2.9.2: 檢查是否誤抓內部相片 (FrameExtrapolator 反推外框 + 外環色彩反差門檻防護)
            let extraRes = FrameExtrapolator.checkAndExtrapolate(corners: best.corners, imageSize: imageSize, image: image)
            if extraRes.isInnerFrame {
                best.corners = extraRes.extrapolatedCorners
                // Task 2.9.4.1: 外彈後執行 1D 直線擬合微調，對齊真實外框邊界 (修復 DSCF0041 2 右上頂點下墜)
                let refRes = VisionManager.refineQuadrilateral(corners: best.corners, imageSize: imageSize, image: image)
                if refRes.wasRefined {
                    best.corners = refRes.corners
                }
                return best
            } else {
                // Task 2.9.3: 四邊垂直平行驗證、單點漂移正交推導與 1D Sobel 梯度邊緣吸附
                let refRes = VisionManager.refineQuadrilateral(corners: best.corners, imageSize: imageSize, image: image)
                if refRes.wasRefined {
                    best.corners = refRes.corners
                }
                
                // 針對滿版塗鴉跨邊 (DSCF0029, DSCF0073, DSCF0012)：
                // 若 Vision 因彩繪/麥克筆跨邊斷裂僅抓到局部碎片 (< 20% 面積) 或殘留嚴重梯形歪斜 (> 14° 且單點推導無法修復)，
                // 啟動四周外框 25 射線 RANSAC 直線擬合重構完整相紙外框
                let canvasArea = Double(imageSize.width * imageSize.height)
                let bestAreaPct = canvasArea > 0 ? (VisionManager.quadArea(best.corners) / canvasArea) : 0.0
                let isBogusFragmentOrSkew = bestAreaPct < 0.20 ||
                    ((refRes.horizontalSkewAngle > 14.0 || refRes.verticalSkewAngle > 14.0) && !refRes.wasRefined)
                if isBogusFragmentOrSkew,
                   let outerCorners = VisionManager.detectOuterPerimeterQuad(in: image, imageSize: imageSize) {
                    best.corners = outerCorners
                    return best
                }
                
                let r = VisionManager.quadAspectRatio(best.corners)
                if r >= 1.15 { // 涵蓋 Square (1.19), Wide (1.26), Mini (1.59)
                    return best
                }
            }
        }
        
        // 若 Layer 1 / 1.5 完全未命中，優先嘗試外框射線 RANSAC 擬合（支援滿版彩繪近拍）
        if let outerCorners = VisionManager.detectOuterPerimeterQuad(in: image, imageSize: imageSize) {
            return DetectionResult(
                corners: outerCorners,
                method: .visionNative,
                confidence: 0.92,
                imageSize: imageSize
            )
        }
        
        // --- Layer 1.8: Task 2.8.5 YOLO11-Pose Fallback 兜底機制 ---
        // 針對滿版彩繪 (DSCF0025.JPG) 或極端反光漏抓，由物件級神經網路全圖兜底重判
        if let fallbackRes = try? await detectFallbackPose(image: image, imageSize: imageSize) {
            return fallbackRes
        }
        
        // --- Layer 2: Hough Transform Fallback ---
        if let hRes = try? detectHough(image: image, imageSize: imageSize) {
            return hRes
        }
        
        // --- Layer 3: White Mask Fallback ---
        return try detectWhiteMask(image: image, imageSize: imageSize)
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
        let tl = ordered[0], tr = ordered[1], br = ordered[2], bl = ordered[3]
        
        let wTop = hypot(tr.x - tl.x, tr.y - tl.y)
        let wBot = hypot(br.x - bl.x, br.y - bl.y)
        let hLeft = hypot(bl.x - tl.x, bl.y - tl.y)
        let hRight = hypot(br.x - tr.x, br.y - tr.y)
        
        let w = (wTop + wBot) / 2.0
        let h = (hLeft + hRight) / 2.0
        
        let longer = max(w, h)
        let shorter = min(w, h)
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
        let minX = -Double(imageSize.width) * 0.45
        let maxX = Double(imageSize.width) * 1.45
        let minY = -Double(imageSize.height) * 0.45
        let maxY = Double(imageSize.height) * 1.45
        return corners.map { pt in
            let nx = cx + (Double(pt.x) - cx) * scale
            let ny = cy + (Double(pt.y) - cy) * scale
            let clampedX = max(minX, min(maxX, nx))
            let clampedY = max(minY, min(maxY, ny))
            return CGPoint(x: clampedX, y: clampedY)
        }
    }

}

// MARK: - VisionError

nonisolated enum VisionError: LocalizedError {
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
