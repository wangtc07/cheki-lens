import Foundation
import CoreImage
import CoreGraphics
import Accelerate

// MARK: - VisionManager + Layer 2 (Hough-based Line Detection)
//
// Python 版 find_cheki_quad_hough() の Swift ポート
// Dual Mask 戦略：
//   mask_white  (HSV 純白) → 下辺精度が高い
//   mask_bright (Gray > 60) → 上/左/右辺精度が高い
// 両マスクの Canny エッジから HoughLines を抽出し，
// 水平線×2 + 垂直線×2 の組み合わせ交点で最良四角形を選ぶ

extension VisionManager {

    // MARK: - Hough Detection Entry

    func detectHough(image: CGImage, imageSize: CGSize) throws -> DetectionResult {
        let imgW = Int(imageSize.width)
        let imgH = Int(imageSize.height)

        // 1. pixel buffer に変換
        guard let pixels = extractRGBAPixels(from: image, width: imgW, height: imgH) else {
            throw VisionError.preprocessFailed
        }

        // 2. Dual Mask 生成
        let maskWhite  = buildWhiteMask(pixels: pixels, w: imgW, h: imgH)
        let maskBright = buildBrightMask(pixels: pixels, w: imgW, h: imgH)

        // 3. Canny エッジ → Hough 直線
        var lines: [HoughLine] = []
        if let mw = maskWhite  { lines += houghLines(mask: mw, w: imgW, h: imgH, scale: 1, threshold: 80) }
        if let mb = maskBright { lines += houghLines(mask: mb, w: imgW, h: imgH, scale: 1, threshold: 80) }
        guard !lines.isEmpty else { print("Hough failed: lines empty"); throw VisionError.detectionFailed }

        // 4. 水平 / 垂直 に分類
        let hThresh = 25.0 * .pi / 180.0
        let vThresh = 25.0 * .pi / 180.0
        var horiz = lines.filter { l in
            let t = normalizeTheta(l.theta)
            return t < hThresh || t > (.pi - hThresh)
        }
        var vert = lines.filter { l in
            let t = normalizeTheta(l.theta)
            return abs(t - .pi / 2) < vThresh
        }
        guard horiz.count >= 2, vert.count >= 2 else { print("Hough failed: not enough horiz/vert: \(horiz.count), \(vert.count)"); throw VisionError.detectionFailed }

        // 5. 重複除去（rho 差 40px 以内は同一辺とみなす）
        horiz = deduplicate(lines: horiz.sorted { $0.rho < $1.rho }, distThresh: 40)
        vert  = deduplicate(lines: vert.sorted  { $0.rho < $1.rho }, distThresh: 40)

        // 6. 組み合わせ総当たり → 最良四角形探索
        var bestCorners: [CGPoint]?
        var bestScore = -Double.infinity
        let margin = 0.15

        for i in 0..<horiz.count {
            for j in (i+1)..<horiz.count {
                let top = horiz[i], bot = horiz[j]
                for k in 0..<vert.count {
                    for l2 in (k+1)..<vert.count {
                        let left = vert[k], right = vert[l2]
                        guard let tl = lineIntersection(top,  left),
                              let tr = lineIntersection(top,  right),
                              let br = lineIntersection(bot,  right),
                              let bl = lineIntersection(bot,  left) else { continue }

                        let corners = [tl, tr, br, bl]

                        // 画像内マージンチェック
                        let inBounds = corners.allSatisfy {
                            $0.x >= -margin * Double(imgW) && $0.x <= Double(imgW) * (1 + margin) &&
                            $0.y >= -margin * Double(imgH) && $0.y <= Double(imgH) * (1 + margin)
                        }
                        guard inBounds else { continue }

                        // 面積チェック
                        let area = VisionManager.quadArea(corners)
                        let minArea = 0.04 * Double(imgW * imgH)
                        let maxArea = 0.60 * Double(imgW * imgH)
                        guard area >= minArea && area <= maxArea else { continue }

                        // 比率チェック（Hough は厳しめ 1.45~1.75）
                        let ratio = VisionManager.quadAspectRatio(corners)
                        guard VisionManager.houghRatioMin <= ratio && ratio <= VisionManager.houghRatioMax
                        else { continue }

                        // スコア：面積優先、比率ズレにペナルティ
                        let score = area / (1.0 + 5.0 * abs(ratio - ChekiFilmFormat.mini.aspectRatio))
                        if score > bestScore {
                            bestScore = score
                            bestCorners = corners
                        }
                    }
                }
            }
        }

        guard let corners = bestCorners else { print("Hough failed: no valid corners found (score: \(bestScore))"); throw VisionError.detectionFailed }
        let ordered = VisionManager.orderPoints(corners)
        let normalizedScore = min(1.0, bestScore / (0.30 * Double(imgW * imgH)))

        return DetectionResult(
            corners: ordered,
            method: .hough,
            confidence: normalizedScore,
            imageSize: imageSize
        )
    }

