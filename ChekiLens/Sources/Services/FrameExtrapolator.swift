import Foundation
import CoreGraphics

// MARK: - ExtrapolationResult

/// 內框反推外框分析結果
struct ExtrapolationResult: Sendable, Equatable {
    let isInnerFrame: Bool
    let detectedFormat: ChekiFilmFormat
    let originalCorners: [CGPoint]
    let extrapolatedCorners: [CGPoint]
    let confidence: Double
}

// MARK: - FrameExtrapolator

/// 拍立得白邊感知與內框反推外框模組 (Task 2.8.2)
/// 當 Apple 原生 Vision 誤將高對比的「內部照片畫面」判定為整張卡片時，
/// 依據富士底片嚴格的工業標準物理比例（內框面積佔 ~60%、長寬比 ~1.348），
/// 自動將 4 個頂點外彈還原回真正的拍立得外框四角。
///
/// 徹底解決 DSCF3716、IMG_7280、DSCF0041 等內部畫面誤判導致白邊被切除之問題。
enum FrameExtrapolator {

    /// 檢驗檢測到的四邊形是否為拍立得內部相片畫面，若是則自動外彈還原外框四角
    static func checkAndExtrapolate(
        corners: [CGPoint],
        imageSize: CGSize
    ) -> ExtrapolationResult {
        let ordered = VisionManager.orderPoints(corners)
        guard ordered.count == 4 else {
            return ExtrapolationResult(
                isInnerFrame: false,
                detectedFormat: .mini,
                originalCorners: corners,
                extrapolatedCorners: corners,
                confidence: 0.0
            )
        }

        let tl = ordered[0]
        let tr = ordered[1]
        let br = ordered[2]
        let bl = ordered[3]

        let topW = hypot(tr.x - tl.x, tr.y - tl.y)
        let bottomW = hypot(br.x - bl.x, br.y - bl.y)
        let leftH = hypot(bl.x - tl.x, bl.y - tl.y)
        let rightH = hypot(br.x - tr.x, br.y - tr.y)

        let avgW = Double((topW + bottomW) / 2.0)
        let avgH = Double((leftH + rightH) / 2.0)

        guard avgW > 1.0 && avgH > 1.0 else {
            return ExtrapolationResult(
                isInnerFrame: false,
                detectedFormat: .mini,
                originalCorners: corners,
                extrapolatedCorners: corners,
                confidence: 0.0
            )
        }

        let isPortrait = avgH >= avgW
        let longShortRatio = max(avgW, avgH) / min(avgW, avgH)

        // 判定是否符合拍立得內部相片的幾何特徵：
        // 1. Instax Mini 內框：46mm × 62mm，長短比 62/46 ≈ 1.348 (容許 1.28 ~ 1.45)
        // 2. Instax Square 內框：62mm × 62mm，長短比 1.000 (容許 0.95 ~ 1.05)
        
        var isInner = false
        var targetFormat: ChekiFilmFormat = .mini
        var sideRatio = 0.0
        var topRatio = 0.0
        var chinRatio = 0.0
        var confidence = 0.0

        if isPortrait {
            if longShortRatio >= 1.28 && longShortRatio <= 1.45 {
                // Mini 縱向內框
                isInner = true
                targetFormat = .mini
                sideRatio = 4.0 / 46.0   // 左右白邊各 4mm
                topRatio = 5.0 / 62.0    // 上白邊 5mm
                chinRatio = 19.0 / 62.0  // 下巴白邊 19mm
                confidence = max(0.5, 1.0 - abs(longShortRatio - 1.348) * 2.0)
            } else if longShortRatio >= 0.95 && longShortRatio <= 1.06 {
                // Square 縱向內框
                isInner = true
                targetFormat = .square
                sideRatio = 5.0 / 62.0   // 左右各 5mm
                topRatio = 5.0 / 62.0    // 上邊 5mm
                chinRatio = 19.0 / 62.0  // 下巴 19mm
                confidence = max(0.5, 1.0 - abs(longShortRatio - 1.0) * 4.0)
            }
        } else {
            if longShortRatio >= 1.28 && longShortRatio <= 1.45 {
                // Mini 橫向內框
                isInner = true
                targetFormat = .mini
                // 橫向時長短邊角色互換
                sideRatio = 19.0 / 62.0 // 下巴在左或右
                topRatio = 4.0 / 46.0
                chinRatio = 4.0 / 46.0
                confidence = 0.8
            }
        }

        guard isInner else {
            return ExtrapolationResult(
                isInnerFrame: false,
                detectedFormat: targetFormat,
                originalCorners: ordered,
                extrapolatedCorners: ordered,
                confidence: 0.0
            )
        }

        // 向量外彈計算
        let uTop = CGPoint(x: tr.x - tl.x, y: tr.y - tl.y)
        let uBot = CGPoint(x: br.x - bl.x, y: br.y - bl.y)
        let vLeft = CGPoint(x: bl.x - tl.x, y: bl.y - tl.y)
        let vRight = CGPoint(x: br.x - tr.x, y: br.y - tr.y)

        // 1. 左右兩邊向外推
        let tlOut = CGPoint(x: tl.x - sideRatio * uTop.x, y: tl.y - sideRatio * uTop.y)
        let blOut = CGPoint(x: bl.x - sideRatio * uBot.x, y: bl.y - sideRatio * uBot.y)
        let trOut = CGPoint(x: tr.x + sideRatio * uTop.x, y: tr.y + sideRatio * uTop.y)
        let brOut = CGPoint(x: br.x + sideRatio * uBot.x, y: br.y + sideRatio * uBot.y)

        // 2. 上下兩邊向外推
        // 評估下巴方向：通常下巴在下方，但若下方空間不足且上方空間充裕，翻轉方向
        let chinAtBottom = (blOut.y + chinRatio * vLeft.y <= imageSize.height + 50.0)
        let actualTopRatio = chinAtBottom ? topRatio : chinRatio
        let actualBotRatio = chinAtBottom ? chinRatio : topRatio

        let tlFinal = CGPoint(x: tlOut.x - actualTopRatio * vLeft.x, y: tlOut.y - actualTopRatio * vLeft.y)
        let trFinal = CGPoint(x: trOut.x - actualTopRatio * vRight.x, y: trOut.y - actualTopRatio * vRight.y)
        let blFinal = CGPoint(x: blOut.x + actualBotRatio * vLeft.x, y: blOut.y + actualBotRatio * vLeft.y)
        let brFinal = CGPoint(x: brOut.x + actualBotRatio * vRight.x, y: brOut.y + actualBotRatio * vRight.y)

        func clamp(_ pt: CGPoint) -> CGPoint {
            CGPoint(
                x: max(0.0, min(imageSize.width, pt.x)),
                y: max(0.0, min(imageSize.height, pt.y))
            )
        }

        let extrapolated = [clamp(tlFinal), clamp(trFinal), clamp(brFinal), clamp(blFinal)]

        return ExtrapolationResult(
            isInnerFrame: true,
            detectedFormat: targetFormat,
            originalCorners: ordered,
            extrapolatedCorners: extrapolated,
            confidence: confidence
        )
    }
}
