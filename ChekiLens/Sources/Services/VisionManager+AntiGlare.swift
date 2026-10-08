import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Task 5.4: 反光與光影處理機制 (Mode A 單張高光抑制 & Mode B Pro 雙角度去反光合成管線)

extension VisionManager {

    /// Mode B 雙角度去反光合成輸出結果
    struct ModeBAntiGlareResult: Sendable {
        /// 雙角度對位並消除反光白斑後的最終透視校正影像
        let fusedCGImage: CGImage
        /// 第 1 張角度之透視校正結果
        let primaryCropResult: CropResult
        /// 第 2 張角度之透視校正結果
        let secondaryCropResult: CropResult
        /// 第 1 張角度之四角偵測結果（用於保存 normalized corners）
        let primaryDetection: DetectionResult
        /// 合成前反光高光區域佔比 (0.0 ~ 1.0)
        let glareRatioBefore: Double
        /// 合成後殘留反光區域佔比 (0.0 ~ 1.0)
        let glareRatioAfter: Double
        /// 自動判定之底片具體規格
        let resolvedFormat: FilmFormat
    }

    private var sRGBColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func makeAntiGlareCIContext() -> CIContext {
        CIContext(options: [
            .workingColorSpace: sRGBColorSpace,
            .outputColorSpace: sRGBColorSpace
        ])
    }

    private func mapToChekiFilmFormat(_ format: FilmFormat) -> ChekiFilmFormat {
        switch format {
        case .mini:   return .mini
        case .square: return .square
        case .wide:   return .wide
        case .auto:   return .auto
        }
    }

    // MARK: - Mode A: 單張智慧高光抑制 (免費版預設 & 基礎動態範圍補償)

    /// 使用 Core Image `CIHighlightShadowAdjust` 與局部對比補償壓制單張翻拍時的輕微反光白霧，同時保留拍立得白邊細節。
    func applyModeAGlareSuppression(to cgImage: CGImage) -> CGImage {
        let ciInput = CIImage(cgImage: cgImage)
        let extent = ciInput.extent
        guard !extent.isEmpty else { return cgImage }

        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = ciInput
        highlightShadow.highlightAmount = 0.74 // 壓制過曝高光白霧
        highlightShadow.shadowAmount = 0.08    // 微提暗部層次

        guard let step1 = highlightShadow.outputImage else { return cgImage }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = step1
        colorControls.contrast = 1.03
        colorControls.saturation = 1.02
        colorControls.brightness = -0.008

        let context = makeAntiGlareCIContext()
        guard let outputCI = colorControls.outputImage?.cropped(to: extent),
              let rendered = context.createCGImage(outputCI, from: extent, format: .RGBA8, colorSpace: sRGBColorSpace) else {
            return cgImage
        }
        return rendered
    }

    // MARK: - Mode B: 雙角度去反光合成管線 (Pro 專屬功能)