    // MARK: - Pixel Extraction

    private func extractRGBAPixels(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
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

    // MARK: - Dual Mask

    /// mask_white：HSV 純白フィルタ（下辺精度向上）
    /// HSV v_min=170, s_max=50 → 純粋な白
    func buildWhiteMask(pixels: [UInt8], w: Int, h: Int) -> [UInt8]? {
        // 複数の閾値パラメータを試して最良のものを採用
        let params: [(sMax: Int, vMin: Int)] = [(50, 170), (70, 150), (40, 185), (100, 130)]
        var bestMask: [UInt8]?
        var bestArea = 0

        for param in params {
            var mask = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let idx = (y * w + x) * 4
                    let r = Int(pixels[idx]), g = Int(pixels[idx+1]), b = Int(pixels[idx+2])
                    let (_, s, v) = rgbToHSV(r: r, g: g, b: b)
                    if s <= param.sMax && v >= param.vMin {
                        mask[y * w + x] = 255
                    }
                }
            }
            // モルフォロジー処理
            mask = morphClose(mask, w: w, h: h, ksize: 7, iterations: 2)
            mask = morphOpen(mask, w: w, h: h, ksize: 7, iterations: 1)

            // 最大連結成分を抽出し面積比チェック
            let area = countWhitePixels(mask)
            let areaRatio = Double(area) / Double(w * h)
            if areaRatio >= 0.04 && areaRatio <= 0.60 && area > bestArea {
                bestArea = area
                bestMask = mask
            }
        }
        return bestMask
    }

    /// mask_bright：グレースケール > 60（暗い背景以外）
    private func buildBrightMask(pixels: [UInt8], w: Int, h: Int) -> [UInt8]? {
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            gray[i] = UInt8(clamping: (r * 77 + g * 150 + b * 29) >> 8)
        }
        // ガウスぼかし（簡易 box blur で近似）
        gray = boxBlur(gray, w: w, h: h, radius: 4)
        var mask = gray.map { $0 > 60 ? UInt8(255) : 0 }
        mask = morphClose(mask, w: w, h: h, ksize: 21, iterations: 3)
        mask = morphOpen(mask, w: w, h: h, ksize: 21, iterations: 1)

        let area = countWhitePixels(mask)
        let ratio = Double(area) / Double(w * h)
        guard ratio <= 0.80 else { return nil }
        return mask
    }

    // MARK: - Hough Lines

    struct HoughLine { var rho: Double; var theta: Double }

    /// Canny エッジ検出 + HoughLines（Python の get_hough_lines に対応）
    private func houghLines(mask: [UInt8], w: Int, h: Int, scale: Int, threshold: Int) -> [HoughLine] {
        // Canny エッジ（Sobel 近似）
        let edges = cannyEdges(mask, w: w, h: h)

        // スケールダウン
        let sw = w / scale, sh = h / scale
        let small = downsample(edges, srcW: w, srcH: h, dstW: sw, dstH: sh)

        // Hough Transform
        return houghTransform(small, w: sw, h: sh, scale: scale, threshold: threshold)
    }

    private func houghTransform(_ mask: [UInt8], w: Int, h: Int, scale: Int, threshold: Int) -> [HoughLine] {
        let diagLen = Int(sqrt(Double(w * w + h * h))) + 1
        let numTheta = 180
        let numRho = diagLen * 2
        var accum = [Int](repeating: 0, count: numRho * numTheta)

        // 事前計算
        var cosTable = [Double](repeating: 0, count: numTheta)
        var sinTable = [Double](repeating: 0, count: numTheta)
        for t in 0..<numTheta {
            let angle = Double(t) * .pi / Double(numTheta)
            cosTable[t] = cos(angle)
            sinTable[t] = sin(angle)
        }

        // 投票
        for y in 0..<h {
            for x in 0..<w {
                guard mask[y * w + x] > 0 else { continue }
                for t in 0..<numTheta {
                    let rho = Double(x) * cosTable[t] + Double(y) * sinTable[t]
                    let rhoIdx = Int(rho) + diagLen
                    if rhoIdx >= 0 && rhoIdx < numRho {
                        accum[rhoIdx * numTheta + t] += 1
                    }
                }
            }
        }

        // 閾値以上のピーク抽出
        var result: [HoughLine] = []
        for rhoIdx in 0..<numRho {
            for t in 0..<numTheta {
                let votes = accum[rhoIdx * numTheta + t]
                guard votes >= threshold else { continue }
                let rho   = (Double(rhoIdx) - Double(diagLen)) * Double(scale)
                let theta = Double(t) * .pi / Double(numTheta)
                result.append(HoughLine(rho: rho, theta: theta))
            }
        }
        return result
    }

    // MARK: - Line Intersection

    private func lineIntersection(_ l1: HoughLine, _ l2: HoughLine) -> CGPoint? {
        // rho = x*cos(theta) + y*sin(theta)
        let c1 = cos(l1.theta), s1 = sin(l1.theta)
        let c2 = cos(l2.theta), s2 = sin(l2.theta)
        let det = c1 * s2 - c2 * s1
        guard abs(det) > 1e-6 else { return nil }
        let x = (l1.rho * s2 - l2.rho * s1) / det
        let y = (l2.rho * c1 - l1.rho * c2) / det
        return CGPoint(x: x, y: y)
    }

    private func normalizeTheta(_ theta: Double) -> Double {
        var t = theta
        if t > .pi { t -= .pi }
        if t < 0   { t += .pi }
        return t
    }

    private func deduplicate(lines: [HoughLine], distThresh: Double) -> [HoughLine] {
        var result: [HoughLine] = []
        for l in lines {
            if result.isEmpty || abs(l.rho - result.last!.rho) > distThresh {
                result.append(l)
            }
        }
        return result
    }

    // MARK: - Image Processing Utilities

    private func rgbToHSV(r: Int, g: Int, b: Int) -> (h: Double, s: Int, v: Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let cmax = max(rf, gf, bf), cmin = min(rf, gf, bf)
        let delta = cmax - cmin
        let v = Int(cmax * 255)
        let s = cmax > 0 ? Int((delta / cmax) * 255) : 0
        var h: Double = 0
        if delta > 0 {
            switch cmax {
            case rf: h = 60 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6))
            case gf: h = 60 * (((bf - rf) / delta) + 2)
            default: h = 60 * (((rf - gf) / delta) + 4)
            }
            if h < 0 { h += 360 }
        }
        return (h, s, v)
    }

    private func countWhitePixels(_ mask: [UInt8]) -> Int {
        mask.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
    }

    /// 簡易 box blur（ガウスブラー近似）
    private func boxBlur(_ input: [UInt8], w: Int, h: Int, radius: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        let r = radius
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0, count = 0
                for dy in -r...r {
                    for dx in -r...r {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0 && nx < w && ny >= 0 && ny < h else { continue }
                        sum += Int(input[ny * w + nx])
                        count += 1
                    }
                }
                out[y * w + x] = UInt8(clamping: sum / max(count, 1))
            }
        }
        return out
    }

    /// Sobel ベースの Canny エッジ近似
    private func cannyEdges(_ input: [UInt8], w: Int, h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 1..<(h-1) {
            for x in 1..<(w-1) {
                let gx = Int(input[(y-1)*w+(x+1)]) + 2*Int(input[y*w+(x+1)]) + Int(input[(y+1)*w+(x+1)])
                        - Int(input[(y-1)*w+(x-1)]) - 2*Int(input[y*w+(x-1)]) - Int(input[(y+1)*w+(x-1)])
                let gy = Int(input[(y+1)*w+(x-1)]) + 2*Int(input[(y+1)*w+x]) + Int(input[(y+1)*w+(x+1)])
                        - Int(input[(y-1)*w+(x-1)]) - 2*Int(input[(y-1)*w+x]) - Int(input[(y-1)*w+(x+1)])
                let mag = Int(sqrt(Double(gx*gx + gy*gy)))
                out[y * w + x] = UInt8(clamping: min(mag, 255))
            }
        }
        // 閾値 30（Python の Canny lowThreshold=30 に対応）
        return out.map { $0 > 30 ? 255 : 0 }
    }

    /// ダウンサンプリング（最近傍）
    private func downsample(_ src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: dstW * dstH)
        for y in 0..<dstH {
            for x in 0..<dstW {
                let sx = x * srcW / dstW, sy = y * srcH / dstH
                out[y * dstW + x] = src[sy * srcW + sx]
            }
        }
        return out
    }

    // MARK: - Morphology

