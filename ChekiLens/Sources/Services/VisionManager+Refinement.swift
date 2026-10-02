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
}

// MARK: - VisionManager + Refinement

extension VisionManager {
    
    /// 檢驗四邊垂直與平行性，並針對單一異常頂點進行幾何與局部精密修正 (Task 2.8.3)
    ///
    /// 專門解決例如 287136 (右上大幅偏移) 的問題：
    /// 當某一頂點因高光反光或污漬向外或向內嚴重漂移時，
    /// 利用其餘 3 個正常正交頂點形成的幾何向量，精準反推修正該漂移頂點。
    static func refineQuadrilateral(
        corners: [CGPoint],
        imageSize: CGSize,
        skewThresholdDegrees: Double = 4.0
    ) -> QuadRefinementResult {
        let ordered = VisionManager.orderPoints(corners)
        guard ordered.count == 4 else {
            return QuadRefinementResult(
                corners: corners,
                wasRefined: false,
                anomalousCornerIndex: nil,
                horizontalSkewAngle: 0.0,
                verticalSkewAngle: 0.0
            )
        }
        
        let tl = ordered[0]
        let tr = ordered[1]
        let br = ordered[2]
        let bl = ordered[3]
        
        // 邊向量
        let uTop = CGPoint(x: tr.x - tl.x, y: tr.y - tl.y)
        let uBot = CGPoint(x: br.x - bl.x, y: br.y - bl.y)
        let vLeft = CGPoint(x: bl.x - tl.x, y: bl.y - tl.y)
        let vRight = CGPoint(x: br.x - tr.x, y: br.y - tr.y)
        
        func angleBetween(_ v1: CGPoint, _ v2: CGPoint) -> Double {
            let dot = Double(v1.x * v2.x + v1.y * v2.y)
            let mag1 = Double(hypot(v1.x, v1.y))
            let mag2 = Double(hypot(v2.x, v2.y))
            guard mag1 > 1e-4, mag2 > 1e-4 else { return 0.0 }
            let cosTheta = max(-1.0, min(1.0, dot / (mag1 * mag2)))
            return acos(cosTheta) * 180.0 / .pi
        }
        
        let hSkew = angleBetween(uTop, uBot)
        let vSkew = angleBetween(vLeft, vRight)
        
        func getCornerAngles(pts: [CGPoint]) -> [Double] {
            var angles: [Double] = []
            for i in 0..<4 {
                let prev = pts[(i + 3) % 4]
                let curr = pts[i]
                let next = pts[(i + 1) % 4]
                let v1 = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
                let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
                angles.append(angleBetween(v1, v2))
            }
            return angles
        }
        
        let angles = getCornerAngles(pts: ordered)
        let devs = angles.map { abs($0 - 90.0) }
        
        var refined = ordered
        var wasRefined = false
        var anomIdx: Int? = nil
        
        let topDev = devs[0] + devs[1]
        let botDev = devs[2] + devs[3]
        let leftDev = devs[0] + devs[3]
        let rightDev = devs[1] + devs[2]
        
        if hSkew >= skewThresholdDegrees {
            if botDev < topDev * 0.5 {
                // 底邊穩定，頂邊某頂點偏移
                let idx = devs[1] >= devs[0] ? 1 : 0
                anomIdx = idx
                if idx == 1 {
                    // TR 偏移 -> TR = TL + (BR - BL)
                    refined[1] = CGPoint(x: refined[0].x + (refined[2].x - refined[3].x),
                                         y: refined[0].y + (refined[2].y - refined[3].y))
                } else {
                    // TL 偏移 -> TL = TR - (BR - BL)
                    refined[0] = CGPoint(x: refined[1].x - (refined[2].x - refined[3].x),
                                         y: refined[1].y - (refined[2].y - refined[3].y))
                }
                wasRefined = true
            } else if topDev < botDev * 0.5 {
                // 頂邊穩定，底邊某頂點偏移
                let idx = devs[2] >= devs[3] ? 2 : 3
                anomIdx = idx
                if idx == 2 {
                    // BR 偏移 -> BR = BL + (TR - TL)
                    refined[2] = CGPoint(x: refined[3].x + (refined[1].x - refined[0].x),
                                         y: refined[3].y + (refined[1].y - refined[0].y))
                } else {
                    // BL 偏移 -> BL = BR - (TR - TL)
                    refined[3] = CGPoint(x: refined[2].x - (refined[1].x - refined[0].x),
                                         y: refined[2].y - (refined[1].y - refined[0].y))
                }
                wasRefined = true
            }
        } else if vSkew >= skewThresholdDegrees {
            if leftDev < rightDev * 0.5 {
                // 左邊穩定，右邊某頂點偏移
                let idx = devs[1] >= devs[2] ? 1 : 2
                anomIdx = idx
                if idx == 1 {
                    refined[1] = CGPoint(x: refined[2].x - (refined[3].x - refined[0].x),
                                         y: refined[2].y - (refined[3].y - refined[0].y))
                } else {
                    refined[2] = CGPoint(x: refined[1].x + (refined[3].x - refined[0].x),
                                         y: refined[1].y + (refined[3].y - refined[0].y))
                }
                wasRefined = true
            } else if rightDev < leftDev * 0.5 {
                // 右邊穩定，左邊某頂點偏移
                let idx = devs[0] >= devs[3] ? 0 : 3
                anomIdx = idx
                if idx == 0 {
                    refined[0] = CGPoint(x: refined[3].x - (refined[2].x - refined[1].x),
                                         y: refined[3].y - (refined[2].y - refined[1].y))
                } else {
                    refined[3] = CGPoint(x: refined[0].x + (refined[2].x - refined[1].x),
                                         y: refined[3].y + (refined[2].y - refined[1].y))
                }
                wasRefined = true
            }
        }
        
        // 座標邊界安全 Clamp
        func clamp(_ pt: CGPoint) -> CGPoint {
            CGPoint(
                x: max(0.0, min(imageSize.width, pt.x)),
                y: max(0.0, min(imageSize.height, pt.y))
            )
        }
        
        return QuadRefinementResult(
            corners: refined.map(clamp),
            wasRefined: wasRefined,
            anomalousCornerIndex: anomIdx,
            horizontalSkewAngle: hSkew,
            verticalSkewAngle: vSkew
        )
    }
}
