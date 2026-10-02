import Foundation
import CoreGraphics
import Vision

// MARK: - QuadRefinementResult

/// 四邊垂直平行修正結果
struct QuadRefinementResult: Sendable, Equatable {
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
        skewThresholdDegrees: Double = 2.0
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
        
        let hasOutOfBounds = currentCorners.contains {
            $0.x < 0 || $0.y < 0 || $0.x > imageSize.width || $0.y > imageSize.height
        }
        
        // 觸發門檻：平行邊歪斜 >= 2.0° 或對應邊長差異 >= 12% 或頂點超出畫面
        let needsRefine = hSkew >= skewThresholdDegrees || vSkew >= skewThresholdDegrees || deltaW >= 0.12 || deltaH >= 0.12 || hasOutOfBounds
        
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
                let r = VisionManager.quadAspectRatio(cand)
                let miniErr = abs(r - 1.593)
                let sqErr = abs(r - 1.194)
                let wideErr = abs(r - 1.256)
                let formatErr = min(miniErr, min(sqErr, wideErr))
                
                guard r >= 1.12 && r <= 1.85 && formatErr <= 0.18 else { continue }
                
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
        
        // --- 1D Sobel 梯度邊緣吸附 ---
        var sobelShifted = false
        if let image = image {
            let snapped = snapEdgesWithSobel(corners: currentCorners, image: image, imageSize: imageSize)
            if snapped != currentCorners {
                currentCorners = snapped
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
    
    /// 沿四邊法向量使用 1D Sobel 梯度自動吸附至實體邊緣階躍線
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
            let a: Double
            let b: Double
            let c: Double
        }
        
        var lines: [Line] = []
        var anyEdgeShifted = false
        
        let searchR = max(15, min(25, Int(Double(min(w, h)) * 0.01)))
        let maxAllowedShift = Double(searchR) * 0.75
        
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
            
            var offsets: [Double] = []
            for s in [0.2, 0.35, 0.5, 0.65, 0.8] {
                let sx = Double(p1.x) + s * dx
                let sy = Double(p1.y) + s * dy
                
                var bestG = 0.0
                var bestD = 0.0
                for d in -searchR...searchR {
                    let outX = Int(round(sx + Double(d + 1) * nx))
                    let outY = Int(round(sy + Double(d + 1) * ny))
                    let inX  = Int(round(sx + Double(d - 1) * nx))
                    let inY  = Int(round(sy + Double(d - 1) * ny))
                    
                    let lOut = lum(x: outX, y: outY)
                    let lIn  = lum(x: inX, y: inY)
                    let g = lIn - lOut
                    if g > bestG {
                        bestG = g
                        bestD = Double(d)
                    }
                }
                if bestG >= 35.0 {
                    offsets.append(bestD)
                }
            }
            
            var shift = 0.0
            if offsets.count >= 3 {
                offsets.sort()
                let med = offsets[offsets.count / 2]
                if abs(med) >= 2.0 && abs(med) <= maxAllowedShift {
                    shift = med
                    anyEdgeShifted = true
                }
            }
            
            let mx = Double(p1.x + p2.x) / 2.0 + shift * nx
            let my = Double(p1.y + p2.y) / 2.0 + shift * ny
            let c = nx * mx + ny * my
            lines.append(Line(a: nx, b: ny, c: c))
        }
        
        guard anyEdgeShifted else { return corners }
        
        var snapped: [CGPoint] = []
        for i in 0..<4 {
            let l1 = lines[(i + 3) % 4]
            let l2 = lines[i]
            let det = l1.a * l2.b - l2.a * l1.b
            guard abs(det) > 1e-4 else { return corners }
            let x = (l1.c * l2.b - l2.c * l1.b) / det
            let y = (l1.a * l2.c - l2.a * l1.c) / det
            snapped.append(CGPoint(x: x, y: y))
        }
        
        // 防跑偏守門 (Area & Ratio Invariants)
        let origArea = VisionManager.quadArea(corners)
        let snapArea = VisionManager.quadArea(snapped)
        guard origArea > 0 else { return corners }
        let areaDiff = abs(snapArea - origArea) / origArea
        guard areaDiff <= 0.08 else { return corners }
        
        let origR = VisionManager.quadAspectRatio(corners)
        let snapR = VisionManager.quadAspectRatio(snapped)
        guard abs(snapR - origR) <= 0.08 else { return corners }
        guard VisionManager.isChekiRatio(snapped) else { return corners }
        
        return snapped
    }
}
