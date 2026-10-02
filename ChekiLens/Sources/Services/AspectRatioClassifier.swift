import Foundation
import CoreGraphics

// MARK: - ChekiOrientation

/// 拍立得拍攝方向
enum ChekiOrientation: String, Sendable, Codable {
    case portrait  // 縱向 (H >= W)
    case landscape // 橫向 (W > H)
}

// MARK: - FilmSpecification

/// 拍立得規格識別結果
struct FilmSpecification: Sendable, Equatable {
    let format: ChekiFilmFormat
    let orientation: ChekiOrientation
    /// 寬度 / 高度 (像素比)
    let targetAspectRatio: Double
    /// 標準輸出解析度 (以長邊 3840px 4K 為基準，短邊以物理比例推算)
    let standardOutputSize: CGSize
    let confidence: Double
    
    init(
        format: ChekiFilmFormat,
        orientation: ChekiOrientation,
        targetAspectRatio: Double,
        standardOutputSize: CGSize,
        confidence: Double = 1.0
    ) {
        self.format = format
        self.orientation = orientation
        self.targetAspectRatio = targetAspectRatio
        self.standardOutputSize = standardOutputSize
        self.confidence = confidence
    }
}

// MARK: - AspectRatioClassifier

/// 拍立得底片規格與方向分類器 (Task 2.8.1)
/// 依據透視校正前的四角頂點座標或外框幾何，自動判別：
/// 1. Instax Mini (直向 54×86, 橫向 86×54)
/// 2. Instax Square (直向 72×86, 橫向 86×72)
/// 3. Instax Wide (橫向 108×86, 直向 86×108)
///
/// 徹底解決橫向拍攝 (如 DSCF2190) 或 Wide 格式 (如 IMG_1886) 被強制拉伸變形為直式 Mini 的問題。
enum AspectRatioClassifier {

    /// 根據 4 個角點 [TL, TR, BR, BL] 精準分類規格與方向
    static func classify(corners: [CGPoint], requestedFormat: ChekiFilmFormat = .auto) -> FilmSpecification {
        let ordered = VisionManager.orderPoints(corners)
        guard ordered.count == 4 else {
            return defaultSpecification(requestedFormat: requestedFormat)
        }
        
        let tl = ordered[0]
        let tr = ordered[1]
        let br = ordered[2]
        let bl = ordered[3]
        
        // 邊長計算
        let topW = hypot(tr.x - tl.x, tr.y - tl.y)
        let bottomW = hypot(br.x - bl.x, br.y - bl.y)
        let leftH = hypot(bl.x - tl.x, bl.y - tl.y)
        let rightH = hypot(br.x - tr.x, br.y - tr.y)
        
        let avgW = Double((topW + bottomW) / 2.0)
        let avgH = Double((leftH + rightH) / 2.0)
        
        guard avgW > 1.0 && avgH > 1.0 else {
            return defaultSpecification(requestedFormat: requestedFormat)
        }
        
        // 判定方向：寬度大於高度即為橫向
        let isLandscape = avgW > avgH
        let orientation: ChekiOrientation = isLandscape ? .landscape : .portrait
        
        // 長邊 / 短邊 比率 (恆 >= 1.0)
        let longShortRatio = max(avgW, avgH) / min(avgW, avgH)
        
        // 若使用者有指定非 .auto 的格式，尊重其格式，但仍自動判定橫豎方向
        if requestedFormat != .auto {
            return specification(for: requestedFormat, orientation: orientation, confidence: 1.0)
        }
        
        // 自動判定邏輯：
        // Mini 比率: 86.0 / 54.0 ≈ 1.593
        // Wide 比率: 108.0 / 86.0 ≈ 1.256
        // Square 比率: 86.0 / 72.0 ≈ 1.194
        
        let detectedFormat: ChekiFilmFormat
        let confidence: Double
        
        if isLandscape {
            // 橫向拍攝：
            // 若長短比 >= 1.42，幾乎必定為 Instax Mini 橫向 (如 DSCF2190, ratio ~ 1.59)
            // 若長短比 < 1.42，預設判定為 Wide (108x86mm, ratio 1.256)
            if longShortRatio >= 1.42 {
                detectedFormat = .mini
                confidence = min(1.0, 1.0 - abs(longShortRatio - (86.0 / 54.0)) * 0.5)
            } else {
                detectedFormat = .wide
                confidence = min(1.0, 1.0 - abs(longShortRatio - (108.0 / 86.0)) * 0.5)
            }
        } else {
            // 直向拍攝：
            // 若長短比 >= 1.38，判定為 Instax Mini 直向 (標準拍立得)
            if longShortRatio >= 1.38 {
                detectedFormat = .mini
                confidence = min(1.0, 1.0 - abs(longShortRatio - (86.0 / 54.0)) * 0.5)
            } else if longShortRatio <= 1.22 {
                // Square 原生直向卡片 (72x86mm, ratio 1.194)
                detectedFormat = .square
                confidence = min(1.0, 1.0 - abs(longShortRatio - (86.0 / 72.0)) * 0.5)
            } else {
                // 介於 1.22 ~ 1.38 之間，選最接近的
                let distSquare = abs(longShortRatio - (86.0 / 72.0))
                let distWide = abs(longShortRatio - (108.0 / 86.0))
                detectedFormat = distSquare < distWide ? .square : .wide
                confidence = 0.8
            }
        }
        
        return specification(for: detectedFormat, orientation: orientation, confidence: max(0.1, confidence))
    }
    
