import Foundation
import CoreImage
import CoreGraphics

// MARK: - VisionManager + Layer 3 (HSV White Mask Contour)
//
// Python 版 find_cheki_quad_by_white() の Swift ポート
// 複数の HSV 閾値パラメータを試し、白い外枠輪郭を 4 角形に近似する

extension VisionManager {

    func detectWhiteMask(image: CGImage, imageSize: CGSize) throws -> DetectionResult {
        let imgW = Int(imageSize.width)
        let imgH = Int(imageSize.height)

        guard let pixels = extractRGBAPixelsPublic(from: image, width: imgW, height: imgH) else {
            throw VisionError.preprocessFailed
        }

        // Python と同じ閾値リスト
        let params: [(sMax: Int, vMin: Int)] = [(40, 185), (55, 170), (70, 155), (90, 140)]
        var bestPts: [CGPoint]?
        var bestArea = 0.0

        for param in params {
            // ① HSV 白マスク生成
            var mask = [UInt8](repeating: 0, count: imgW * imgH)
            for y in 0..<imgH {
                for x in 0..<imgW {
                    let idx = (y * imgW + x) * 4
                    let r = Int(pixels[idx]), g = Int(pixels[idx+1]), b = Int(pixels[idx+2])
                    let (_, s, v) = rgbToHSVPublic(r: r, g: g, b: b)
                    if s <= param.sMax && v >= param.vMin {
                        mask[y * imgW + x] = 255
                    }
                }
            }

            // ② モルフォロジー：close (15×15 × 3) + open (5×5 × 2)
            mask = morphClose(mask, w: imgW, h: imgH, ksize: 15, iterations: 3)
            mask = morphOpen(mask,  w: imgW, h: imgH, ksize: 5,  iterations: 2)

            // ③ 連結成分の外接矩形近似（contourApproxPoly 代替）
            // 簡略実装：マスクの境界ピクセルから凸四角形を近似
            if let pts = approximateQuadFromMask(mask, w: imgW, h: imgH) {
                let area = VisionManager.quadArea(pts)
                let minA = 0.04 * Double(imgW * imgH)
                let maxA = 0.60 * Double(imgW * imgH)
                if area >= minA && area <= maxA
                    && VisionManager.isChekiRatio(pts)
                    && area > bestArea {
                    bestArea = area
                    bestPts  = pts
                }
            }
        }

        guard let pts = bestPts else { throw VisionError.detectionFailed }
        let ordered = VisionManager.orderPoints(pts)
        return DetectionResult(
            corners: ordered,
            method: .whiteMask,
            confidence: 0.5,
            imageSize: imageSize
        )
    }

    // MARK: - Quad Approximation from Binary Mask

    /// マスクの境界ピクセルから最外枠の凸四角形を近似
    private func approximateQuadFromMask(_ mask: [UInt8], w: Int, h: Int) -> [CGPoint]? {
        // エッジピクセルを収集
        var edgePts: [CGPoint] = []
        for y in 1..<(h-1) {
            for x in 1..<(w-1) {
                guard mask[y * w + x] > 0 else { continue }
                // 隣接に 0 があればエッジ
                let neighbors = [
                    mask[(y-1)*w+x], mask[(y+1)*w+x],
                    mask[y*w+(x-1)], mask[y*w+(x+1)]
                ]
                if neighbors.contains(0) {
                    edgePts.append(CGPoint(x: x, y: y))
                }
            }
        }
        guard edgePts.count >= 4 else { return nil }

        // 凸包 → 四角形近似
        let hull = convexHull(edgePts)
        guard hull.count >= 4 else { return nil }

        // 四角形に近似（最遠点選択）
        return approximateToQuad(hull)
    }

    /// Graham Scan 凸包
    private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count-2], lower[lower.count-1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count-2], upper[upper.count-1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    private func cross(_ O: CGPoint, _ A: CGPoint, _ B: CGPoint) -> Double {
        Double((A.x - O.x) * (B.y - O.y) - (A.y - O.y) * (B.x - O.x))
    }

    /// 凸包から最も四角形らしい 4 点を選択
    private func approximateToQuad(_ hull: [CGPoint]) -> [CGPoint]? {
        guard hull.count >= 4 else { return nil }
        // 対角距離最大の 2 点ペア + それぞれ直交方向の最遠点
        // 簡略版：TL/TR/BR/BL 方向の最遠点
        let cx = hull.map { $0.x }.reduce(0, +) / CGFloat(hull.count)
        let cy = hull.map { $0.y }.reduce(0, +) / CGFloat(hull.count)

        // 各象限で中心から最遠の点
        var tl: CGPoint?, tr: CGPoint?, br: CGPoint?, bl: CGPoint?
        var dTL = 0.0, dTR = 0.0, dBR = 0.0, dBL = 0.0

        for p in hull {
            let d = Double(hypot(p.x - cx, p.y - cy))
            if p.x <= cx && p.y <= cy { if d > dTL { dTL = d; tl = p } }
            if p.x >  cx && p.y <= cy { if d > dTR { dTR = d; tr = p } }
            if p.x >  cx && p.y >  cy { if d > dBR { dBR = d; br = p } }
            if p.x <= cx && p.y >  cy { if d > dBL { dBL = d; bl = p } }
        }
        guard let TL = tl, let TR = tr, let BR = br, let BL = bl else { return nil }
        return [TL, TR, BR, BL]
    }

    // MARK: - Shared Pixel Utilities (public to this extension)

    func extractRGBAPixelsPublic(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    func rgbToHSVPublic(r: Int, g: Int, b: Int) -> (h: Double, s: Int, v: Int) {
        let rf = Double(r)/255, gf = Double(g)/255, bf = Double(b)/255
        let cmax = max(rf,gf,bf), cmin = min(rf,gf,bf), delta = cmax - cmin
        let v = Int(cmax * 255)
        let s = cmax > 0 ? Int((delta / cmax) * 255) : 0
        var h = 0.0
        if delta > 0 {
            switch cmax {
            case rf: h = 60 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6))
            case gf: h = 60 * ((bf - rf) / delta + 2)
            default: h = 60 * ((rf - gf) / delta + 4)
            }
            if h < 0 { h += 360 }
        }
        return (h, s, v)
    }



    private func erodePublic(_ input: [UInt8], w: Int, h: Int, ksize: Int) -> [UInt8] {
        let r = ksize / 2; var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h { for x in 0..<w {
            var v = UInt8(255)
            for dy in -r...r { for dx in -r...r {
                let nx = x+dx, ny = y+dy
                guard nx>=0&&nx<w&&ny>=0&&ny<h else { continue }
                v = min(v, input[ny*w+nx])
            }}
            out[y*w+x] = v
        }}
        return out
    }
}