    /// 透過兩個微傾角度拍攝的拍立得照片 (`primaryImage` 與 `secondaryImage`)：
    /// 1. 分別執行混合式四角偵測與 `CIPerspectiveCorrection` 正位至相同的標準物理畫布尺寸。
    /// 2. 透過 Apple Vision `VNTranslationalImageRegistrationRequest` 進行次像素級別微對位。
    /// 3. 於內部相片區域偵測鏡面反光白斑（高亮度、低飽和且兩角度存在顯著亮度差之像素），
    ///    建立空間平滑羽化權重遮罩，以無反光角度的乾淨像素無縫替換反光白斑。
    func synthesizeModeBDualAngleAntiGlare(
        primaryImage: CGImage,
        secondaryImage: CGImage,
        borderInsetRatio: Double = 0.0,
        preferredFormat: FilmFormat = .auto
    ) async throws -> ModeBAntiGlareResult {
        let primarySize = CGSize(width: primaryImage.width, height: primaryImage.height)
        let secondarySize = CGSize(width: secondaryImage.width, height: secondaryImage.height)
        let chekiFormat = mapToChekiFilmFormat(preferredFormat)

        // 1. 分別對角度 A 與角度 B 執行高精度四角偵測與透視正位
        let detectionA = try await detectQuad(in: primaryImage, imageSize: primarySize)
        let cornersA = applyBorderInset(
            corners: detectionA.corners,
            imageSize: primarySize,
            ratio: borderInsetRatio
        )
        let adjustedDetectionA = DetectionResult(
            corners: cornersA,
            method: detectionA.method,
            confidence: detectionA.confidence,
            imageSize: primarySize
        )
        let cropA = try perspectiveCorrect(
            image: primaryImage,
            corners: cornersA,
            detection: adjustedDetectionA,
            format: chekiFormat
        )

        let resolvedFormat = FilmFormat.resolvedConcreteFormat(
            preferred: preferredFormat,
            specName: cropA.filmSpecification?.format.rawValue,
            outputSize: cropA.outputSize
        )

        let detectionB = try await detectQuad(in: secondaryImage, imageSize: secondarySize)
        let cornersB = applyBorderInset(
            corners: detectionB.corners,
            imageSize: secondarySize,
            ratio: borderInsetRatio
        )
        let adjustedDetectionB = DetectionResult(
            corners: cornersB,
            method: detectionB.method,
            confidence: detectionB.confidence,
            imageSize: secondarySize
        )
        let cropB = try perspectiveCorrect(
            image: secondaryImage,
            corners: cornersB,
            detection: adjustedDetectionB,
            format: mapToChekiFilmFormat(resolvedFormat)
        )

        // 2. 將角度 B 對齊至與角度 A 完全相同的畫布尺寸，並執行 Vision 次像素配準
        let alignedImageB = alignSecondaryCroppedImage(
            reference: cropA.cgImage,
            floating: cropB.cgImage
        )

        // 3. 執行雙角度高光白斑遮罩檢測與羽化像素融合
        let (fusedRaw, glareBefore, glareAfter) = fuseDualAngleAlignedImages(
            imageA: cropA.cgImage,
            imageB: alignedImageB
        )

        // 4. 結合 Mode A 輕量高光平衡完成最終潤飾
        let finalCGImage = applyModeAGlareSuppression(to: fusedRaw)

        return ModeBAntiGlareResult(
            fusedCGImage: finalCGImage,
            primaryCropResult: cropA,
            secondaryCropResult: cropB,
            primaryDetection: adjustedDetectionA,
            glareRatioBefore: glareBefore,
            glareRatioAfter: glareAfter,
            resolvedFormat: resolvedFormat
        )
    }

    // MARK: - Internal Alignment & Specular Glare Fusion Helpers

    /// 將第二角度正位圖縮放至與第一角度相同尺寸，並使用 `VNTranslationalImageRegistrationRequest` 補償微小平移偏移
    private func alignSecondaryCroppedImage(reference: CGImage, floating: CGImage) -> CGImage {
        let targetWidth = reference.width
        let targetHeight = reference.height
        let targetExtent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let context = makeAntiGlareCIContext()

        var ciFloating = CIImage(cgImage: floating)
        let scaleX = CGFloat(targetWidth) / max(1.0, ciFloating.extent.width)
        let scaleY = CGFloat(targetHeight) / max(1.0, ciFloating.extent.height)
        if abs(scaleX - 1.0) > 0.001 || abs(scaleY - 1.0) > 0.001 {
            ciFloating = ciFloating.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        // 先渲染為相同尺寸的 CGImage 供 Vision Registration 比對
        let resizedFloating = context.createCGImage(
            ciFloating.cropped(to: targetExtent),
            from: targetExtent,
            format: .RGBA8,
            colorSpace: sRGBColorSpace
        ) ?? floating

        let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: reference)
        let handler = VNImageRequestHandler(cgImage: resizedFloating, options: [:])
        try? handler.perform([registrationRequest])

        if let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation {
            let transform = observation.alignmentTransform
            // 僅在合理微調範圍內套用配準位移（小於畫布 6%），避免因強反光區塊誤導而過度偏移外框
            let maxShiftX = CGFloat(targetWidth) * 0.06
            let maxShiftY = CGFloat(targetHeight) * 0.06
            if abs(transform.tx) <= maxShiftX && abs(transform.ty) <= maxShiftY {
                let translated = CIImage(cgImage: resizedFloating)
                    .transformed(by: transform)
                    .clampedToExtent()
                    .cropped(to: targetExtent)
                if let aligned = context.createCGImage(translated, from: targetExtent, format: .RGBA8, colorSpace: sRGBColorSpace) {
                    return aligned
                }
            }
        }

        return resizedFloating
    }

