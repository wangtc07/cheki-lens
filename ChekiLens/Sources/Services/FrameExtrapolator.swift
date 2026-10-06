import Foundation
import CoreGraphics

// MARK: - ExtrapolationResult

/// 內框反推外框分析結果
nonisolated struct ExtrapolationResult: Sendable, Equatable {
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
nonisolated enum FrameExtrapolator {

    /// 讀取 CGImage 指定座標之灰階亮度 (0~255)
    static func sampleLuminance(in image: CGImage, at pt: CGPoint) -> Double {
        let x = max(0, min(image.width - 1, Int(pt.x)))
        let y = max(0, min(image.height - 1, Int(pt.y)))
        
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 128.0 }
        
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return 128.0 }
        
        let offset = y * bytesPerRow + x * bytesPerPixel
        let r = Double(ptr[offset])
        let g = Double(ptr[offset + 1])
        let b = Double(ptr[offset + 2])
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// 外緣色彩反差檢驗 (Outer Ring Contrast Gate - Task 2.9.2)
    /// 若候選框有 2 邊以上的外側皆為暗色背景 (亮度 < 75)，表示其已為外框，嚴禁向外彈出黑底。
    static func checkOuterContrast(image: CGImage, corners: [CGPoint]) -> Bool {
        let tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3]
        let midTop = CGPoint(x: (tl.x + tr.x)/2.0, y: (tl.y + tr.y)/2.0)
        let midBot = CGPoint(x: (bl.x + br.x)/2.0, y: (bl.y + br.y)/2.0)
        let midLeft = CGPoint(x: (tl.x + bl.x)/2.0, y: (tl.y + bl.y)/2.0)
        let midRight = CGPoint(x: (tr.x + br.x)/2.0, y: (tr.y + br.y)/2.0)
        
        let hDist = hypot(midBot.x - midTop.x, midBot.y - midTop.y)
        let wDist = hypot(midRight.x - midLeft.x, midRight.y - midLeft.y)
        guard hDist > 10 && wDist > 10 else { return false }
        
        let vDown = CGPoint(x: (midBot.x - midTop.x)/hDist, y: (midBot.y - midTop.y)/hDist)
        let vRight = CGPoint(x: (midRight.x - midLeft.x)/wDist, y: (midRight.y - midLeft.y)/wDist)
        
        let d = min(35.0, min(wDist, hDist) * 0.08)
        
        let outTop = CGPoint(x: midTop.x - vDown.x * d, y: midTop.y - vDown.y * d)
        let outBot = CGPoint(x: midBot.x + vDown.x * d, y: midBot.y + vDown.y * d)
        let outLeft = CGPoint(x: midLeft.x - vRight.x * d, y: midLeft.y - vRight.y * d)
        let outRight = CGPoint(x: midRight.x + vRight.x * d, y: midRight.y + vRight.y * d)
        
        let lumTop = sampleLuminance(in: image, at: outTop)
        let lumBot = sampleLuminance(in: image, at: outBot)
        let lumLeft = sampleLuminance(in: image, at: outLeft)
        let lumRight = sampleLuminance(in: image, at: outRight)
        
        var darkOuterCount = 0
        if lumTop < 75.0 { darkOuterCount += 1 }
        if lumBot < 75.0 { darkOuterCount += 1 }
        if lumLeft < 75.0 { darkOuterCount += 1 }
        if lumRight < 75.0 { darkOuterCount += 1 }
        
        // 若外圍多側為暗底桌面，則絕對不是內部相片
        return darkOuterCount < 2
    }

    /// 檢驗檢測到的四邊形是否為拍立得內部相片畫面，若是則自動外彈還原外框四角
    static func checkAndExtrapolate(
        corners: [CGPoint],
        imageSize: CGSize,
        image: CGImage? = nil
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

        let topW = Double(hypot(tr.x - tl.x, tr.y - tl.y))
        let bottomW = Double(hypot(br.x - bl.x, br.y - bl.y))
        let leftH = Double(hypot(bl.x - tl.x, bl.y - tl.y))
        let rightH = Double(hypot(br.x - tr.x, br.y - tr.y))

        let avgW = (topW + bottomW) / 2.0
        let avgH = (leftH + rightH) / 2.0

        guard avgW > 1.0 && avgH > 1.0 else {
            return ExtrapolationResult(
                isInnerFrame: false,
                detectedFormat: .mini,
                originalCorners: corners,
                extrapolatedCorners: corners,
                confidence: 0.0
            )
        }

        // 面積約束：內部相片面積絕不可能超過畫布的 65%
        let quadArea = VisionManager.quadArea(ordered)
        let canvasArea = Double(imageSize.width * imageSize.height)
        if quadArea > 0.65 * canvasArea {
            return ExtrapolationResult(
                isInnerFrame: false,
                detectedFormat: .mini,
                originalCorners: ordered,
                extrapolatedCorners: ordered,
                confidence: 0.0
            )
        }

        let isPortrait = avgH >= avgW
        let longShortRatio = max(avgW, avgH) / min(avgW, avgH)

        // 判定是否符合拍立得內部相片的緊緻幾何特徵：
        // 1. Instax Mini 內框：46mm × 62mm，長短比 62/46 ≈ 1.348 (精確收窄至 1.29 ~ 1.385，排除 1.39 與 1.41 外框誤傷)
        // 2. Instax Square 內框：62mm × 62mm，長短比 1.000 (精確收窄至 0.96 ~ 1.05)
        var isInner = false
        var targetFormat: ChekiFilmFormat = .mini
        var confidence = 0.0

        if isPortrait {
            // 直向拍攝：Mini 內框物理比為 1.348，考量透視短縮可放寬至 1.20 ~ 1.385 (完全不會影響橫向 Wide，因 Wide 是 landscape)
            if longShortRatio >= 1.20 && longShortRatio <= 1.385 {
                isInner = true
                targetFormat = .mini
                confidence = max(0.6, 1.0 - abs(longShortRatio - 1.348) * 3.0)
            }
        } else {
            // 橫向拍攝：Mini 橫向內框精確鎖定 1.29 ~ 1.385，避免誤傷橫向 Wide (1.256)
            if longShortRatio >= 1.29 && longShortRatio <= 1.385 {
                isInner = true
                targetFormat = .mini
                confidence = max(0.6, 1.0 - abs(longShortRatio - 1.348) * 3.0)
            }
        }
        
        if !isInner && longShortRatio >= 0.96 && longShortRatio <= 1.05 {
            isInner = true
            targetFormat = .square
            confidence = max(0.6, 1.0 - abs(longShortRatio - 1.0) * 4.0)
        }

        // 若有傳入影像，執行外環色彩反差檢驗
        if isInner, let img = image {
            if !checkOuterContrast(image: img, corners: ordered) {
                isInner = false
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

        // 物理尺寸向量外彈計算 (物理標準毫米精確對齊)
        let uTop = CGPoint(x: (tr.x - tl.x) / max(1.0, topW), y: (tr.y - tl.y) / max(1.0, topW))
        let uBot = CGPoint(x: (br.x - bl.x) / max(1.0, bottomW), y: (br.y - bl.y) / max(1.0, bottomW))
        let vLeft = CGPoint(x: (bl.x - tl.x) / max(1.0, leftH), y: (bl.y - tl.y) / max(1.0, leftH))
        let vRight = CGPoint(x: (br.x - tr.x) / max(1.0, rightH), y: (br.y - tr.y) / max(1.0, rightH))

        var tlFinal: CGPoint
        var trFinal: CGPoint
        var brFinal: CGPoint
        var blFinal: CGPoint

        if isPortrait {
            // 直式相片：寬 46mm, 高 62mm
            let pxMmX = avgW / 46.0
            let pxMmY = avgH / 62.0

            let sideMargin = 4.0 * pxMmX
            let topMargin = 5.0 * pxMmY
            let chinMargin = 19.0 * pxMmY

            // 判斷下巴方位
            let spaceBelow = Double(imageSize.height) - max(bl.y, br.y)
            let spaceAbove = min(tl.y, tr.y)
            let chinAtBottom = (spaceBelow >= chinMargin * 0.75) || (spaceBelow >= spaceAbove)

            let actualTopMargin = chinAtBottom ? topMargin : chinMargin
            let actualBotMargin = chinAtBottom ? chinMargin : topMargin

            // 水平展開
            let tlOut = CGPoint(x: tl.x - sideMargin * uTop.x, y: tl.y - sideMargin * uTop.y)
            let trOut = CGPoint(x: tr.x + sideMargin * uTop.x, y: tr.y + sideMargin * uTop.y)
            let blOut = CGPoint(x: bl.x - sideMargin * uBot.x, y: bl.y - sideMargin * uBot.y)
            let brOut = CGPoint(x: br.x + sideMargin * uBot.x, y: br.y + sideMargin * uBot.y)

            // 垂直展開
            tlFinal = CGPoint(x: tlOut.x - actualTopMargin * vLeft.x, y: tlOut.y - actualTopMargin * vLeft.y)
            trFinal = CGPoint(x: trOut.x - actualTopMargin * vRight.x, y: trOut.y - actualTopMargin * vRight.y)
            blFinal = CGPoint(x: blOut.x + actualBotMargin * vLeft.x, y: blOut.y + actualBotMargin * vLeft.y)
            brFinal = CGPoint(x: brOut.x + actualBotMargin * vRight.x, y: brOut.y + actualBotMargin * vRight.y)
        } else {
            // 橫式相片：寬 62mm, 高 46mm
            let pxMmX = avgW / 62.0
            let pxMmY = avgH / 46.0

            let topMargin = 4.0 * pxMmY
            let botMargin = 4.0 * pxMmY
            let thinSideMargin = 5.0 * pxMmX
            let chinMargin = 19.0 * pxMmX

            // 判斷下巴方位 (左側或右側)
            let spaceRight = Double(imageSize.width) - max(tr.x, br.x)
            let spaceLeft = min(tl.x, bl.x)
            let chinAtRight = (spaceRight >= chinMargin * 0.75) || (spaceRight >= spaceLeft)

            let actualLeftMargin = chinAtRight ? thinSideMargin : chinMargin
            let actualRightMargin = chinAtRight ? chinMargin : thinSideMargin

            // 水平展開 (單側下巴，絕不對稱雙倍外彈)
            let tlOut = CGPoint(x: tl.x - actualLeftMargin * uTop.x, y: tl.y - actualLeftMargin * uTop.y)
            let trOut = CGPoint(x: tr.x + actualRightMargin * uTop.x, y: tr.y + actualRightMargin * uTop.y)
            let blOut = CGPoint(x: bl.x - actualLeftMargin * uBot.x, y: bl.y - actualLeftMargin * uBot.y)
            let brOut = CGPoint(x: br.x + actualRightMargin * uBot.x, y: br.y + actualRightMargin * uBot.y)

            // 垂直展開
            tlFinal = CGPoint(x: tlOut.x - topMargin * vLeft.x, y: tlOut.y - topMargin * vLeft.y)
            trFinal = CGPoint(x: trOut.x - topMargin * vRight.x, y: trOut.y - topMargin * vRight.y)
            blFinal = CGPoint(x: blOut.x + botMargin * vLeft.x, y: blOut.y + botMargin * vLeft.y)
            brFinal = CGPoint(x: brOut.x + botMargin * vRight.x, y: brOut.y + botMargin * vRight.y)
        }

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
