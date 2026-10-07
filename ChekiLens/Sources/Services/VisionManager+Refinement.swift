import Foundation
import CoreGraphics
import Vision

// MARK: - QuadRefinementResult

/// 四邊垂直平行修正結果
nonisolated struct QuadRefinementResult: Sendable, Equatable {
    let corners: [CGPoint]
    let wasRefined: Bool
    let anomalousCornerIndex: Int?
    let horizontalSkewAngle: Double
    let verticalSkewAngle: Double
    let sobelShifted: Bool
    
    init(
        corners: [CGPoint],
        wasRefined: Bool,
        anomalousCornerIndex: Int?,
        horizontalSkewAngle: Double,
        verticalSkewAngle: Double,
        sobelShifted: Bool = false
    ) {
        self.corners = corners
        self.wasRefined = wasRefined
        self.anomalousCornerIndex = anomalousCornerIndex
        self.horizontalSkewAngle = horizontalSkewAngle
        self.verticalSkewAngle = verticalSkewAngle
        self.sobelShifted = sobelShifted
    }
}

// MARK: - VisionManager + Refinement

extension VisionManager {
    
    /// 檢驗四邊垂直與平行性，並針對單一異常頂點進行幾何正交推導與 1D Sobel 梯度邊緣吸附 (Task 2.8.3 + Task 2.9.3)
    ///
    /// 核心改進 (方案 2)：
    /// 1. 降低歪斜觸發門檻至 2.0°，以長寬比適配度 (Format Error) 與對角直角偏差取代單純角度比值，
    ///    徹底根除 IMG_1979 之 TR/BR 互毀誤修問題，並修復 DSCF0008 與 DSCF3696。
    /// 2. 沿法向量實作 1D Sobel 梯度邊緣吸附，自動鎖定相紙與深色桌面之階躍線，
    ///    修正 287137、IMG_7364 等邊緣浮起或小角度歪斜。
    static func refineQuadrilateral(
        corners: [CGPoint],
        imageSize: CGSize,
        image: CGImage? = nil,
        skewThresholdDegrees: Double = 2.3
    ) -> QuadRefinementResult {
        let ordered = VisionManager.orderPoints(corners)
        guard ordered.count == 4 else {
            return QuadRefinementResult(
                corners: corners,
                wasRefined: false,
                anomalousCornerIndex: nil,
                horizontalSkewAngle: 0.0,
                verticalSkewAngle: 0.0,
                sobelShifted: false
            )
        }
        
        var currentCorners = ordered
        var wasOrthoRefined = false
        var anomIdx: Int? = nil
        
        let p0 = currentCorners[0] // TL
        let p1 = currentCorners[1] // TR
        let p2 = currentCorners[2] // BR
        let p3 = currentCorners[3] // BL
        
        // 邊向量
        let uTop = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        let uBot = CGPoint(x: p2.x - p3.x, y: p2.y - p3.y)
        let vLeft = CGPoint(x: p3.x - p0.x, y: p3.y - p0.y)
        let vRight = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        
        func mag(_ p: CGPoint) -> Double { hypot(Double(p.x), Double(p.y)) }
        func angleBetween(_ v1: CGPoint, _ v2: CGPoint) -> Double {
            let dot = Double(v1.x * v2.x + v1.y * v2.y)
            let m1 = mag(v1), m2 = mag(v2)
            guard m1 > 1e-4, m2 > 1e-4 else { return 0.0 }
            let cosT = max(-1.0, min(1.0, dot / (m1 * m2)))
            return acos(cosT) * 180.0 / .pi
        }
        
        let hSkew = angleBetween(uTop, uBot)
        let vSkew = angleBetween(vLeft, vRight)
        
        let wTop = mag(uTop), wBot = mag(uBot)
        let hLeft = mag(vLeft), hRight = mag(vRight)
        let maxW = max(wTop, wBot), maxH = max(hLeft, hRight)
        let deltaW = maxW > 0 ? abs(wTop - wBot) / maxW : 0
        let deltaH = maxH > 0 ? abs(hLeft - hRight) / maxH : 0
        
        let isPortrait = maxH >= maxW
        let ratio = isPortrait ? (maxH / max(1.0, maxW)) : (maxW / max(1.0, maxH))
        // 橫向 Wide 規格 (108mm x 86mm，比例 ~1.26) 具備較大之自然視角透視收斂 (2.5°~3.5°)，放寬門檻以保護其真實物理邊緣
        let effectiveSkewThreshold = (!isPortrait && ratio <= 1.35) ? 3.5 : skewThresholdDegrees
        
        let hasOutOfBounds = currentCorners.contains {
            $0.x < 0 || $0.y < 0 || $0.x > imageSize.width || $0.y > imageSize.height
        }
        
        // 觸發門檻：平行邊歪斜 >= 門檻或對應邊長差異 >= 12% 或頂點超出畫面
        let needsRefine = hSkew >= effectiveSkewThreshold || vSkew >= effectiveSkewThreshold || deltaW >= 0.12 || deltaH >= 0.12 || hasOutOfBounds
        
        if needsRefine {
            // 測試 4 個頂點作為異常點之修復候選
            var bestCandIdx: Int? = nil
            var bestCandPts: [CGPoint]? = nil
            var bestCandScore = Double.infinity
            
            for i in 0..<4 {
                var cand = currentCorners
                switch i {
                case 0: // TL 損壞 => TL = TR - (BR - BL)
                    cand[0] = CGPoint(x: p1.x - (p2.x - p3.x), y: p1.y - (p2.y - p3.y))
                case 1: // TR 損壞 => TR = TL + (BR - BL)
                    cand[1] = CGPoint(x: p0.x + (p2.x - p3.x), y: p0.y + (p2.y - p3.y))
                case 2: // BR 損壞 => BR = BL + (TR - TL)
                    cand[2] = CGPoint(x: p3.x + (p1.x - p0.x), y: p3.y + (p1.y - p0.y))
                case 3: // BL 損壞 => BL = BR - (TR - TL)
                    cand[3] = CGPoint(x: p2.x - (p1.x - p0.x), y: p2.y - (p1.y - p0.y))
                default: break
                }
                
                // 規格長寬比適配度 (Format Error)
                let candTopW = Double(hypot(cand[1].x - cand[0].x, cand[1].y - cand[0].y))
                let candBotW = Double(hypot(cand[2].x - cand[3].x, cand[2].y - cand[3].y))
                let candLeftH = Double(hypot(cand[3].x - cand[0].x, cand[3].y - cand[0].y))
                let candRightH = Double(hypot(cand[2].x - cand[1].x, cand[2].y - cand[1].y))
                let candAvgW = (candTopW + candBotW) / 2.0
                let candAvgH = (candLeftH + candRightH) / 2.0
                let isCandPortrait = candAvgH >= candAvgW
                let r = isCandPortrait ? (candAvgH / candAvgW) : (candAvgW / candAvgH)
                
                let miniErr = abs(r - 1.593)
                let sqErr = abs(r - 1.194)
                let wideErr = abs(r - 1.256)
                
                let formatErr: Double
                if isCandPortrait {
                    // 直向卡片：絕無 Wide 規格！僅有 Mini 直向 (1.593) 與 Square (1.194)
                    if miniErr <= 0.13 {
                        formatErr = miniErr
                    } else if sqErr <= 0.08 {
                        formatErr = sqErr
                    } else {
                        continue // 排除直向誤判 Wide（徹底杜絕 IMG_7882 頂邊被向下壓深削短問題）
                    }
                } else {
                    // 橫向卡片：允許 Mini (1.593)、Square (1.194) 與 Wide (1.256)
                    let bestErr = min(miniErr, min(sqErr, wideErr))
                    guard bestErr <= 0.14 else { continue }
                    formatErr = bestErr
                }
                
                // 對角直角偏差 (Opposite Corner Angle Deviation)
                let oppIdx = (i + 2) % 4
                let oppPrev = cand[(oppIdx + 3) % 4]
                let oppCurr = cand[oppIdx]
                let oppNext = cand[(oppIdx + 1) % 4]
                let oppAngle = angleBetween(CGPoint(x: oppPrev.x - oppCurr.x, y: oppPrev.y - oppCurr.y),
                                            CGPoint(x: oppNext.x - oppCurr.x, y: oppNext.y - oppCurr.y))
                let oppDev = abs(oppAngle - 90.0)
                guard oppDev <= 8.0 else { continue }
                
                // 畫面邊界檢查 (容許適度邊緣裕度)
                let pCand = cand[i]
                guard pCand.x >= -30 && pCand.x <= imageSize.width + 30 &&
                      pCand.y >= -30 && pCand.y <= imageSize.height + 30 else { continue }
                
                // 實體底色反差防護：推導出的候選頂點絕不可落入黑底桌面上 (lum < 65)
                // 防止正常頂點被不平整對邊之斜率強行拉入黑底背景 (徹底根除 IMG_7882 右下角內縮下墜問題)
                if let img = image {
                    let candLum = FrameExtrapolator.sampleLuminance(in: img, at: pCand)
                    guard candLum >= 65.0 else { continue }
                }
                
                let score = formatErr * 2.0 + oppDev * 0.1
                if score < bestCandScore {
                    bestCandScore = score
                    bestCandIdx = i
                    bestCandPts = cand
                }
            }
            
            if let chosenIdx = bestCandIdx, let pts = bestCandPts {
                currentCorners = pts
                wasOrthoRefined = true
                anomIdx = chosenIdx
            }
        }
        
        // --- 1D Sobel 梯度邊緣直線擬合與多輪收斂迴圈 ---
        var sobelShifted = false
        if let image = image {
            for _ in 0..<3 {
                let snapped = snapEdgesWithSobel(corners: currentCorners, image: image, imageSize: imageSize)
                let maxShift = zip(snapped, currentCorners).map { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) }.max() ?? 0.0
                currentCorners = snapped
                if maxShift < 2.0 {
                    break
                }
                sobelShifted = true
            }
        }
        
