import Foundation
import CoreImage
import CoreGraphics
import ImageIO

// MARK: - VisionManager + Perspective Correction (Task 2.4)
//
// Python 版 warp_cheki() の CIPerspectiveCorrection ポート
// 透視変換後に標準拍立得比率 (86/54 ≈ 1.593) にロック

extension VisionManager {

    // MARK: - Perspective Correct

    /// CIPerspectiveCorrection で透視拉直し、比率ロック + 4K リサイズ
    ///
    /// - Parameters:
    ///   - image: 前処理済み CGImage
    ///   - corners: 偵測された四角点 [TL, TR, BR, BL]（ピクセル座標）
    ///   - detection: 偵測メタ情報
    ///   - format: 相紙規格（.auto の場合は長短比から自動選択）
    func perspectiveCorrect(
        image: CGImage,
        corners: [CGPoint],
        detection: DetectionResult,
        format: ChekiFilmFormat
    ) throws -> CropResult {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        // 四角点を正順（TL, TR, BR, BL）に並び替え
        let ordered = VisionManager.orderPoints(corners)
        guard ordered.count == 4 else { throw VisionError.perspectiveCorrectionFailed }

        let tl = ordered[0], tr = ordered[1], br = ordered[2], bl = ordered[3]

        // 縦横判定：w_top < h_left なら縦向きチェキ（通常）
        let wTop = hypot(tr.x - tl.x, tr.y - tl.y)
        let hLeft = hypot(bl.x - tl.x, bl.y - tl.y)

        // 縦長になるよう回転
        let (finalTL, finalTR, finalBR, finalBL): (CGPoint, CGPoint, CGPoint, CGPoint)
        if wTop > hLeft {
            // 横向き → 90° 回転してチェキを縦に
            finalTL = bl; finalTR = tl; finalBR = tr; finalBL = br
        } else {
            finalTL = tl; finalTR = tr; finalBR = br; finalBL = bl
        }

        // CIPerspectiveCorrection は Vision 座標系 (y 上向き, 0~1 正規化) を使用
        // → ピクセル座標を正規化 + y 反転
        func normalize(_ pt: CGPoint) -> CIVector {
            CIVector(x: pt.x / imgW, y: (imgH - pt.y) / imgH)
        }

        let ciImage = CIImage(cgImage: image)

        // CIFilter の inputTopLeft は Vision 座標系（左下原点）
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw VisionError.perspectiveCorrectionFailed
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(normalize(finalTL), forKey: "inputTopLeft")
        filter.setValue(normalize(finalTR), forKey: "inputTopRight")
        filter.setValue(normalize(finalBR), forKey: "inputBottomRight")
        filter.setValue(normalize(finalBL), forKey: "inputBottomLeft")

        guard let corrected = filter.outputImage else {
            throw VisionError.perspectiveCorrectionFailed
        }

        // 出力サイズ決定（比率ロック + 4K）
        let outputSize = resolveOutputSize(
            from: corrected.extent.size,
            format: resolveFormat(from: detection, requestedFormat: format)
        )

        // Lanczos リサンプリング（Python の cv2.INTER_LANCZOS4 相当）
        guard let scaled = applyLanczosResize(image: corrected, targetSize: outputSize) else {
            throw VisionError.perspectiveCorrectionFailed
        }

        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let finalCG = ctx.createCGImage(scaled, from: scaled.extent) else {
            throw VisionError.perspectiveCorrectionFailed
        }

        return CropResult(
            cgImage: finalCG,
            outputSize: outputSize,
            detectionResult: detection
        )
    }

    // MARK: - Format Auto Resolution

    private func resolveFormat(
        from detection: DetectionResult,
        requestedFormat: ChekiFilmFormat
    ) -> ChekiFilmFormat {
        if requestedFormat != .auto { return requestedFormat }
        let ratio = VisionManager.quadAspectRatio(detection.corners)
        // ratio 近傍で最良のフォーマットを選ぶ
        let formats: [ChekiFilmFormat] = [.mini, .square, .wide]
        return formats.min(by: { abs($0.aspectRatio - ratio) < abs($1.aspectRatio - ratio) }) ?? .mini
    }

    // MARK: - Output Size

    /// 4K 出力サイズ計算（長辺 3840px 固定、短辺は比率から逆算）
    private func resolveOutputSize(from rawSize: CGSize, format: ChekiFilmFormat) -> CGSize {
        let longEdge = Double(ChekiFilmFormat.outputLongEdgePx)   // 3840
        let ratio = format == .auto ? 86.0/54.0 : format.aspectRatio
        let isPortrait = rawSize.height >= rawSize.width
        if isPortrait {
            // 縦向き：高さ = 3840, 幅 = 3840 / ratio
            let h = longEdge
            let w = h / ratio
            return CGSize(width: w, height: h)
        } else {
            // 横向き（Wide）
            let w = longEdge
            let h = w / ratio
            return CGSize(width: w, height: h)
        }
    }

    // MARK: - Lanczos Resize

    private func applyLanczosResize(image: CIImage, targetSize: CGSize) -> CIImage? {
        // CILanczosScaleTransform
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return image
        }
        let scaleX = targetSize.width  / image.extent.width
        let scaleY = targetSize.height / image.extent.height
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
        return filter.outputImage
    }

    // MARK: - Save Result

    /// 指定パスに JPEG 出力（Benchmark ツール用）
    func save(result: CropResult, to url: URL, quality: Double = 0.90) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { throw VisionError.perspectiveCorrectionFailed }

        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, result.cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw VisionError.perspectiveCorrectionFailed
        }
    }
}