    /// 像素級雙角度反光偵測與空間羽化融合：
    /// - 保護拍立得四周白邊與底部手寫簽名區（維持第 1 張的銳利字跡）
    /// - 在內部相片區比較兩張角度之亮度 ($L_A, L_B$) 與飽和度 ($S_A, S_B$)，
    ///   當某角度出現強光白斑（亮度明顯高於另一張且飽和度下降）時，自動平滑切換至另一張無反光角度的像素。
    private func fuseDualAngleAlignedImages(
        imageA: CGImage,
        imageB: CGImage
    ) -> (fused: CGImage, glareBefore: Double, glareAfter: Double) {
        let width = imageA.width
        let height = imageA.height
        guard width > 16, height > 16,
              imageB.width == width, imageB.height == height else {
            return (imageA, 0.0, 0.0)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow
        let colorSpace = sRGBColorSpace

        var bufferA = [UInt8](repeating: 0, count: totalBytes)
        var bufferB = [UInt8](repeating: 0, count: totalBytes)

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctxA = CGContext(
            data: &bufferA,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let ctxB = CGContext(
            data: &bufferB,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return (imageA, 0.0, 0.0)
        }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        ctxA.draw(imageA, in: fullRect)
        ctxB.draw(imageB, in: fullRect)

        // 定義拍立得內部相片區邊界（留出四周白框與下巴手寫區，避免下巴手寫簽名產生雙影）
        let isPortraitOrSquare = height >= width
        let leftMargin = Int(Double(width) * 0.055)
        let rightMargin = Int(Double(width) * 0.945)
        let topMargin = Int(Double(height) * 0.050)
        let bottomMargin = Int(Double(height) * (isPortraitOrSquare ? 0.80 : 0.86))
        let featherBand = max(6, min(width, height) / 36)

        // 1. 計算每個像素對角度 B 的融合權重 (0.0 = 完全取角度 A, 1.0 = 完全取角度 B)
        var weightB = [Float](repeating: 0.0, count: width * height)
        var glareCountBefore = 0
        var innerPixelCount = 0

        for y in topMargin..<bottomMargin {
            let dyTop = min(featherBand, y - topMargin)
            let dyBottom = min(featherBand, bottomMargin - 1 - y)
            let fy = Float(min(dyTop, dyBottom)) / Float(featherBand)

            for x in leftMargin..<rightMargin {
                let dxLeft = min(featherBand, x - leftMargin)
                let dxRight = min(featherBand, rightMargin - 1 - x)
                let fx = Float(min(dxLeft, dxRight)) / Float(featherBand)
                let regionMask = min(1.0, fx * fy)

                let idx = (y * width + x) * 4
                let rA = Float(bufferA[idx]) / 255.0
                let gA = Float(bufferA[idx + 1]) / 255.0
                let bA = Float(bufferA[idx + 2]) / 255.0

                let rB = Float(bufferB[idx]) / 255.0
                let gB = Float(bufferB[idx + 1]) / 255.0
                let bB = Float(bufferB[idx + 2]) / 255.0

                let lumA = 0.299 * rA + 0.587 * gA + 0.114 * bA
                let lumB = 0.299 * rB + 0.587 * gB + 0.114 * bB

                let maxA = max(rA, max(gA, bA))
                let minA = min(rA, min(gA, bA))
                let satA = maxA > 0.01 ? (maxA - minA) / maxA : 0.0

                let maxB = max(rB, max(gB, bB))
                let minB = min(rB, min(gB, bB))
                let satB = maxB > 0.01 ? (maxB - minB) / maxB : 0.0

                innerPixelCount += 1
                if (lumA > 0.72 && satA < 0.28) || (lumA - lumB > 0.12 && lumA > 0.58) {
                    glareCountBefore += 1
                }

                // 反光指標：結合亮度與低飽和沖淡感 (glareScore 越高代表越像塑膠膜強光白斑)
                let glareScoreA = lumA * (1.0 - 0.45 * satA)
                let glareScoreB = lumB * (1.0 - 0.45 * satB)
                let diff = glareScoreA - glareScoreB

                let rawWeightB: Float
                if diff > 0.035 {
                    // 角度 A 比角度 B 明顯更亮/更泛白 -> 判定角度 A 在此處有反光，平滑替換為角度 B 像素
                    let normalized = min(1.0, (diff - 0.035) / 0.16)
                    rawWeightB = 0.22 + 0.78 * normalized
                } else if diff < -0.035 {
                    // 角度 B 在此處有反光 -> 嚴格保留角度 A 的乾淨像素
                    let normalized = min(1.0, (-diff - 0.035) / 0.16)
                    rawWeightB = 0.22 * (1.0 - normalized)
                } else {
                    // 兩張皆無明顯反光 -> 以 82% 角度 A + 18% 角度 B 輕微降噪融合
                    rawWeightB = 0.18
                }

                weightB[y * width + x] = rawWeightB * regionMask
            }
        }

        // 2. 對融合權重遮罩進行快速水平+垂直平滑濾波（消除反光交界處的接縫感）
        let smoothedWeightB = smoothWeightMap(weightB, width: width, height: height, radius: max(3, min(width, height) / 80))

        // 3. 逐像素融合輸出並統計合成後殘留高光
        var outputBuffer = bufferA
        var glareCountAfter = 0

        for y in topMargin..<bottomMargin {
            for x in leftMargin..<rightMargin {
                let wB = smoothedWeightB[y * width + x]
                let wA = 1.0 - wB
                let idx = (y * width + x) * 4

                let rOut = wA * Float(bufferA[idx]) + wB * Float(bufferB[idx])
                let gOut = wA * Float(bufferA[idx + 1]) + wB * Float(bufferB[idx + 1])
                let bOut = wA * Float(bufferA[idx + 2]) + wB * Float(bufferB[idx + 2])

                outputBuffer[idx]     = UInt8(min(255, max(0, Int(rOut.rounded()))))
                outputBuffer[idx + 1] = UInt8(min(255, max(0, Int(gOut.rounded()))))
                outputBuffer[idx + 2] = UInt8(min(255, max(0, Int(bOut.rounded()))))
                outputBuffer[idx + 3] = 255

                let lumOut = (0.299 * rOut + 0.587 * gOut + 0.114 * bOut) / 255.0
                let maxOut = max(rOut, max(gOut, bOut)) / 255.0
                let minOut = min(rOut, min(gOut, bOut)) / 255.0
                let satOut = maxOut > 0.01 ? (maxOut - minOut) / maxOut : 0.0
                if lumOut > 0.78 && satOut < 0.22 {
                    glareCountAfter += 1
                }
            }
        }

        let ratioBefore = innerPixelCount > 0 ? Double(glareCountBefore) / Double(innerPixelCount) : 0.0
        let ratioAfter = innerPixelCount > 0 ? Double(glareCountAfter) / Double(innerPixelCount) : 0.0

        guard let outCtx = CGContext(
            data: &outputBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let fusedCG = outCtx.makeImage() else {
            return (imageA, ratioBefore, ratioAfter)
        }

        return (fusedCG, ratioBefore, ratioAfter)
    }

    /// 可分離雙向均值盒狀濾波器（近似高斯羽化，O(N) 複雜度，不阻塞執行緒）
    private func smoothWeightMap(_ input: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return input }
        var temp = input
        var output = input
        let windowSize = Float(radius * 2 + 1)

        // 水平平滑
        for y in 0..<height {
            let rowOffset = y * width
            for x in radius..<(width - radius) {
                var sum: Float = 0
                for k in -radius...radius {
                    sum += input[rowOffset + x + k]
                }
                temp[rowOffset + x] = sum / windowSize
            }
        }

        // 垂直平滑
        for y in radius..<(height - radius) {
            for x in 0..<width {
                var sum: Float = 0
                for k in -radius...radius {
                    sum += temp[(y + k) * width + x]
                }
                output[y * width + x] = sum / windowSize
            }
        }

        return output
    }
}