    /// 依據規格與方向生成輸出規格與像素尺寸
    static func specification(
        for format: ChekiFilmFormat,
        orientation: ChekiOrientation,
        confidence: Double = 1.0
    ) -> FilmSpecification {
        let longEdge = Double(ChekiFilmFormat.outputLongEdgePx) // 3840
        
        switch (format, orientation) {
        case (.mini, .portrait):
            // 縱向 Mini: 54mm × 86mm
            let targetRatio = 54.0 / 86.0 // ≈ 0.6279
            let w = round(longEdge * targetRatio)
            let h = longEdge
            return FilmSpecification(
                format: .mini,
                orientation: .portrait,
                targetAspectRatio: targetRatio,
                standardOutputSize: CGSize(width: w, height: h),
                confidence: confidence
            )
            
        case (.mini, .landscape):
            // 橫向 Mini: 86mm × 54mm (解決 DSCF2190 變形問題)
            let targetRatio = 86.0 / 54.0 // ≈ 1.5926
            let w = longEdge
            let h = round(longEdge / targetRatio)
            return FilmSpecification(
                format: .mini,
                orientation: .landscape,
                targetAspectRatio: targetRatio,
                standardOutputSize: CGSize(width: w, height: h),
                confidence: confidence
            )
            
        case (.square, .portrait):
            // 縱向 Square: 72mm × 86mm
            let targetRatio = 72.0 / 86.0 // ≈ 0.8372
            let w = round(longEdge * targetRatio)
            let h = longEdge
            return FilmSpecification(
                format: .square,
                orientation: .portrait,
                targetAspectRatio: targetRatio,
                standardOutputSize: CGSize(width: w, height: h),
                confidence: confidence
            )
            
        case (.square, .landscape):
            // 橫向 Square: 86mm × 72mm
            let targetRatio = 86.0 / 72.0 // ≈ 1.1944
            let w = longEdge
            let h = round(longEdge / targetRatio)
            return FilmSpecification(
                format: .square,
                orientation: .landscape,
                targetAspectRatio: targetRatio,
                standardOutputSize: CGSize(width: w, height: h),
                confidence: confidence
            )
            
        case (.wide, .landscape):
            // 橫向 Wide: 108mm × 86mm (解決 IMG_1886 變形問題)
            let targetRatio = 108.0 / 86.0 // ≈ 1.2558
            let w = longEdge
            let h = round(longEdge / targetRatio)
            return FilmSpecification(
                format: .wide,
                orientation: .landscape,
                targetAspectRatio: targetRatio,
                standardOutputSize: CGSize(width: w, height: h),
                confidence: confidence
            )
            
        case (.wide, .portrait):
            // 縱向 Wide (豎拿拍攝)
            let targetRatio = 86.0 / 108.0 // ≈ 0.7963
            let w = round(longEdge * targetRatio)
            let h = longEdge
            return FilmSpecification(
                format: .wide,
                orientation: .portrait,
                targetAspectRatio: targetRatio,
                standardOutputSize: CGSize(width: w, height: h),
                confidence: confidence
            )
            
        case (.auto, _):
            return specification(for: .mini, orientation: orientation, confidence: confidence)
        }
    }
    
    private static func defaultSpecification(requestedFormat: ChekiFilmFormat) -> FilmSpecification {
        let fmt = (requestedFormat == .auto) ? .mini : requestedFormat
        return specification(for: fmt, orientation: .portrait, confidence: 0.5)
    }
}
