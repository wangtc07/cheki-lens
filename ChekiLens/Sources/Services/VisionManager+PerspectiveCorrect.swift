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
        format: ChekiFilmFormat,
        preserveCornerOrder: Bool = false
    ) throws -> CropResult {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        // 四角点を正順（TL, TR, BR, BL）に並び替え（手動四頂點編輯器則直接保留 [TL, TR, BR, BL] 索引順序）
        let ordered = preserveCornerOrder ? corners : VisionManager.orderPoints(corners)
        guard ordered.count == 4 else { throw VisionError.perspectiveCorrectionFailed }

        let tl = ordered[0], tr = ordered[1], br = ordered[2], bl = ordered[3]

        // 保持原始偵測方向，不強制旋轉。這樣可以支援橫向的 Wide 規格，並且避免背面 (Backside) 被錯誤旋轉
        let (finalTL, finalTR, finalBR, finalBL) = (tl, tr, br, bl)

        // Core Image 座標系：原點在左下角（y 軸朝上），坐標以像素（Pixel）為單位，不可除以寬高做正規化
        func toCoreImageVector(_ pt: CGPoint) -> CIVector {
            CIVector(x: pt.x, y: imgH - pt.y)
        }

        let baseCIImage = CIImage(cgImage: image)
        // 若手動調整的四個頂點超出原始相片範圍（例如傾斜拍立得的白邊尖角稍微超出畫面左/右緣），
        // 透過 clampedToExtent() 延伸邊緣像素（自動延續相紙白邊色澤，避免超出區域變成黑色三角缺角）
        let ciPts = [finalTL, finalTR, finalBR, finalBL].map { CGPoint(x: $0.x, y: imgH - $0.y) }
        let minCIX = min(0, ciPts.map(\.x).min() ?? 0)
        let maxCIX = max(imgW, ciPts.map(\.x).max() ?? imgW)
        let minCIY = min(0, ciPts.map(\.y).min() ?? 0)
        let maxCIY = max(imgH, ciPts.map(\.y).max() ?? imgH)

        let ciImage: CIImage
        if minCIX < 0 || maxCIX > imgW || minCIY < 0 || maxCIY > imgH {
            let expandedExtent = CGRect(
                x: floor(minCIX) - 8,
                y: floor(minCIY) - 8,
                width: ceil(maxCIX - minCIX) + 16,
                height: ceil(maxCIY - minCIY) + 16
            )
            ciImage = baseCIImage.clampedToExtent().cropped(to: expandedExtent)
        } else {
            ciImage = baseCIImage
        }

        // CIFilter の inputTopLeft は Core Image 座標系（左下原點，以像素為單位）
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw VisionError.perspectiveCorrectionFailed
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(toCoreImageVector(finalTL), forKey: "inputTopLeft")
        filter.setValue(toCoreImageVector(finalTR), forKey: "inputTopRight")
        filter.setValue(toCoreImageVector(finalBR), forKey: "inputBottomRight")
        filter.setValue(toCoreImageVector(finalBL), forKey: "inputBottomLeft")


        guard let corrected = filter.outputImage else {
            throw VisionError.perspectiveCorrectionFailed
        }

        // 規格與方向智能分類 (Task 2.8.1: AspectRatioClassifier)
        let spec = AspectRatioClassifier.classify(corners: ordered, requestedFormat: format)
        let outputSize = spec.standardOutputSize

        // Lanczos 重採樣 (Python cv2.INTER_LANCZOS4 等效)
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
            detectionResult: detection,
            filmSpecification: spec
        )
    }

    // MARK: - Legacy Resolvers (Delegated to AspectRatioClassifier)

    private func resolveFormat(
        from detection: DetectionResult,
        requestedFormat: ChekiFilmFormat
    ) -> ChekiFilmFormat {
        let spec = AspectRatioClassifier.classify(corners: detection.corners, requestedFormat: requestedFormat)
        return spec.format
    }

    private func resolveOutputSize(from rawSize: CGSize, format: ChekiFilmFormat) -> CGSize {
        let isLandscape = rawSize.width > rawSize.height
        let orientation: ChekiOrientation = isLandscape ? .landscape : .portrait
        let spec = AspectRatioClassifier.specification(for: format, orientation: orientation)
        return spec.standardOutputSize
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