func morphClose(_ input: [UInt8], w: Int, h: Int, ksize: Int, iterations: Int) -> [UInt8] {
        var cur = input
        for _ in 0..<iterations { cur = dilateFast(cur, w: w, h: h, ksize: ksize) }
        for _ in 0..<iterations { cur = erodeFast(cur, w: w, h: h, ksize: ksize) }
        return cur
    }

    func morphOpen(_ input: [UInt8], w: Int, h: Int, ksize: Int, iterations: Int) -> [UInt8] {
        var cur = input
        for _ in 0..<iterations { cur = erodeFast(cur, w: w, h: h, ksize: ksize) }
        for _ in 0..<iterations { cur = dilateFast(cur, w: w, h: h, ksize: ksize) }
        return cur
    }

    func dilateFast(_ input: [UInt8], w: Int, h: Int, ksize: Int) -> [UInt8] {
        var inputCopy = input
        var outData = [UInt8](repeating: 0, count: w * h)
        inputCopy.withUnsafeMutableBytes { inPtr in
            outData.withUnsafeMutableBytes { outPtr in
                var inBuf = vImage_Buffer(data: inPtr.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var outBuf = vImage_Buffer(data: outPtr.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageMax_Planar8(&inBuf, &outBuf, nil, 0, 0, vImagePixelCount(ksize), vImagePixelCount(ksize), vImage_Flags(kvImageDoNotTile))
            }
        }
        return outData
    }

    func erodeFast(_ input: [UInt8], w: Int, h: Int, ksize: Int) -> [UInt8] {
        var inputCopy = input
        var outData = [UInt8](repeating: 0, count: w * h)
        inputCopy.withUnsafeMutableBytes { inPtr in
            outData.withUnsafeMutableBytes { outPtr in
                var inBuf = vImage_Buffer(data: inPtr.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var outBuf = vImage_Buffer(data: outPtr.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageMin_Planar8(&inBuf, &outBuf, nil, 0, 0, vImagePixelCount(ksize), vImagePixelCount(ksize), vImage_Flags(kvImageDoNotTile))
            }
        }
        return outData
    }

    // Keeping original signatures to avoid breaking other calls
    private func dilate(_ input: [UInt8], w: Int, h: Int, ksize: Int) -> [UInt8] { return dilateFast(input, w: w, h: h, ksize: ksize) }
    private func erode(_ input: [UInt8], w: Int, h: Int, ksize: Int) -> [UInt8] { return erodeFast(input, w: w, h: h, ksize: ksize) }
}
