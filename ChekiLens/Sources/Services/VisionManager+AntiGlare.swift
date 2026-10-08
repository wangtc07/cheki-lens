import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Task 5.4 & 6.1: 反光與光影處理機制 (Mode A 單張高光抑制 & Mode B Pro 極速雙角度去反光合成管線)

extension VisionManager {

    /// Mode B 第 1 張角度背景預處理結果（於使用者調整角度準備拍第 2 張的空檔先行算完，將第 2 張拍完後的等待時間砍半）
    struct ModeBPreparedFirstAngle: @unchecked Sendable {
        let originalCGImage: CGImage
        let originalSize: CGSize
        let cropResult: CropResult
        let adjustedDetection: DetectionResult
        let resolvedFormat: FilmFormat
        let ocrDate: Date?
    }

    /// Mode B 雙角度去反光合成輸出結果
    struct ModeBAntiGlareResult: @unchecked Sendable {
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
        /// 第 1 張預處理時已順帶辨識出的手寫日期（若有則免重複執行 OCR）
        let preRecognizedDate: Date?
    }

    private static let sharedSRGBColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 共用高效能 Metal CIContext（避免每次快門重複編譯 Core Image Metal Pipeline）
    private static let sharedAntiGlareCIContext: CIContext = CIContext(options: [
        .workingColorSpace: sharedSRGBColorSpace,
        .outputColorSpace: sharedSRGBColorSpace,
        .cacheIntermediates: false
    ])

    private var sRGBColorSpace: CGColorSpace {
        Self.sharedSRGBColorSpace
    }

    private func makeAntiGlareCIContext() -> CIContext {
        Self.sharedAntiGlareCIContext
    }

    private func mapToChekiFilmFormat(_ format: FilmFormat) -> ChekiFilmFormat {
        switch format {
        case .mini:   return .mini
        case .square: return .square
        case .wide:   return .wide
        case .auto:   return .auto
        }
    }

    // MARK: - Fast Front-Card Quad Detection (相機拍攝 12MP 原圖專用快速通道)

    /// 針對相機實拍之高解析度照片（如 12MP `3024×4032`），先降採樣至長邊 `1440px` 代理畫布執行快速四角偵測，
    /// 若已知為正面照 (`isKnownFrontPhoto == true`) 則略過背面 OCR 掃描，且當 Apple 原生 `VNDetectRectanglesRequest`
    /// 已命中高信心拍立得矩形時略過重複的 `CIDetectorAccuracyHigh`，再將四角座標等比例映射回 12MP 原圖。
    func detectQuadFastForCamera(
        in image: CGImage,
        imageSize: CGSize,
        isKnownFrontPhoto: Bool = true
    ) async throws -> DetectionResult {
        let maxProxySide: CGFloat = 1440.0
        let longSide = max(imageSize.width, imageSize.height)
        let scaleDown = longSide > maxProxySide ? (maxProxySide / longSide) : 1.0
        let proxySize = CGSize(
            width: max(1, round(imageSize.width * scaleDown)),
            height: max(1, round(imageSize.height * scaleDown))
        )

        let proxyCGImage: CGImage
        if scaleDown < 0.99,
           let downsampled = downsampleCGImage(image, to: proxySize) {
            proxyCGImage = downsampled
        } else {
            proxyCGImage = image
        }

        let actualProxySize = CGSize(width: proxyCGImage.width, height: proxyCGImage.height)
        let scaleBackX = imageSize.width / max(1.0, actualProxySize.width)
        let scaleBackY = imageSize.height / max(1.0, actualProxySize.height)

        // 若已知為正面照（例如一般拍照、Mode B 雙角度防反光），優先直接跑 Layer 1 Vision Native
        if isKnownFrontPhoto,
           let vRes = try? await detectVisionNative(image: proxyCGImage, imageSize: actualProxySize) {
            let proxyArea = actualProxySize.width * actualProxySize.height
            let quadAreaVal = VisionManager.quadArea(vRes.corners)
            if proxyArea > 0,
               quadAreaVal >= 0.08 * Double(proxyArea),
               VisionManager.isChekiRatio(vRes.corners) {
                var corners = vRes.corners
                let extraRes = FrameExtrapolator.checkAndExtrapolate(
                    corners: corners,
                    imageSize: actualProxySize,
                    image: proxyCGImage
                )
                if extraRes.isInnerFrame {
                    corners = extraRes.extrapolatedCorners
                }
                let refRes = VisionManager.refineQuadrilateral(
                    corners: corners,
                    imageSize: actualProxySize,
                    image: proxyCGImage
                )
                if refRes.wasRefined {
                    corners = refRes.corners
                }

                let fullResCorners = corners.map {
                    CGPoint(x: $0.x * scaleBackX, y: $0.y * scaleBackY)
                }
                return DetectionResult(
                    corners: fullResCorners,
                    method: vRes.method,
                    confidence: vRes.confidence,
                    imageSize: imageSize
                )
            }
        }

        // Fallback：在 1440px 代理圖上執行完整混合偵測並映射回原圖座標
        let proxyDetection = try await detectQuad(in: proxyCGImage, imageSize: actualProxySize)
        let fullResCorners = proxyDetection.corners.map {
            CGPoint(x: $0.x * scaleBackX, y: $0.y * scaleBackY)
        }
        return DetectionResult(
            corners: fullResCorners,
            method: proxyDetection.method,
            confidence: proxyDetection.confidence,
            imageSize: imageSize
        )
    }