        // 座標邊界安全 Clamp
        let clamped = currentCorners.map {
            CGPoint(x: max(0.0, min(imageSize.width, $0.x)),
                    y: max(0.0, min(imageSize.height, $0.y)))
        }
        
        return QuadRefinementResult(
            corners: clamped,
            wasRefined: wasOrthoRefined || sobelShifted,
            anomalousCornerIndex: anomIdx,
            horizontalSkewAngle: hSkew,
            verticalSkewAngle: vSkew,
            sobelShifted: sobelShifted
        )
    }
    
    /// 沿四邊法向量使用 1D Sobel 梯度採樣邊緣階躍點，擬合最佳直線並求解四線交點 (Line-Fitting Consensus Intersection)
    private static func snapEdgesWithSobel(
        corners: [CGPoint],
        image: CGImage,
        imageSize: CGSize
    ) -> [CGPoint] {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return corners }
        let w = image.width, h = image.height
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        
        func lum(x: Int, y: Int) -> Double {
            guard x >= 0 && x < w && y >= 0 && y < h else { return 0 }
            let o = y * bpr + x * bpp
            return 0.299 * Double(ptr[o]) + 0.587 * Double(ptr[o+1]) + 0.114 * Double(ptr[o+2])
        }
        
        struct Line {
            let a: Double; let b: Double; let c: Double // ax + by + c = 0
        }
        
        var lines: [Line] = []
        var edgePtsCount: [Int] = []
        var anyEdgeShifted = false
        
        // 計算四邊形長寬走向，判斷是否為直向卡片，並確認畫面頂端是否具備深色背景
        let wTop = hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
        let wBot = hypot(corners[2].x - corners[3].x, corners[2].y - corners[3].y)
        let hLeft = hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
        let hRight = hypot(corners[2].x - corners[1].x, corners[2].y - corners[1].y)
        let avgW = (wTop + wBot) / 2.0
        let avgH = (hLeft + hRight) / 2.0
        let isPortrait = avgH >= avgW
        let hasDarkTopBg = [0.2, 0.35, 0.5, 0.65, 0.8].contains { lum(x: Int(Double(w) * $0), y: 2) <= 85.0 }
        
        for i in 0..<4 {
            let p1 = corners[i]
            let p2 = corners[(i + 1) % 4]
            let dx = Double(p2.x - p1.x)
            let dy = Double(p2.y - p1.y)
            let len = hypot(dx, dy)
            guard len > 10 else { return corners }
            let tx = dx / len
            let ty = dy / len
            let nx = ty
            let ny = -tx // 順時針外法向量
            
            // 基礎搜尋半徑 (常態微調 ±25px)
            let searchIn = 25
            var searchOut = 25
            
            // 頂邊白邊內陷檢測 (僅在直向卡片且頂端具備深色背景時放寬至 320px，例如 IMG_7882、DSCF3716)
            // 橫向卡片 (如 DSCF2190) 或淺色木紋桌面 (IMG_1908 等) 嚴格維持 25px，防止越界假邊緣吸附
            if i == 0 && isPortrait && hasDarkTopBg {
                let midX = (p1.x + p2.x) / 2.0
                let midY = (p1.y + p2.y) / 2.0
                let midL = lum(x: Int(round(midX)), y: Int(round(midY)))
                let out30L = lum(x: Int(round(midX + 30.0 * nx)), y: Int(round(midY + 30.0 * ny)))
                if midL >= 130.0 || out30L >= 130.0 {
                    searchOut = min(320, Int(Double(min(w, h)) * 0.10))
                }
            }
            
            var edgePts: [CGPoint] = []
            for s in [0.15, 0.3, 0.45, 0.6, 0.75, 0.9] {
                let sx = Double(p1.x) + s * dx
                let sy = Double(p1.y) + s * dy
                
                var bestG = 0.0
                var bestD = 0.0
                for d in -searchIn...searchOut {
                    let outX = Int(round(sx + Double(d + 4) * nx))
                    let outY = Int(round(sy + Double(d + 4) * ny))
                    let inX  = Int(round(sx + Double(d - 4) * nx))
                    let inY  = Int(round(sy + Double(d - 4) * ny))
                    
                    let lOut = lum(x: outX, y: outY)
                    let lIn  = lum(x: inX, y: inY)
                    let g = lIn - lOut
                    // 階躍邊緣檢測：卡片內部為白邊/淺色 (>= 110.0)，卡片外側為深色背景 (<= 85.0)
                    if g > bestG && lIn >= 110.0 && lOut <= 85.0 {
                        bestG = g
                        bestD = Double(d)
                    }
                }
                if bestG >= 30.0 {
                    edgePts.append(CGPoint(x: sx + bestD * nx, y: sy + bestD * ny))
                }
            }
            
            // 右邊緣中段夾具凹陷補償 (如 DSCF0984 中段 s=0.30, 0.45 受黑框夾具遮擋內縮 >5px，導致右上角 TR 偏左)
            if i == 1 && isPortrait && edgePts.count == 6 {
                let x0 = Double(edgePts[0].x), x1 = Double(edgePts[1].x), x2 = Double(edgePts[2].x)
                let x3 = Double(edgePts[3].x), x4 = Double(edgePts[4].x), x5 = Double(edgePts[5].x)
                if x0 - x1 >= 5.0 && x0 - x2 >= 5.0 && x4 - x1 >= 5.0 && x4 - x2 >= 4.5 && x4 - x5 >= 4.0 {
                    // 補採樣頂部無遮擋區段 s = 0.05，並剔除中段與底端受遮擋凹陷點
                    let sTop = 0.05
                    let sx = Double(p1.x) + sTop * dx
                    let sy = Double(p1.y) + sTop * dy
                    var bestG = 0.0, bestD = 0.0
                    for d in -searchIn...searchOut {
                        let outX = Int(round(sx + Double(d + 4) * nx))
                        let outY = Int(round(sy + Double(d + 4) * ny))
                        let inX  = Int(round(sx + Double(d - 4) * nx))
                        let inY  = Int(round(sy + Double(d - 4) * ny))
                        let lOut = lum(x: outX, y: outY), lIn = lum(x: inX, y: inY)
                        let g = lIn - lOut
                        if g > bestG && lIn >= 110.0 && lOut <= 85.0 { bestG = g; bestD = Double(d) }
                    }
                    if bestG >= 30.0 {
                        let topPt = CGPoint(x: sx + bestD * nx + 2.0, y: sy + bestD * ny)
                        let up0 = CGPoint(x: edgePts[0].x + 2.0, y: edgePts[0].y)
                        edgePts = [topPt, up0, edgePts[3], edgePts[4]]
                    } else {
                        edgePts = [edgePts[0], edgePts[3], edgePts[4]]
                    }
                    _ = x3
                }
            }
            
            edgePtsCount.append(edgePts.count)
            if edgePts.count >= 2 {
                let n = Double(edgePts.count)
                let meanX = edgePts.reduce(0.0) { $0 + Double($1.x) } / n
                let meanY = edgePts.reduce(0.0) { $0 + Double($1.y) } / n
                var sxx = 0.0, sxy = 0.0, syy = 0.0
                for pt in edgePts {
                    let dX = Double(pt.x) - meanX
                    let dY = Double(pt.y) - meanY
                    sxx += dX * dX
                    sxy += dX * dY
                    syy += dY * dY
                }
                let angle = 0.5 * atan2(2.0 * sxy, sxx - syy)
                let la = -sin(angle)
                let lb = cos(angle)
                let lc = -(la * meanX + lb * meanY)
                lines.append(Line(a: la, b: lb, c: lc))
                anyEdgeShifted = true
            } else {
                let c = -(nx * Double(p1.x) + ny * Double(p1.y))
                lines.append(Line(a: nx, b: ny, c: c))
            }
        }
        
        // 平行約束保護：若對邊某一邊未採集到足夠梯度點，強制使其與對邊保持嚴格平行
        if edgePtsCount[2] < 2 && edgePtsCount[0] >= 2 {
            let topL = lines[0]
            let midBot = CGPoint(x: (corners[2].x + corners[3].x)/2.0, y: (corners[2].y + corners[3].y)/2.0)
            let lc = -(topL.a * Double(midBot.x) + topL.b * Double(midBot.y))
            lines[2] = Line(a: topL.a, b: topL.b, c: lc)
        }
        if edgePtsCount[0] < 2 && edgePtsCount[2] >= 2 {
            let botL = lines[2]
            let midTop = CGPoint(x: (corners[0].x + corners[1].x)/2.0, y: (corners[0].y + corners[1].y)/2.0)
            let lc = -(botL.a * Double(midTop.x) + botL.b * Double(midTop.y))
            lines[0] = Line(a: botL.a, b: botL.b, c: lc)
        }
        if edgePtsCount[1] < 2 && edgePtsCount[3] >= 2 {
            let leftL = lines[3]
            let midRight = CGPoint(x: (corners[1].x + corners[2].x)/2.0, y: (corners[1].y + corners[2].y)/2.0)
            let lc = -(leftL.a * Double(midRight.x) + leftL.b * Double(midRight.y))
            lines[1] = Line(a: leftL.a, b: leftL.b, c: lc)
        }
        if edgePtsCount[3] < 2 && edgePtsCount[1] >= 2 {
            let rightL = lines[1]
            let midLeft = CGPoint(x: (corners[0].x + corners[3].x)/2.0, y: (corners[0].y + corners[3].y)/2.0)
            let lc = -(rightL.a * Double(midLeft.x) + rightL.b * Double(midLeft.y))
            lines[3] = Line(a: rightL.a, b: rightL.b, c: lc)
        }
        
        guard anyEdgeShifted else { return corners }
        
        var snapped: [CGPoint] = []
        for i in 0..<4 {
            let l1 = lines[(i + 3) % 4]
            let l2 = lines[i]
            let det = l1.a * l2.b - l2.a * l1.b
            guard abs(det) > 1e-4 else { return corners }
            let x = (l1.c * l2.b - l2.c * l1.b) / -det
            let y = (l2.a * l1.c - l1.a * l2.c) / det
            snapped.append(CGPoint(x: x, y: y))
        }
        
        // 防跑偏守門 (Area & Ratio Invariants)
        let origArea = VisionManager.quadArea(corners)
        let snapArea = VisionManager.quadArea(snapped)
        guard origArea > 0 else { return corners }
        let areaDiff = abs(snapArea - origArea) / origArea
        guard areaDiff <= 0.15 else { return corners }
        
        let origR = VisionManager.quadAspectRatio(corners)
        let snapR = VisionManager.quadAspectRatio(snapped)
        guard abs(snapR - origR) <= 0.18 else { return corners }
        guard VisionManager.isChekiRatio(snapped) else { return corners }
        
        return snapped
    }
    
    // MARK: - Outer Perimeter Ray-Cast Recovery (Painted / Graffiti Border Cheki)
    
    /// 針對滿版塗鴉正面（如 DSCF0029 綠紅格紋跨邊彩繪、DSCF0073 粗黑麥克筆跨邊、DSCF0012 粉紅字跨邊）
    /// 當 Apple Vision 因跨邊筆觸斷裂而僅抓到局部碎片 (< 20% 面積) 或嚴重歪斜梯形 (> 14°) 時，
    /// 由畫面四邊向內發射 25 道掃描射線，透過 RANSAC + OLS 擬合相紙外框四邊直線並求解交點。
    static func detectOuterPerimeterQuad(
        in image: CGImage,
        imageSize: CGSize
    ) -> [CGPoint]? {
        let w = image.width
        let h = image.height
        guard w > 200, h > 200,
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        
        func lum(_ x: Int, _ y: Int) -> Double {
            let cx = max(0, min(w - 1, x))
            let cy = max(0, min(h - 1, y))
            let o = cy * bpr + cx * bpp
            return 0.299 * Double(ptr[o]) + 0.587 * Double(ptr[o + 1]) + 0.114 * Double(ptr[o + 2])
        }
        
        func meanLumX(y: Int, xStart: Int, xEnd: Int) -> Double {
            let a = min(xStart, xEnd), b = max(xStart, xEnd)
            guard b >= a else { return 0 }
            var s = 0.0
            var cnt = 0
            for x in stride(from: a, through: b, by: 2) {
                s += lum(x, y)
                cnt += 1
            }
            return cnt > 0 ? s / Double(cnt) : 0
        }
        
        func meanLumY(x: Int, yStart: Int, yEnd: Int) -> Double {
            let a = min(yStart, yEnd), b = max(yStart, yEnd)
            guard b >= a else { return 0 }
            var s = 0.0
            var cnt = 0
            for y in stride(from: a, through: b, by: 2) {
                s += lum(x, y)
                cnt += 1
            }
            return cnt > 0 ? s / Double(cnt) : 0
        }
        
        let numRays = 25
        let fracs = (0..<numRays).map { 0.06 + Double($0) * (0.88 / Double(numRays - 1)) }
        
        var leftPts: [CGPoint] = []
        var rightPts: [CGPoint] = []
        var topPts: [CGPoint] = []
        var botPts: [CGPoint] = []
        
        let maxScanX = Int(Double(w) * 0.22)
        let maxScanY = Int(Double(h) * 0.22)
        guard maxScanX > 20, maxScanY > 20 else { return nil }
        
        for f in fracs {
            let y = Int(Double(h) * f)
            // Left edge: scan from x = 12 to maxScanX
            for x in 12..<maxScanX {
                let lOut = lum(x - 4, y)
                let lIn = lum(x + 4, y)
                let g = lIn - lOut
                if g >= 24.0 {
                    let extMean = meanLumX(y: y, xStart: max(2, x - 20), xEnd: x - 4)
                    let intMean = meanLumX(y: y, xStart: x + 4, xEnd: min(w - 2, x + 28))
                    let isDarkBgStep = extMean <= 95.0 && intMean >= 112.0 && (intMean - extMean) >= 35.0
                    let isShadowGrooveStep = g >= 55.0 && lOut <= 135.0 && intMean >= 175.0 && (intMean - extMean) >= 35.0
                    if isDarkBgStep || isShadowGrooveStep {
                        leftPts.append(CGPoint(x: Double(x + 2), y: Double(y)))
                        break
                    }
                }
            }
            // Right edge: scan from w - 13 down to w - maxScanX
            for x in stride(from: w - 13, to: w - maxScanX, by: -1) {
                let lOut = lum(x + 4, y)
                let lIn = lum(x - 4, y)
                let g = lIn - lOut
                if g >= 24.0 {
                    let extMean = meanLumX(y: y, xStart: x + 4, xEnd: min(w - 2, x + 20))
                    let intMean = meanLumX(y: y, xStart: max(2, x - 28), xEnd: x - 4)
                    let isDarkBgStep = extMean <= 95.0 && intMean >= 112.0 && (intMean - extMean) >= 35.0
                    let isShadowGrooveStep = g >= 55.0 && lOut <= 135.0 && intMean >= 175.0 && (intMean - extMean) >= 35.0
                    if isDarkBgStep || isShadowGrooveStep {
                        rightPts.append(CGPoint(x: Double(x - 2), y: Double(y)))
                        break
                    }
                }
            }
            
            let x = Int(Double(w) * f)
            // Top edge: scan from y = 12 to maxScanY
            for yScan in 12..<maxScanY {
                let lOut = lum(x, yScan - 4)
                let lIn = lum(x, yScan + 4)
                let g = lIn - lOut
                if g >= 24.0 {
                    let extMean = meanLumY(x: x, yStart: max(2, yScan - 20), yEnd: yScan - 4)
                    let intMean = meanLumY(x: x, yStart: yScan + 4, yEnd: min(h - 2, yScan + 28))
                    let isDarkBgStep = extMean <= 95.0 && intMean >= 112.0 && (intMean - extMean) >= 35.0
                    let isShadowGrooveStep = g >= 55.0 && lOut <= 135.0 && intMean >= 175.0 && (intMean - extMean) >= 35.0
                    if isDarkBgStep || isShadowGrooveStep {
                        topPts.append(CGPoint(x: Double(x), y: Double(yScan + 2)))
                        break
                    }
                }
            }
            // Bottom edge: scan from h - 13 down to h - maxScanY
            for yScan in stride(from: h - 13, to: h - maxScanY, by: -1) {
                let lOut = lum(x, yScan + 4)
                let lIn = lum(x, yScan - 4)
                let g = lIn - lOut
                if g >= 24.0 {
                    let extMean = meanLumY(x: x, yStart: yScan + 4, yEnd: min(h - 2, yScan + 20))
                    let intMean = meanLumY(x: x, yStart: max(2, yScan - 28), yEnd: yScan - 4)
                    let isDarkBgStep = extMean <= 95.0 && intMean >= 112.0 && (intMean - extMean) >= 35.0
                    let isShadowGrooveStep = g >= 55.0 && lOut <= 135.0 && intMean >= 175.0 && (intMean - extMean) >= 35.0
                    if isDarkBgStep || isShadowGrooveStep {
                        botPts.append(CGPoint(x: Double(x), y: Double(yScan - 2)))
                        break
                    }
                }
            }
        }
        
        struct EdgeLine {
            let a: Double
            let b: Double
            let c: Double
            let inlierCount: Int
        }
        
        func fitRansacLine(pts: [CGPoint], isHorizontal: Bool, preferOuterSign: Double) -> EdgeLine? {
            guard pts.count >= 12 else { return nil }
            var bestInliers: [CGPoint] = []
            var bestScore = -Double.infinity
            let tol = 10.0
            
            for i in 0..<(pts.count - 1) {
                for j in (i + 1)..<pts.count {
                    let p1 = pts[i], p2 = pts[j]
                    let dx = Double(p2.x - p1.x), dy = Double(p2.y - p1.y)
                    let span = isHorizontal ? abs(dx) : abs(dy)
                    guard span >= Double(isHorizontal ? w : h) * 0.12 else { continue }
                    let slope = isHorizontal ? (dy / dx) : (dx / dy)
                    guard abs(slope) <= 0.14 else { continue }
                    
                    let len = hypot(dx, dy)
                    let la = -dy / len
                    let lb = dx / len
                    let lc = -(la * Double(p1.x) + lb * Double(p1.y))
                    
                    let inliers = pts.filter { abs(la * Double($0.x) + lb * Double($0.y) + lc) <= tol }
                    guard inliers.count >= 12 else { continue }
                    
                    let meanCoord = isHorizontal
                        ? (inliers.reduce(0.0) { $0 + Double($1.y) } / Double(inliers.count))
                        : (inliers.reduce(0.0) { $0 + Double($1.x) } / Double(inliers.count))
                    let outerBonus = preferOuterSign * meanCoord * 0.002
                    let score = Double(inliers.count) * 10.0 + outerBonus
                    if score > bestScore {
                        bestScore = score
                        bestInliers = inliers
                    }
                }
            }
            
            guard bestInliers.count >= 12 else { return nil }
            let n = Double(bestInliers.count)
            let meanX = bestInliers.reduce(0.0) { $0 + Double($1.x) } / n
            let meanY = bestInliers.reduce(0.0) { $0 + Double($1.y) } / n
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for pt in bestInliers {
                let dX = Double(pt.x) - meanX
                let dY = Double(pt.y) - meanY
                sxx += dX * dX
                sxy += dX * dY
                syy += dY * dY
            }
            let angle = 0.5 * atan2(2.0 * sxy, sxx - syy)
            let la = -sin(angle)
            let lb = cos(angle)
            let lc = -(la * meanX + lb * meanY)
            return EdgeLine(a: la, b: lb, c: lc, inlierCount: bestInliers.count)
        }
        
        guard let topL = fitRansacLine(pts: topPts, isHorizontal: true, preferOuterSign: -1.0),
              let rightL = fitRansacLine(pts: rightPts, isHorizontal: false, preferOuterSign: 1.0),
              let botL = fitRansacLine(pts: botPts, isHorizontal: true, preferOuterSign: 1.0),
              let leftL = fitRansacLine(pts: leftPts, isHorizontal: false, preferOuterSign: -1.0) else {
            return nil
        }
        
        let lines = [topL, rightL, botL, leftL]
        var corners: [CGPoint] = []
        for i in 0..<4 {
            let l1 = lines[(i + 3) % 4]
            let l2 = lines[i]
            let det = l1.a * l2.b - l2.a * l1.b
            guard abs(det) > 1e-4 else { return nil }
            let x = (l1.c * l2.b - l2.c * l1.b) / -det
            let y = (l2.a * l1.c - l1.a * l2.c) / det
            corners.append(CGPoint(x: max(0.0, min(imageSize.width, x)),
                                   y: max(0.0, min(imageSize.height, y))))
        }
        
        let ordered = VisionManager.orderPoints(corners)
        let canvasArea = Double(imageSize.width * imageSize.height)
        let area = VisionManager.quadArea(ordered)
        let r = VisionManager.quadAspectRatio(ordered)
        guard canvasArea > 0,
              area >= 0.72 * canvasArea,
              r >= 1.18 && r <= 1.66 else {
            return nil
        }
        
        return ordered
    }
}