    private func downsampleCGImage(_ image: CGImage, to targetSize: CGSize) -> CGImage? {
        let w = max(1, Int(targetSize.width.rounded()))
        let h = max(1, Int(targetSize.height.rounded()))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: Self.sharedSRGBColorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Mode A: 單張智慧高光抑制 (免費版預設 & 基礎動態範圍補償)

    /// 使用 Core Image `CIHighlightShadowAdjust` 與局部對比補償壓制單張翻拍時的輕微反光白霧，同時保留拍立得白邊細節。
    func applyModeAGlareSuppression(to cgImage: CGImage) -> CGImage {
        let ciInput = CIImage(cgImage: cgImage)
        let extent = ciInput.extent
        guard !extent.isEmpty else { return cgImage }

        let polishedCI = applyModeAGlareSuppressionFilter(to: ciInput)
        let context = Self.sharedAntiGlareCIContext
        guard let rendered = context.createCGImage(polishedCI, from: extent, format: .RGBA8, colorSpace: Self.sharedSRGBColorSpace) else {
            return cgImage
        }
        return rendered
    }

    private func applyModeAGlareSuppressionFilter(to ciInput: CIImage) -> CIImage {
        let extent = ciInput.extent
        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = ciInput
        highlightShadow.highlightAmount = 0.74 // 壓制過曝高光白霧
        highlightShadow.shadowAmount = 0.08    // 微提暗部層次

        guard let step1 = highlightShadow.outputImage else { return ciInput }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = step1
        colorControls.contrast = 1.03
        colorControls.saturation = 1.02
        colorControls.brightness = -0.008

        return colorControls.outputImage?.cropped(to: extent) ?? step1.cropped(to: extent)
    }

    // MARK: - Mode B: 雙角度去反光合成管線 (Pro 專屬功能 — 支援第 1 張背景預處理 + GPU 遮罩融合)

    /// 在使用者拍下 Mode B 第 1 張後，趁使用者微調手機角度準備拍第 2 張的空檔，立即於背景先行完成第 1 張之四角偵測、透視正位與日期 OCR。
    func prepareModeBFirstAngle(
        primaryImage: CGImage,
        borderInsetRatio: Double = 0.0,
        preferredFormat: FilmFormat = .auto
    ) async throws -> ModeBPreparedFirstAngle {
        let primarySize = CGSize(width: primaryImage.width, height: primaryImage.height)
        let chekiFormat = mapToChekiFilmFormat(preferredFormat)

        let detectionA = try await detectQuadFastForCamera(
            in: primaryImage,
            imageSize: primarySize,
            isKnownFrontPhoto: true
        )
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
        let ocrDate = await recognizeDate(from: cropA.cgImage)?.date

        return ModeBPreparedFirstAngle(
            originalCGImage: primaryImage,
            originalSize: primarySize,
            cropResult: cropA,
            adjustedDetection: adjustedDetectionA,
            resolvedFormat: resolvedFormat,
            ocrDate: ocrDate
        )
    }

    /// 透過兩個微傾角度拍攝的拍立得照片 (`primaryImage` 與 `secondaryImage`) 執行極速去反光合成：
    /// - 若傳入 `preparedFirstAngle`，則直接重用第 1 張已完成之正位與 OCR 結果，第 2 張拍完後僅需處理第 2 張與 GPU 遮罩融合。
    func synthesizeModeBDualAngleAntiGlare(
        primaryImage: CGImage,
        secondaryImage: CGImage,
        borderInsetRatio: Double = 0.0,
        preferredFormat: FilmFormat = .auto,
        preparedFirstAngle: ModeBPreparedFirstAngle? = nil
    ) async throws -> ModeBAntiGlareResult {
        // 1. 取得角度 A 的正位結果（若有背景預處理結果則 0ms 直接取用）
        let firstPrepared: ModeBPreparedFirstAngle
        if let preparedFirstAngle {
            firstPrepared = preparedFirstAngle
        } else {
            firstPrepared = try await prepareModeBFirstAngle(
                primaryImage: primaryImage,
                borderInsetRatio: borderInsetRatio,
                preferredFormat: preferredFormat
            )
        }

        let cropA = firstPrepared.cropResult
        let adjustedDetectionA = firstPrepared.adjustedDetection
        let resolvedFormat = firstPrepared.resolvedFormat

        // 2. 對角度 B 執行快速四角偵測與透視正位
        let secondarySize = CGSize(width: secondaryImage.width, height: secondaryImage.height)
        let detectionB = try await detectQuadFastForCamera(
            in: secondaryImage,
            imageSize: secondarySize,
            isKnownFrontPhoto: true
        )
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

        // 3. 以 540p 輕量代理計算次像素平移配準，並將角度 B 的 CIImage 對齊至角度 A 的 4K 畫布
        let alignedSecondaryCI = alignSecondaryCroppedCIImage(
            reference: cropA.cgImage,
            floating: cropB.cgImage
        )

        // 4. 在 270×430 輕量分析網格計算雙角度高光白斑權重遮罩，並以 Core Image GPU CIBlendWithMask + Mode A 單次渲染輸出 4K 無反光成品
        let (finalCGImage, glareBefore, glareAfter) = fuseDualAngleWithGPUMask(
            imageA: cropA.cgImage,
            alignedCIImageB: alignedSecondaryCI
        )

        return ModeBAntiGlareResult(
            fusedCGImage: finalCGImage,
            primaryCropResult: cropA,
            secondaryCropResult: cropB,
            primaryDetection: adjustedDetectionA,
            glareRatioBefore: glareBefore,
            glareRatioAfter: glareAfter,
            resolvedFormat: resolvedFormat,
            preRecognizedDate: firstPrepared.ocrDate
        )
    }

    // MARK: - Fast Sub-Pixel Registration & GPU Specular Glare Fusion

    /// 使用 `540px` 輕量代理圖執行 `VNTranslationalImageRegistrationRequest`（耗時 < 15ms），
    /// 並將計算出的平移向量等比例套用回 4K `CIImage`，避免多次 4K CGImage 重複渲染。
    private func alignSecondaryCroppedCIImage(reference: CGImage, floating: CGImage) -> CIImage {
        let targetWidth = CGFloat(reference.width)
        let targetHeight = CGFloat(reference.height)
        let targetExtent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        var ciFloating = CIImage(cgImage: floating)
        let scaleX = targetWidth / max(1.0, ciFloating.extent.width)
        let scaleY = targetHeight / max(1.0, ciFloating.extent.height)
        if abs(scaleX - 1.0) > 0.001 || abs(scaleY - 1.0) > 0.001 {
            ciFloating = ciFloating.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        ciFloating = ciFloating.cropped(to: targetExtent)

        // 以長邊 540px 建立輕量配準代理圖
        let regScale = min(1.0, 540.0 / max(targetWidth, targetHeight))
        let regSize = CGSize(
            width: max(32, round(targetWidth * regScale)),
            height: max(32, round(targetHeight * regScale))
        )

        if let smallRef = downsampleCGImage(reference, to: regSize),
           let smallFloat = downsampleCGImage(floating, to: regSize) {
            let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: smallRef)
            let handler = VNImageRequestHandler(cgImage: smallFloat, options: [:])
            try? handler.perform([registrationRequest])

            if let observation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation {
                let smallTransform = observation.alignmentTransform
                let fullTx = smallTransform.tx / regScale
                let fullTy = smallTransform.ty / regScale
                let maxShiftX = targetWidth * 0.06
                let maxShiftY = targetHeight * 0.06
                if abs(fullTx) <= maxShiftX && abs(fullTy) <= maxShiftY {
                    let fullTransform = CGAffineTransform(translationX: fullTx, y: fullTy)
                    return ciFloating
                        .transformed(by: fullTransform)
                        .clampedToExtent()
                        .cropped(to: targetExtent)
                }
            }
        }

        return ciFloating
    }

    /// 極速 GPU 雙角度去反光融合：
    /// 1. 將兩張正位圖降採樣至 `270×430` 輕量分析網格（僅約 11.6 萬像素，比 4K 少 80 倍），
    /// 2. 計算內部相片區的鏡面反光白斑差異權重遮罩，並以 $O(1)$ 滑動視窗均值濾波平滑化（CPU 耗時 < 3ms），
    /// 3. 將權重遮罩轉為灰階 `CIImage` 放大至 4K 畫布，透過 GPU `CIBlendWithMask` + `applyModeAGlareSuppressionFilter` 單次渲染完成！
    private func fuseDualAngleWithGPUMask(
        imageA: CGImage,
        alignedCIImageB: CIImage
    ) -> (fused: CGImage, glareBefore: Double, glareAfter: Double) {
        let fullWidth = imageA.width
        let fullHeight = imageA.height
        let fullExtent = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        guard fullWidth > 16, fullHeight > 16 else {
            return (imageA, 0.0, 0.0)
        }

        // 建立輕量分析網格 (長邊固定約 430px，例如 Mini 為 270×430 = 116,100 px)
        let maxGridSide: Double = 430.0
        let gridScale = min(1.0, maxGridSide / Double(max(fullWidth, fullHeight)))
        let gridW = max(32, Int((Double(fullWidth) * gridScale).rounded()))
        let gridH = max(32, Int((Double(fullHeight) * gridScale).rounded()))
        let gridRect = CGRect(x: 0, y: 0, width: gridW, height: gridH)

        let bytesPerRow = gridW * 4
        let totalBytes = gridH * bytesPerRow
        let colorSpace = Self.sharedSRGBColorSpace
        let context = Self.sharedAntiGlareCIContext

        var bufferA = [UInt8](repeating: 0, count: totalBytes)
        var bufferB = [UInt8](repeating: 0, count: totalBytes)

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let smallB = context.createCGImage(
            alignedCIImageB.transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(gridW) / CGFloat(fullWidth),
                    y: CGFloat(gridH) / CGFloat(fullHeight)
                )
            ).cropped(to: gridRect),
            from: gridRect,
            format: .RGBA8,
            colorSpace: colorSpace
        ),
        let ctxA = CGContext(
            data: &bufferA,
            width: gridW,
            height: gridH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let ctxB = CGContext(
            data: &bufferB,
            width: gridW,
            height: gridH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return (imageA, 0.0, 0.0)
        }

        ctxA.interpolationQuality = .low
        ctxB.interpolationQuality = .low
        ctxA.draw(imageA, in: gridRect)
        ctxB.draw(smallB, in: gridRect)

        // 定義拍立得內部相片區邊界（保護四周白框與下巴手寫簽名區，維持第 1 張的銳利字跡）
        let isPortraitOrSquare = gridH >= gridW
        let leftMargin = Int(Double(gridW) * 0.055)
        let rightMargin = Int(Double(gridW) * 0.945)
        let topMargin = Int(Double(gridH) * 0.050)
        let bottomMargin = Int(Double(gridH) * (isPortraitOrSquare ? 0.80 : 0.86))
        let featherBand = max(4, min(gridW, gridH) / 28)

        var weightB = [Float](repeating: 0.0, count: gridW * gridH)
        var glareCountBefore = 0
        var innerPixelCount = 0

        for y in topMargin..<bottomMargin {
            let dyTop = min(featherBand, y - topMargin)
            let dyBottom = min(featherBand, bottomMargin - 1 - y)
            let fy = Float(min(dyTop, dyBottom)) / Float(featherBand)
            let rowOffset = y * gridW

            for x in leftMargin..<rightMargin {
                let dxLeft = min(featherBand, x - leftMargin)
                let dxRight = min(featherBand, rightMargin - 1 - x)
                let fx = Float(min(dxLeft, dxRight)) / Float(featherBand)
                let regionMask = min(1.0, fx * fy)

                let idx = (rowOffset + x) * 4
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

                let glareScoreA = lumA * (1.0 - 0.45 * satA)
                let glareScoreB = lumB * (1.0 - 0.45 * satB)
                let diff = glareScoreA - glareScoreB

                let rawWeightB: Float
                if diff > 0.035 {
                    let normalized = min(1.0, (diff - 0.035) / 0.16)
                    rawWeightB = 0.22 + 0.78 * normalized
                } else if diff < -0.035 {
                    let normalized = min(1.0, (-diff - 0.035) / 0.16)
                    rawWeightB = 0.22 * (1.0 - normalized)
                } else {
                    rawWeightB = 0.18
                }

                weightB[rowOffset + x] = rawWeightB * regionMask
            }
        }

        // O(1) 滑動視窗快速平滑權重遮罩（在 270×430 網格上僅需 < 2ms）
        let smoothedWeightB = smoothWeightMapFast(
            weightB,
            width: gridW,
            height: gridH,
            radius: max(3, min(gridW, gridH) / 48)
        )

        // 統計融合後殘留高光並建立單通道 8-bit 灰階遮罩陣列供 GPU CIBlendWithMask 使用
        var maskBytes = [UInt8](repeating: 0, count: gridW * gridH)
        var glareCountAfter = 0

        for y in topMargin..<bottomMargin {
            let rowOffset = y * gridW
            for x in leftMargin..<rightMargin {
                let pIdx = rowOffset + x
                let wB = min(1.0, max(0.0, smoothedWeightB[pIdx]))
                let wA = 1.0 - wB
                maskBytes[pIdx] = UInt8((wB * 255.0).rounded())

                let idx = pIdx * 4
                let rOut = wA * Float(bufferA[idx]) + wB * Float(bufferB[idx])
                let gOut = wA * Float(bufferA[idx + 1]) + wB * Float(bufferB[idx + 1])
                let bOut = wA * Float(bufferA[idx + 2]) + wB * Float(bufferB[idx + 2])

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

        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let maskCtx = CGContext(
            data: &maskBytes,
            width: gridW,
            height: gridH,
            bitsPerComponent: 8,
            bytesPerRow: gridW,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ),
        let smallMaskCG = maskCtx.makeImage() else {
            return (applyModeAGlareSuppression(to: imageA), ratioBefore, ratioAfter)
        }

        // 在 GPU 上將灰階遮罩放大至 4K 原圖尺寸並執行微高斯柔化與 CIBlendWithMask + Mode A 潤飾（單次 GPU 渲染）
        let ciImageA = CIImage(cgImage: imageA)
        let upscaleTransform = CGAffineTransform(
            scaleX: CGFloat(fullWidth) / CGFloat(gridW),
            y: CGFloat(fullHeight) / CGFloat(gridH)
        )
        let upscaledMaskCI = CIImage(cgImage: smallMaskCG)
            .transformed(by: upscaleTransform)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 4.5)
            .cropped(to: fullExtent)

        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = alignedCIImageB.cropped(to: fullExtent)
        blendFilter.backgroundImage = ciImageA
        blendFilter.maskImage = upscaledMaskCI

        let blendedCI = blendFilter.outputImage?.cropped(to: fullExtent) ?? ciImageA
        let finalPolishedCI = applyModeAGlareSuppressionFilter(to: blendedCI)

        guard let finalCG = context.createCGImage(
            finalPolishedCI,
            from: fullExtent,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            return (imageA, ratioBefore, ratioAfter)
        }

        return (finalCG, ratioBefore, ratioAfter)
    }

    /// O(1) 滑動視窗均值盒狀濾波器（水平 + 垂直雙趟累加器，無內部迴圈，在 270×430 網格上耗時 < 1.5ms）
    private func smoothWeightMapFast(
        _ input: [Float],
        width: Int,
        height: Int,
        radius: Int
    ) -> [Float] {
        guard radius > 0, width > radius * 2 + 1, height > radius * 2 + 1 else {
            return input
        }
        var temp = input
        var output = input
        let invWindow = 1.0 / Float(radius * 2 + 1)

        // 1. 水平滑動視窗累加
        for y in 0..<height {
            let rowOffset = y * width
            var runningSum: Float = 0
            for k in 0...(radius * 2) {
                runningSum += input[rowOffset + k]
            }
            temp[rowOffset + radius] = runningSum * invWindow

            for x in (radius + 1)..<(width - radius) {
                runningSum += input[rowOffset + x + radius] - input[rowOffset + x - radius - 1]
                temp[rowOffset + x] = runningSum * invWindow
            }
        }

        // 2. 垂直滑動視窗累加
        for x in 0..<width {
            var runningSum: Float = 0
            for k in 0...(radius * 2) {
                runningSum += temp[k * width + x]
            }
            output[radius * width + x] = runningSum * invWindow

            for y in (radius + 1)..<(height - radius) {
                runningSum += temp[(y + radius) * width + x] - temp[(y - radius - 1) * width + x]
                output[y * width + x] = runningSum * invWindow
            }
        }

        return output
    }
}
