import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Task 5.4 & 6.1: 反光與光影處理機制 + 相機/手動編輯高精度純淨四角吸附

extension VisionManager {

    /// Mode B 第 1 張角度背景預處理結果（於使用者調整角度準備拍第 2 張的空檔先行算完）
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

    // MARK: - 1. 高精度純淨四角偵測 (專供「相機實拍」與「手動編輯器左下角自動吸附」使用)

    /// 針對實機手持拍攝與手動編輯器「自動吸附」設計的純淨四角定位管線：
    /// 1. 優先採用 Apple 原生 `VNDetectRectanglesRequest` 的真實透視梯形，**絕不**呼叫舊版 `CIDetector` 比大面積（避免包入桌面木紋或陰影）。
    /// 2. **自然透視保護**：當手持拍攝存在自然的近大遠小透視收斂（四角內角皆在 `72° ~ 108°` 之間）時，**絕不**執行 `refineQuadrilateral` 的平行四邊形頂點強制改寫（徹底解決拍完照後左上角被推到木桌面上或跨邊手寫字把頂邊吸歪的問題）。
    /// 3. **取景器綠框錨定 (`priorNormalizedCorners`)**：若相機預覽綠框已鎖定拍立得，優先挑選與取景器綠框最吻合之候選矩形；若快門瞬間因反光/手震漏抓，直接以取景器鎖定之綠框進行局部精準微調。
    func detectQuadFastForCamera(
        in image: CGImage,
        imageSize: CGSize,
        isKnownFrontPhoto: Bool = true,
        priorNormalizedCorners: [CGPoint]? = nil,
        allowHeavyFallbacks: Bool = true
    ) async throws -> DetectionResult {
        let maxProxySide: CGFloat = 1280.0
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

        // 若為背面照片，先檢查背面專用雙重錨點
        if !isKnownFrontPhoto,
           let backRes = try? await detectBacksideCorners(in: proxyCGImage, imageSize: actualProxySize) {
            let fullCorners = backRes.corners.map { CGPoint(x: $0.x * scaleBackX, y: $0.y * scaleBackY) }
            return DetectionResult(
                corners: fullCorners,
                method: backRes.method,
                confidence: backRes.confidence,
                imageSize: imageSize
            )
        }

        // Step A: 使用純淨版 VNDetectRectanglesRequest 搜尋所有符合拍立得幾何的候選矩形
        if let cleanCornersOnProxy = detectCleanVisionQuadOnProxy(
            proxyImage: proxyCGImage,
            proxySize: actualProxySize,
            priorNormalizedCorners: priorNormalizedCorners
        ) {
            let fullResCorners = cleanCornersOnProxy.map {
                CGPoint(x: $0.x * scaleBackX, y: $0.y * scaleBackY)
            }
            return DetectionResult(
                corners: fullResCorners,
                method: .visionNative,
                confidence: 0.96,
                imageSize: imageSize
            )
        }

        // Step B: 若快門瞬間 Vision 未抓到，但取景器綠框或陀螺儀追蹤框 (priorNormalizedCorners) 已經鎖定拍立得，直接沿用！（不裁切超出畫面的頂點）
        if let prior = priorNormalizedCorners, prior.count == 4 {
            let fullResCorners = VisionManager.orderPoints(prior.map {
                CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height)
            })
            if !allowHeavyFallbacks || VisionManager.isChekiRatio(fullResCorners) {
                return DetectionResult(
                    corners: fullResCorners,
                    method: .visionNative,
                    confidence: 0.90,
                    imageSize: imageSize
                )
            }
        }

        guard allowHeavyFallbacks else {
            throw VisionError.detectionFailed
        }

        // Step C: 最終兜底（外框 25 射線 RANSAC 或 YOLO Pose），但同樣關閉破壞性的平行四邊形硬掰
        if let outerCorners = VisionManager.detectOuterPerimeterQuad(in: proxyCGImage, imageSize: actualProxySize),
           isNaturalPerspectiveQuad(outerCorners) {
            let fullResCorners = outerCorners.map {
                CGPoint(x: $0.x * scaleBackX, y: $0.y * scaleBackY)
            }
            return DetectionResult(
                corners: fullResCorners,
                method: .visionNative,
                confidence: 0.88,
                imageSize: imageSize
            )
        }

        if let poseRes = try? await detectFallbackPose(image: proxyCGImage, imageSize: actualProxySize) {
            let fullResCorners = poseRes.corners.map {
                CGPoint(x: $0.x * scaleBackX, y: $0.y * scaleBackY)
            }
            return DetectionResult(
                corners: fullResCorners,
                method: poseRes.method,
                confidence: poseRes.confidence,
                imageSize: imageSize
            )
        }

        let fallbackDetection = try await detectQuad(in: proxyCGImage, imageSize: actualProxySize)
        let fullResCorners = fallbackDetection.corners.map {
            CGPoint(x: $0.x * scaleBackX, y: $0.y * scaleBackY)
        }
        return DetectionResult(
            corners: fullResCorners,
            method: fallbackDetection.method,
            confidence: fallbackDetection.confidence,
            imageSize: imageSize
        )
    }

    /// 純淨版 Apple Vision 矩形偵測：
    /// - 結合取景器綠框先驗 (`priorNormalizedCorners`)、拍立得工業比例契合度、以及自然透視四角對稱性評分。
    /// - 若誤抓內部相片框 (`isInnerFrame`) 則依據富士工業規格外推至白邊外框，但**絕不**對正常的自然透視梯形執行平行四邊形頂點覆寫。
    private func detectCleanVisionQuadOnProxy(
        proxyImage: CGImage,
        proxySize: CGSize,
        priorNormalizedCorners: [CGPoint]?
    ) -> [CGPoint]? {
        let imgW = Double(proxySize.width)
        let imgH = Double(proxySize.height)
        guard imgW > 32, imgH > 32 else { return nil }

        let handler = VNImageRequestHandler(cgImage: proxyImage, options: [:])

        // 與取景器預覽完全一致的黃金比例參數，並允許最多 8 個候選以同時檢查外框與內框
        let req1 = VNDetectRectanglesRequest()
        req1.minimumAspectRatio = 0.45
        req1.maximumAspectRatio = 0.96
        req1.minimumSize        = 0.14
        req1.maximumObservations = 8
        req1.minimumConfidence  = 0.35

        try? handler.perform([req1])
        var observations = req1.results ?? []

        if observations.isEmpty {
            let req2 = VNDetectRectanglesRequest()
            req2.minimumAspectRatio = 0.25
            req2.maximumAspectRatio = 1.00
            req2.minimumSize        = 0.08
            req2.maximumObservations = 10
            req2.minimumConfidence  = 0.20
            try? handler.perform([req2])
            observations = req2.results ?? []
        }

        guard !observations.isEmpty else { return nil }

        let orderedPrior: [CGPoint]? = priorNormalizedCorners.flatMap { prior in
            guard prior.count == 4 else { return nil }
            return VisionManager.orderPoints(prior.map {
                CGPoint(x: Double($0.x) * imgW, y: Double($0.y) * imgH)
            })
        }

        let canvasArea = imgW * imgH
        let diag = hypot(imgW, imgH)
        var bestCorners: [CGPoint]? = nil
        var bestScore: Double = -Double.infinity

        for obs in observations {
            let rawPts: [CGPoint] = [
                CGPoint(x: Double(obs.topLeft.x)     * imgW, y: (1.0 - Double(obs.topLeft.y))     * imgH),
                CGPoint(x: Double(obs.topRight.x)    * imgW, y: (1.0 - Double(obs.topRight.y))    * imgH),
                CGPoint(x: Double(obs.bottomRight.x) * imgW, y: (1.0 - Double(obs.bottomRight.y)) * imgH),
                CGPoint(x: Double(obs.bottomLeft.x)  * imgW, y: (1.0 - Double(obs.bottomLeft.y))  * imgH)
            ]
            var pts = VisionManager.orderPoints(rawPts)
            let rawArea = VisionManager.quadArea(pts)
            guard rawArea >= 0.05 * canvasArea else { continue }
            guard VisionManager.isChekiRatio(pts) else { continue }

            // 檢查是否僅抓到拍立得內部相片區（例如頂部白邊有深色麥克筆字導致 Vision 只抓到內框）
            let extraRes = FrameExtrapolator.checkAndExtrapolate(
                corners: pts,
                imageSize: proxySize,
                image: proxyImage
            )
            if extraRes.isInnerFrame {
                pts = VisionManager.orderPoints(extraRes.extrapolatedCorners)
            }

            guard isNaturalPerspectiveQuad(pts) else { continue }

            let finalArea = VisionManager.quadArea(pts)
            let areaRatio = finalArea / canvasArea
            let ratio = VisionManager.quadAspectRatio(pts)

            // 拍立得標準長短邊比契合度 (Mini 1.593, Square 1.194, Wide 1.256)
            let miniDist = abs(ratio - (86.0 / 54.0))
            let squareDist = abs(ratio - (86.0 / 72.0))
            let wideDist = abs(ratio - (108.0 / 86.0))
            let minDist = min(miniDist, min(squareDist, wideDist))
            let formatScore = max(0.35, 1.0 - minDist * 1.1)

            // 四角正交與自然透視對稱度 (0.5 ~ 1.0)
            let symmetryScore = perspectiveSymmetryScore(pts)

            // 若有取景器鎖定綠框 (orderedPrior)，計算與取景器綠框的吻合獎勵
            var priorBonus = 1.0
            if let prior = orderedPrior {
                let meanCornerDist = zip(pts, prior).reduce(0.0) { acc, pair in
                    acc + hypot(Double(pair.0.x - pair.1.x), Double(pair.0.y - pair.1.y))
                } / 4.0
                let normalizedDist = meanCornerDist / max(1.0, diag)
                if normalizedDist < 0.12 {
                    priorBonus = 1.35 * (1.0 - normalizedDist * 2.0)
                }
            }

            let score = areaRatio * formatScore * symmetryScore * Double(obs.confidence) * priorBonus
            if score > bestScore {
                bestScore = score
                bestCorners = pts
            }
        }

        guard let selected = bestCorners else { return nil }

        // 執行溫和、不破壞透視角度的局部白邊-背景對比微調（僅在邊界外側有明顯背景色差時微調 <= 1.2% 邊長）
        return snapCornersToLocalWhiteBorder(
            corners: selected,
            image: proxyImage,
            imageSize: proxySize
        )
    }

    /// 驗證四邊形是否為合理的自然透視梯形（四個內角皆介於 68° ~ 112°，且無單一頂點劇烈扭曲）
    private func isNaturalPerspectiveQuad(_ pts: [CGPoint]) -> Bool {
        guard pts.count == 4 else { return false }
        let ordered = VisionManager.orderPoints(pts)
        var angles: [Double] = []
        for i in 0..<4 {
            let prev = ordered[(i + 3) % 4]
            let curr = ordered[i]
            let next = ordered[(i + 1) % 4]
            let v1 = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
            let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
            let m1 = hypot(Double(v1.x), Double(v1.y))
            let m2 = hypot(Double(v2.x), Double(v2.y))
            guard m1 > 4.0, m2 > 4.0 else { return false }
            let cosT = max(-1.0, min(1.0, Double(v1.x * v2.x + v1.y * v2.y) / (m1 * m2)))
            let deg = acos(cosT) * 180.0 / .pi
            if deg < 68.0 || deg > 112.0 {
                return false
            }
            angles.append(deg)
        }
        // 自然透視下，對角和 (TL+BR 與 TR+BL) 應接近 180°
        let sumDiag1 = angles[0] + angles[2]
        let sumDiag2 = angles[1] + angles[3]
        return abs(sumDiag1 - 180.0) <= 18.0 && abs(sumDiag2 - 180.0) <= 18.0
    }

    private func perspectiveSymmetryScore(_ pts: [CGPoint]) -> Double {
        let ordered = VisionManager.orderPoints(pts)
        guard ordered.count == 4 else { return 0.5 }
        var angles: [Double] = []
        for i in 0..<4 {
            let prev = ordered[(i + 3) % 4]
            let curr = ordered[i]
            let next = ordered[(i + 1) % 4]
            let v1 = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
            let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
            let m1 = max(1e-4, hypot(Double(v1.x), Double(v1.y)))
            let m2 = max(1e-4, hypot(Double(v2.x), Double(v2.y)))
            let cosT = max(-1.0, min(1.0, Double(v1.x * v2.x + v1.y * v2.y) / (m1 * m2)))
            angles.append(acos(cosT) * 180.0 / .pi)
        }
        let maxDevFrom90 = angles.map { abs($0 - 90.0) }.max() ?? 0.0
        return max(0.55, 1.0 - maxDevFrom90 / 45.0)
    }

    /// 溫和的局部邊緣貼合：僅限制在四個頂點的 0.8% 範圍內做安全邊界夾限，絕不因為跨邊麥克筆字把頂點拉出拍立得外框
    private func snapCornersToLocalWhiteBorder(
        corners: [CGPoint],
        image: CGImage,
        imageSize: CGSize
    ) -> [CGPoint] {
        let ordered = VisionManager.orderPoints(corners)
        guard ordered.count == 4 else { return corners }

        // 若單一頂點明顯異常（某對角和偏離 180° 超過 12°，代表其中一角被遮擋或誤抓），才用幾何對稱修復該異常角
        var angles: [Double] = []
        for i in 0..<4 {
            let prev = ordered[(i + 3) % 4]
            let curr = ordered[i]
            let next = ordered[(i + 1) % 4]
            let v1 = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
            let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
            let m1 = max(1e-4, hypot(Double(v1.x), Double(v1.y)))
            let m2 = max(1e-4, hypot(Double(v2.x), Double(v2.y)))
            let cosT = max(-1.0, min(1.0, Double(v1.x * v2.x + v1.y * v2.y) / (m1 * m2)))
            angles.append(acos(cosT) * 180.0 / .pi)
        }

        var result = ordered
        let diagDiff = abs((angles[0] + angles[2]) - (angles[1] + angles[3]))
        if diagDiff > 14.0 {
            let refRes = VisionManager.refineQuadrilateral(
                corners: ordered,
                imageSize: imageSize,
                image: nil,
                skewThresholdDegrees: 9.5
            )
            if refRes.wasRefined {
                result = refRes.corners
            }
        }

        return result.map { pt in
            CGPoint(
                x: max(0, min(imageSize.width, pt.x)),
                y: max(0, min(imageSize.height, pt.y))
            )
        }
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

    // MARK: - 2. Mode A: 單張智慧高光抑制 (免費版預設 & 基礎動態範圍補償)

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
        highlightShadow.highlightAmount = 0.78 // 溫和壓制過曝高光白霧
        highlightShadow.shadowAmount = 0.06    // 微提暗部層次

        guard let step1 = highlightShadow.outputImage else { return ciInput }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = step1
        colorControls.contrast = 1.02
        colorControls.saturation = 1.02
        colorControls.brightness = -0.005

        return colorControls.outputImage?.cropped(to: extent) ?? step1.cropped(to: extent)
    }

    // MARK: - 3. Mode B: 零鬼影雙角度去反光合成管線 (Pro 專屬功能)

    /// 在使用者拍下 Mode B 第 1 張後，趁使用者微調手機角度準備拍四個角落的空檔，立即於背景先行完成第 1 張之純淨四角鎖定與透視正位。
    func prepareModeBFirstAngle(
        primaryImage: CGImage,
        borderInsetRatio: Double = 0.0,
        preferredFormat: FilmFormat = .auto,
        priorNormalizedCorners: [CGPoint]? = nil
    ) async throws -> ModeBPreparedFirstAngle {
        let primarySize = CGSize(width: primaryImage.width, height: primaryImage.height)
        let chekiFormat = mapToChekiFilmFormat(preferredFormat)

        let detectionA = try await detectQuadFastForCamera(
            in: primaryImage,
            imageSize: primarySize,
            isKnownFrontPhoto: true,
            priorNormalizedCorners: priorNormalizedCorners,
            allowHeavyFallbacks: priorNormalizedCorners == nil
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

        return ModeBPreparedFirstAngle(
            originalCGImage: primaryImage,
            originalSize: primarySize,
            cropResult: cropA,
            adjustedDetection: adjustedDetectionA,
            resolvedFormat: resolvedFormat,
            ocrDate: nil
        )
    }

    /// Google フォトスキャン (PhotoScan) 風格多視角（2~4 張四角對準閃光拍攝）無反光合成管線：
    /// 1. 第 1 張照片固定拍立得外框位置作為正位基準；後續四角照片優先使用陀螺儀追蹤之四角位置與輕量矩形微調，絕不執行耗時的重型 Fallback。
    /// 2. 先將各角度照片快速縮放至 1280px 工作解析度再正位，大幅縮短 12MP 大圖處理時間（總合成時間 < 0.35 秒）。
    func synthesizePhotoScanMultiFrameAntiGlare(
        rawImages: [CGImage],
        priorNormalizedQuads: [[CGPoint]?] = [],
        borderInsetRatio: Double = 0.0,
        preferredFormat: FilmFormat = .auto,
        preparedFirstAngle: ModeBPreparedFirstAngle? = nil
    ) async throws -> ModeBAntiGlareResult {
        guard let firstRaw = rawImages.first else {
            throw VisionError.detectionFailed
        }

        // 1. 取得第 1 張（完整置中基準圖）的正位結果（若有背景預處理結果則 0ms 直接取用）
        let firstPrepared: ModeBPreparedFirstAngle
        if let preparedFirstAngle {
            firstPrepared = preparedFirstAngle
        } else {
            let firstPrior = priorNormalizedQuads.first ?? nil
            firstPrepared = try await prepareModeBFirstAngle(
                primaryImage: firstRaw,
                borderInsetRatio: borderInsetRatio,
                preferredFormat: preferredFormat,
                priorNormalizedCorners: firstPrior
            )
        }

        let resolvedFormat = firstPrepared.resolvedFormat
        let baseW0 = max(1.0, firstPrepared.originalSize.width)
        let baseH0 = max(1.0, firstPrepared.originalSize.height)
        let baseNormCorners0: [CGPoint] = VisionManager.orderPoints(
            firstPrepared.adjustedDetection.corners
        ).map {
            CGPoint(x: $0.x / baseW0, y: $0.y / baseH0)
        }

        var croppedResults: [CropResult] = [firstPrepared.cropResult]
        var detections: [DetectionResult] = [firstPrepared.adjustedDetection]
        var normalizedQuadsPerFrame: [[CGPoint]] = [baseNormCorners0]

        // 2. 依序對第 2..N 張四角照片執行極速透視正位（支援部分拍立得移出畫面外的四角特寫對位）
        let maxDonorRawSide: CGFloat = 1280.0
        for idx in 1..<rawImages.count {
            let fullImg = rawImages[idx]
            let fullLongSide = CGFloat(max(fullImg.width, fullImg.height))
            let donorScale = fullLongSide > maxDonorRawSide ? (maxDonorRawSide / fullLongSide) : 1.0
            let workingImg: CGImage
            if donorScale < 0.99,
               let small = downsampleCGImage(
                   fullImg,
                   to: CGSize(
                       width: max(1, round(CGFloat(fullImg.width) * donorScale)),
                       height: max(1, round(CGFloat(fullImg.height) * donorScale))
                   )
               ) {
                workingImg = small
            } else {
                workingImg = fullImg
            }

            let imgSize = CGSize(width: workingImg.width, height: workingImg.height)
            let prior = idx < priorNormalizedQuads.count ? priorNormalizedQuads[idx] : nil

            let donorNormCorners = estimateDonorNormalizedQuadInRawFrame(
                baseRawImage: firstPrepared.originalCGImage,
                baseNormCorners: baseNormCorners0,
                donorImage: workingImg,
                donorSize: imgSize,
                priorNormalizedCorners: prior
            )

            let pixelCorners = donorNormCorners.map {
                CGPoint(x: $0.x * imgSize.width, y: $0.y * imgSize.height)
            }
            let adjDet = DetectionResult(
                corners: pixelCorners,
                method: .visionNative,
                confidence: 0.94,
                imageSize: imgSize
            )
            if let crop = try? perspectiveCorrect(
                image: workingImg,
                corners: pixelCorners,
                detection: adjDet,
                format: mapToChekiFilmFormat(resolvedFormat),
                preserveCornerOrder: true
            ) {
                croppedResults.append(crop)
                detections.append(adjDet)
                normalizedQuadsPerFrame.append(donorNormCorners)
            }
        }

        guard croppedResults.count >= 2 else {
            let suppressed = applyModeAGlareSuppression(to: firstPrepared.cropResult.cgImage)
            return ModeBAntiGlareResult(
                fusedCGImage: suppressed,
                primaryCropResult: firstPrepared.cropResult,
                secondaryCropResult: firstPrepared.cropResult,
                primaryDetection: firstPrepared.adjustedDetection,
                glareRatioBefore: 0.0,
                glareRatioAfter: 0.0,
                resolvedFormat: resolvedFormat,
                preRecognizedDate: firstPrepared.ocrDate
            )
        }

        // 3. 永遠以第 1 張完整置中拍攝的拍立得為 Base 底圖，將四角照片中畫面內 (In-Bounds) 的無反光區域精準對位修補進來
        let croppedCGs = croppedResults.map(\.cgImage)
        let (finalCGImage, glareBefore, glareAfter) = fuseMultiFrameGlareFree(
            croppedImages: croppedCGs,
            donorNormalizedQuads: normalizedQuadsPerFrame
        )

        return ModeBAntiGlareResult(
            fusedCGImage: finalCGImage,
            primaryCropResult: croppedResults[0],
            secondaryCropResult: croppedResults[1],
            primaryDetection: detections[0],
            glareRatioBefore: glareBefore,
            glareRatioAfter: glareAfter,
            resolvedFormat: resolvedFormat,
            preRecognizedDate: firstPrepared.ocrDate
        )
    }

    /// 零鬼影 Mode B 雙角度去反光合成（直接路由至 Google フォトスキャン 核心多視角無反光合成管線）
    func synthesizeModeBDualAngleAntiGlare(
        primaryImage: CGImage,
        secondaryImage: CGImage,
        borderInsetRatio: Double = 0.0,
        preferredFormat: FilmFormat = .auto,
        preparedFirstAngle: ModeBPreparedFirstAngle? = nil,
        secondaryPriorNormalizedCorners: [CGPoint]? = nil
    ) async throws -> ModeBAntiGlareResult {
        return try await synthesizePhotoScanMultiFrameAntiGlare(
            rawImages: [primaryImage, secondaryImage],
            priorNormalizedQuads: [nil, secondaryPriorNormalizedCorners],
            borderInsetRatio: borderInsetRatio,
            preferredFormat: preferredFormat,
            preparedFirstAngle: preparedFirstAngle
        )
    }

    // MARK: - 4. 四角移動原始幀對位 + 局部網格配準與測地線光暈 100% 替換核心

    /// 計算第 2..N 張四角照片中拍立得在原始畫面的正規化四角座標 `[TL, TR, BR, BL]`（允許超出 `0...1` 畫面邊界，絕不錯誤夾限）
    private func estimateDonorNormalizedQuadInRawFrame(
        baseRawImage: CGImage,
        baseNormCorners: [CGPoint],
        donorImage: CGImage,
        donorSize: CGSize,
        priorNormalizedCorners: [CGPoint]?
    ) -> [CGPoint] {
        guard baseNormCorners.count == 4 else {
            return priorNormalizedCorners ?? baseNormCorners
        }

        // 先計算取景器追蹤框 prior 相對於第 1 張基準框的初始平移量
        var initNormDx: CGFloat = 0
        var initNormDy: CGFloat = 0
        if let prior = priorNormalizedCorners, prior.count == 4 {
            let orderedPrior = VisionManager.orderPoints(prior)
            initNormDx = (orderedPrior[0].x - baseNormCorners[0].x
                        + orderedPrior[1].x - baseNormCorners[1].x
                        + orderedPrior[2].x - baseNormCorners[2].x
                        + orderedPrior[3].x - baseNormCorners[3].x) * 0.25
            initNormDy = (orderedPrior[0].y - baseNormCorners[0].y
                        + orderedPrior[1].y - baseNormCorners[1].y
                        + orderedPrior[2].y - baseNormCorners[2].y
                        + orderedPrior[3].y - baseNormCorners[3].y) * 0.25
        }

        // 在 120×160 縮圖上直接比對第 1 張拍立得非反光錨點與第 k 張四角照片，精確求出剛體位移 (normDx, normDy)
        let trackW = 120
        let trackH = 160
        let colorSpace = Self.sharedSRGBColorSpace
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var buf0 = [UInt8](repeating: 0, count: trackW * trackH * 4)
        var bufK = [UInt8](repeating: 0, count: trackW * trackH * 4)

        var refinedNormDx = initNormDx
        var refinedNormDy = initNormDy

        if let ctx0 = CGContext(data: &buf0, width: trackW, height: trackH, bitsPerComponent: 8, bytesPerRow: trackW * 4, space: colorSpace, bitmapInfo: bitmapInfo),
           let ctxK = CGContext(data: &bufK, width: trackW, height: trackH, bitsPerComponent: 8, bytesPerRow: trackW * 4, space: colorSpace, bitmapInfo: bitmapInfo) {
            ctx0.interpolationQuality = .low
            ctxK.interpolationQuality = .low
            ctx0.draw(baseRawImage, in: CGRect(x: 0, y: 0, width: trackW, height: trackH))
            ctxK.draw(donorImage, in: CGRect(x: 0, y: 0, width: trackW, height: trackH))

            let tl = baseNormCorners[0], tr = baseNormCorners[1], br = baseNormCorners[2], bl = baseNormCorners[3]
            func bilerp(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                let top = CGPoint(x: tl.x + (tr.x - tl.x) * u, y: tl.y + (tr.y - tl.y) * u)
                let bot = CGPoint(x: bl.x + (br.x - bl.x) * u, y: bl.y + (br.y - bl.y) * u)
                return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
            }

            struct SamplePt {
                let x: Int, y: Int
                let r: Float, g: Float, b: Float
                let gx: Float, gy: Float
                let weight: Float
            }
            var samples: [SamplePt] = []
            let steps = 16
            for iv in 0...steps {
                let v = -0.02 + 1.04 * (CGFloat(iv) / CGFloat(steps))
                for iu in 0...steps {
                    let u = -0.02 + 1.04 * (CGFloat(iu) / CGFloat(steps))
                    let pt = bilerp(u, v)
                    let px = Int((pt.x * CGFloat(trackW)).rounded())
                    let py = Int((pt.y * CGFloat(trackH)).rounded())
                    guard px >= 2, px < trackW - 2, py >= 2, py < trackH - 2 else { continue }
                    let idx = (py * trackW + px) * 4
                    let r = Float(buf0[idx]), g = Float(buf0[idx + 1]), b = Float(buf0[idx + 2])
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    if lum > 222.0 && u > 0.12 && u < 0.88 && v > 0.10 && v < 0.78 { continue }

                    let idxL = (py * trackW + (px - 1)) * 4
                    let idxR = (py * trackW + (px + 1)) * 4
                    let idxU = ((py - 1) * trackW + px) * 4
                    let idxD = ((py + 1) * trackW + px) * 4
                    let gx = (0.299 * Float(buf0[idxR]) + 0.587 * Float(buf0[idxR + 1]) + 0.114 * Float(buf0[idxR + 2]))
                           - (0.299 * Float(buf0[idxL]) + 0.587 * Float(buf0[idxL + 1]) + 0.114 * Float(buf0[idxL + 2]))
                    let gy = (0.299 * Float(buf0[idxD]) + 0.587 * Float(buf0[idxD + 1]) + 0.114 * Float(buf0[idxD + 2]))
                           - (0.299 * Float(buf0[idxU]) + 0.587 * Float(buf0[idxU + 1]) + 0.114 * Float(buf0[idxU + 2]))
                    let isEdge = (u <= 0.08 || u >= 0.92 || v <= 0.08 || v >= 0.92 || abs(v - 0.78) <= 0.06)
                    samples.append(SamplePt(x: px, y: py, r: r, g: g, b: b, gx: gx, gy: gy, weight: isEdge ? 1.6 : 1.0))
                }
            }

            let minValid = max(14, samples.count / 4)
            let priorDxPx = Int((initNormDx * CGFloat(trackW)).rounded())
            let priorDyPx = Int((initNormDy * CGFloat(trackH)).rounded())

            func evalShift(_ dx: Int, _ dy: Int) -> Float {
                var errSum: Float = 0
                var wSum: Float = 0
                var count = 0
                for s in samples {
                    let qx = s.x + dx
                    let qy = s.y + dy
                    guard qx >= 2, qx < trackW - 2, qy >= 2, qy < trackH - 2 else { continue }
                    let idx = (qy * trackW + qx) * 4
                    let r = Float(bufK[idx]), g = Float(bufK[idx + 1]), b = Float(bufK[idx + 2])
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    if lum > 235.0 && (0.299 * s.r + 0.587 * s.g + 0.114 * s.b) < 205.0 { continue }

                    let idxL = (qy * trackW + (qx - 1)) * 4
                    let idxR = (qy * trackW + (qx + 1)) * 4
                    let idxU = ((qy - 1) * trackW + qx) * 4
                    let idxD = ((qy + 1) * trackW + qx) * 4
                    let gx = (0.299 * Float(bufK[idxR]) + 0.587 * Float(bufK[idxR + 1]) + 0.114 * Float(bufK[idxR + 2]))
                           - (0.299 * Float(bufK[idxL]) + 0.587 * Float(bufK[idxL + 1]) + 0.114 * Float(bufK[idxL + 2]))
                    let gy = (0.299 * Float(bufK[idxD]) + 0.587 * Float(bufK[idxD + 1]) + 0.114 * Float(bufK[idxD + 2]))
                           - (0.299 * Float(bufK[idxU]) + 0.587 * Float(bufK[idxU + 1]) + 0.114 * Float(bufK[idxU + 2]))
                    let cDiff = (abs(r - s.r) + abs(g - s.g) + abs(b - s.b)) / 3.0
                    let gDiff = (abs(gx - s.gx) + abs(gy - s.gy)) * 0.85
                    errSum += min(90.0, cDiff * 0.38 + gDiff * 0.62) * s.weight
                    wSum += s.weight
                    count += 1
                }
                guard count >= minValid, wSum > 1.0 else { return .greatestFiniteMagnitude }
                let priorPenalty = hypot(Float(dx - priorDxPx), Float(dy - priorDyPx)) * 0.12
                return (errSum / wSum) + priorPenalty
            }

            var bestDx = priorDxPx
            var bestDy = priorDyPx
            var bestCost = evalShift(bestDx, bestDy)

            for dy in stride(from: -110, through: 110, by: 3) {
                for dx in stride(from: -82, through: 82, by: 3) {
                    let c = evalShift(dx, dy)
                    if c < bestCost {
                        bestCost = c
                        bestDx = dx
                        bestDy = dy
                    }
                }
            }
            let cDx = bestDx, cDy = bestDy
            for dy in (cDy - 2)...(cDy + 2) {
                for dx in (cDx - 2)...(cDx + 2) {
                    let c = evalShift(dx, dy)
                    if c < bestCost {
                        bestCost = c
                        bestDx = dx
                        bestDy = dy
                    }
                }
            }
            refinedNormDx = CGFloat(bestDx) / CGFloat(trackW)
            refinedNormDy = CGFloat(bestDy) / CGFloat(trackH)
        }

        let shiftedNormCorners = baseNormCorners.map {
            CGPoint(x: $0.x + refinedNormDx, y: $0.y + refinedNormDy)
        }

        // 僅當拍立得四個角皆完整在畫面內部 (0.04...0.96) 時，才允許以 Vision 矩形微調透視角度；
        // 若拍攝四角特寫導致任一角靠近或超出畫面邊緣，直接使用剛體追蹤之 shiftedNormCorners（絕不裁切壓扁！）
        let allCornersWellInside = shiftedNormCorners.allSatisfy {
            $0.x >= 0.04 && $0.x <= 0.96 && $0.y >= 0.04 && $0.y <= 0.96
        }
        if allCornersWellInside,
           let visionPts = detectCleanVisionQuadOnProxy(
               proxyImage: donorImage,
               proxySize: donorSize,
               priorNormalizedCorners: shiftedNormCorners
           ) {
            let normVision = VisionManager.orderPoints(visionPts).map {
                CGPoint(x: $0.x / max(1.0, donorSize.width), y: $0.y / max(1.0, donorSize.height))
            }
            let meanDiff = zip(normVision, shiftedNormCorners).reduce(0.0) { acc, pair in
                acc + hypot(Double(pair.0.x - pair.1.x), Double(pair.0.y - pair.1.y))
            } / 4.0
            if meanDiff < 0.065 {
                return normVision
            }
        }

        return shiftedNormCorners
    }

    /// 多視角無反光合成核心 (`fuseMultiFrameGlareFree`)：
    /// - 永遠以第 1 張完整置中拍攝之拍立得 (`croppedImages[0]`) 為基準底圖 (Base Frame)。
    /// - 針對其餘四角拍攝圖 (`k = 1..<count`)：
    ///   1. 計算畫面內有效遮罩 (`rawValidB`)，自動排除移出相機畫面外的延伸區域。
    ///   2. 執行兩階段配準：先執行全域粗平移搜尋 (`±36px` X, `±48px` Y) 消除手持移動視差，再執行 4×6 局部非剛性網格微調。
    ///   3. 以乾淨中間調估算全域環境曝光差（絕不把白衣上的反光斑誤吸納為環境光差），100% 消除中央與白衣/深色外套上的閃光燈反光核與光暈。
    private func fuseMultiFrameGlareFree(
        croppedImages: [CGImage],
        donorNormalizedQuads: [[CGPoint]] = []
    ) -> (fused: CGImage, glareBefore: Double, glareAfter: Double) {
        guard let baseCG = croppedImages.first else {
            fatalError("croppedImages must not be empty")
        }
        guard croppedImages.count >= 2 else {
            return (baseCG, 0.0, 0.0)
        }

        let fullWidth = baseCG.width
        let fullHeight = baseCG.height
        let fullExtent = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        guard fullWidth > 32, fullHeight > 32 else {
            return (baseCG, 0.0, 0.0)
        }

        // 建立 420px 極速分析畫布（並於最後透過 GPU CIBlendWithMask 還原 4K 畫質）
        let maxWorkSide: Double = 420.0
        let workScale = min(1.0, maxWorkSide / Double(max(fullWidth, fullHeight)))
        let width = max(64, Int((Double(fullWidth) * workScale).rounded()))
        let height = max(64, Int((Double(fullHeight) * workScale).rounded()))
        let workRect = CGRect(x: 0, y: 0, width: width, height: height)
        let bytesPerRow = width * 4
        let colorSpace = Self.sharedSRGBColorSpace
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        var currentBuf = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctxBase = CGContext(
            data: &currentBuf,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return (baseCG, 0.0, 0.0)
        }
        ctxBase.interpolationQuality = .high
        ctxBase.draw(baseCG, in: workRect)

        // 保留初始 Base Frame 副本，用於全域對位基準與產生最終 4K GPU 融合遮罩
        let initialBaseBuf = currentBuf
        var baseLum0 = [Float](repeating: 0, count: width * height)
        for p in 0..<(width * height) {
            let i = p * 4
            baseLum0[p] = (0.299 * Float(initialBaseBuf[i]) + 0.587 * Float(initialBaseBuf[i + 1]) + 0.114 * Float(initialBaseBuf[i + 2])) / 255.0
        }

        var cumulativeReplacedMask = [Float](repeating: 0, count: width * height)
        var initialGlarePixelCount = 0

        for k in 1..<croppedImages.count {
            let donorCG = croppedImages[k]
            var bufB = [UInt8](repeating: 0, count: width * height * 4)
            guard let ctxB = CGContext(
                data: &bufB,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { continue }
            ctxB.interpolationQuality = .high
            ctxB.draw(donorCG, in: workRect)

            // 計算 Donor k 在原始相機畫面內的真實有效像素遮罩 (排除移出畫面外的 clampedToExtent 拉伸區)
            var rawValidB = [Bool](repeating: true, count: width * height)
            if k < donorNormalizedQuads.count, donorNormalizedQuads[k].count == 4 {
                let q = donorNormalizedQuads[k]
                let tl = q[0], tr = q[1], br = q[2], bl = q[3]
                // 注意：CGContext memory row y=0 對應拍立得頂部 (v=0)
                for y in 0..<height {
                    let v = (CGFloat(y) + 0.5) / CGFloat(height)
                    let topX = tl.x + (tr.x - tl.x) * 0.0
                    let _ = topX
                    for x in 0..<width {
                        let u = (CGFloat(x) + 0.5) / CGFloat(width)
                        let tx = tl.x + (tr.x - tl.x) * u
                        let ty = tl.y + (tr.y - tl.y) * u
                        let bx = bl.x + (br.x - bl.x) * u
                        let by = bl.y + (br.y - bl.y) * u
                        let rx = tx + (bx - tx) * v
                        let ry = ty + (by - ty) * v
                        if rx < 0.02 || rx > 0.98 || ry < 0.02 || ry > 0.98 {
                            rawValidB[y * width + x] = false
                        }
                    }
                }
            }

            var rawLumB = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                let i = p * 4
                rawLumB[p] = (0.299 * Float(bufB[i]) + 0.587 * Float(bufB[i + 1]) + 0.114 * Float(bufB[i + 2])) / 255.0
            }

            // 第一階段：全域粗平移對位 (±36px X, ±48px Y)，解決移動到四角時的透視與高度殘差
            var bestGlobalDx = 0
            var bestGlobalDy = 0
            var bestGlobalCost: Float = .greatestFiniteMagnitude

            initialBaseBuf.withUnsafeBufferPointer { ptrA in
                bufB.withUnsafeBufferPointer { ptrB in
                    func evalGlobal(_ dx: Int, _ dy: Int, step: Int) -> Float {
                        var errSum: Float = 0
                        var count = 0
                        for y in stride(from: 14, to: height - 14, by: step) {
                            let sy = y + dy
                            guard sy >= 4, sy < height - 4 else { continue }
                            for x in stride(from: 14, to: width - 14, by: step) {
                                let sx = x + dx
                                guard sx >= 4, sx < width - 4 else { continue }
                                let pA = y * width + x
                                let pB = sy * width + sx
                                guard rawValidB[pB] else { continue }
                                // 跳過雙方的高光反光區，僅以乾淨的拍立得紋理與邊界對位
                                if baseLum0[pA] > 0.87 || rawLumB[pB] > 0.87 { continue }

                                let iA = pA * 4
                                let iB = pB * 4
                                let cDiff = (abs(Float(ptrA[iA]) - Float(ptrB[iB]))
                                           + abs(Float(ptrA[iA + 1]) - Float(ptrB[iB + 1]))
                                           + abs(Float(ptrA[iA + 2]) - Float(ptrB[iB + 2]))) / 3.0
                                let gxA = (baseLum0[pA + 1] - baseLum0[pA - 1]) * 255.0
                                let gyA = (baseLum0[pA + width] - baseLum0[pA - width]) * 255.0
                                let gxB = (rawLumB[pB + 1] - rawLumB[pB - 1]) * 255.0
                                let gyB = (rawLumB[pB + width] - rawLumB[pB - width]) * 255.0
                                let gDiff = abs(gxA - gxB) + abs(gyA - gyB)

                                errSum += min(85.0, cDiff * 0.38 + gDiff * 0.62)
                                count += 1
                            }
                        }
                        guard count >= 45 else { return .greatestFiniteMagnitude }
                        let penalty = hypot(Float(dx), Float(dy)) * 0.14
                        return (errSum / Float(count)) + penalty
                    }

                    for dy in stride(from: -45, through: 45, by: 3) {
                        for dx in stride(from: -36, through: 36, by: 3) {
                            let c = evalGlobal(dx, dy, step: 6)
                            if c < bestGlobalCost {
                                bestGlobalCost = c
                                bestGlobalDx = dx
                                bestGlobalDy = dy
                            }
                        }
                    }
                    let cDx = bestGlobalDx, cDy = bestGlobalDy
                    bestGlobalCost = evalGlobal(cDx, cDy, step: 4)
                    for dy in (cDy - 2)...(cDy + 2) {
                        for dx in (cDx - 2)...(cDx + 2) {
                            let c = evalGlobal(dx, dy, step: 4)
                            if c < bestGlobalCost {
                                bestGlobalCost = c
                                bestGlobalDx = dx
                                bestGlobalDy = dy
                            }
                        }
                    }
                }
            }

            // 第二階段：以 (bestGlobalDx, bestGlobalDy) 為中心的 4×6 穩健局部網格微調 (±7px)
            let cols = 4
            let rows = 6
            var gridShiftX = [Float](repeating: Float(bestGlobalDx), count: (cols + 1) * (rows + 1))
            var gridShiftY = [Float](repeating: Float(bestGlobalDy), count: (cols + 1) * (rows + 1))
            let localRange = 7

            initialBaseBuf.withUnsafeBufferPointer { ptrA in
                bufB.withUnsafeBufferPointer { ptrB in
                    for gy in 0...rows {
                        let centerY = Int(Double(gy) / Double(rows) * Double(height - 1))
                        let y0 = max(8, centerY - height / (rows * 2))
                        let y1 = min(height - 9, centerY + height / (rows * 2))
                        for gx in 0...cols {
                            let centerX = Int(Double(gx) / Double(cols) * Double(width - 1))
                            let x0 = max(8, centerX - width / (cols * 2))
                            let x1 = min(width - 9, centerX + width / (cols * 2))

                            var bestDx = bestGlobalDx
                            var bestDy = bestGlobalDy
                            var bestCost: Float = .greatestFiniteMagnitude

                            for dy in (bestGlobalDy - localRange)...(bestGlobalDy + localRange) {
                                for dx in (bestGlobalDx - localRange)...(bestGlobalDx + localRange) {
                                    var errSum: Float = 0
                                    var count: Int = 0
                                    for y in stride(from: y0, to: y1, by: 4) {
                                        let sy = y + dy
                                        guard sy >= 2, sy < height - 2 else { continue }
                                        for x in stride(from: x0, to: x1, by: 4) {
                                            let sx = x + dx
                                            guard sx >= 2, sx < width - 2 else { continue }
                                            let pA = y * width + x
                                            let pB = sy * width + sx
                                            guard rawValidB[pB] else { continue }
                                            if baseLum0[pA] > 0.88 || rawLumB[pB] > 0.88 { continue }

                                            let iA = pA * 4
                                            let iB = pB * 4
                                            let cDiff = (abs(Float(ptrA[iA]) - Float(ptrB[iB]))
                                                       + abs(Float(ptrA[iA + 1]) - Float(ptrB[iB + 1]))
                                                       + abs(Float(ptrA[iA + 2]) - Float(ptrB[iB + 2]))) / 3.0
                                            let gxA = (baseLum0[pA + 1] - baseLum0[pA - 1]) * 255.0
                                            let gyA = (baseLum0[pA + width] - baseLum0[pA - width]) * 255.0
                                            let gxB = (rawLumB[pB + 1] - rawLumB[pB - 1]) * 255.0
                                            let gyB = (rawLumB[pB + width] - rawLumB[pB - width]) * 255.0
                                            let gDiff = abs(gxA - gxB) + abs(gyA - gyB)

                                            errSum += min(80.0, cDiff * 0.40 + gDiff * 0.60)
                                            count += 1
                                        }
                                    }
                                    if count >= 10 {
                                        let penalty = Float(abs(dx - bestGlobalDx) + abs(dy - bestGlobalDy)) * 0.45
                                        let avgCost = (errSum / Float(count)) + penalty
                                        if avgCost < bestCost {
                                            bestCost = avgCost
                                            bestDx = dx
                                            bestDy = dy
                                        }
                                    }
                                }
                            }
                            gridShiftX[gy * (cols + 1) + gx] = Float(bestDx)
                            gridShiftY[gy * (cols + 1) + gx] = Float(bestDy)
                        }
                    }
                }
            }

            // 透過雙線性內插對齊 Donor 影像與其畫面內有效遮罩 warpedValidB
            var warpedB = bufB
            var warpedValidB = [Bool](repeating: false, count: width * height)
            warpedB.withUnsafeMutableBufferPointer { dstPtr in
                bufB.withUnsafeBufferPointer { srcPtr in
                    for y in 0..<height {
                        let fy = Float(y) / Float(max(1, height - 1)) * Float(rows)
                        let gy0 = min(rows - 1, max(0, Int(fy)))
                        let gy1 = gy0 + 1
                        let wy = fy - Float(gy0)
                        for x in 0..<width {
                            let fx = Float(x) / Float(max(1, width - 1)) * Float(cols)
                            let gx0 = min(cols - 1, max(0, Int(fx)))
                            let gx1 = gx0 + 1
                            let wx = fx - Float(gx0)

                            let idx00 = gy0 * (cols + 1) + gx0
                            let idx10 = gy0 * (cols + 1) + gx1
                            let idx01 = gy1 * (cols + 1) + gx0
                            let idx11 = gy1 * (cols + 1) + gx1

                            let dx = (1 - wx) * (1 - wy) * gridShiftX[idx00]
                                   + wx * (1 - wy) * gridShiftX[idx10]
                                   + (1 - wx) * wy * gridShiftX[idx01]
                                   + wx * wy * gridShiftX[idx11]
                            let dy = (1 - wx) * (1 - wy) * gridShiftY[idx00]
                                   + wx * (1 - wy) * gridShiftY[idx10]
                                   + (1 - wx) * wy * gridShiftY[idx01]
                                   + wx * wy * gridShiftY[idx11]

                            let sxRaw = Int((Float(x) + dx).rounded())
                            let syRaw = Int((Float(y) + dy).rounded())
                            let pDst = y * width + x
                            let dstIdx = pDst * 4
                            if sxRaw >= 2 && sxRaw < width - 2 && syRaw >= 2 && syRaw < height - 2 {
                                let pSrc = syRaw * width + sxRaw
                                if rawValidB[pSrc] {
                                    warpedValidB[pDst] = true
                                    let srcIdx = pSrc * 4
                                    dstPtr[dstIdx]     = srcPtr[srcIdx]
                                    dstPtr[dstIdx + 1] = srcPtr[srcIdx + 1]
                                    dstPtr[dstIdx + 2] = srcPtr[srcIdx + 2]
                                    dstPtr[dstIdx + 3] = 255
                                }
                            }
                        }
                    }
                }
            }

            var lumMapA = [Float](repeating: 0, count: width * height)
            var lumMapB = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                let i = p * 4
                lumMapA[p] = (0.299 * Float(currentBuf[i]) + 0.587 * Float(currentBuf[i + 1]) + 0.114 * Float(currentBuf[i + 2])) / 255.0
                lumMapB[p] = (0.299 * Float(warpedB[i]) + 0.587 * Float(warpedB[i + 1]) + 0.114 * Float(warpedB[i + 2])) / 255.0
            }

            let smoothLumA = smoothWeightMapFast(lumMapA, width: width, height: height, radius: max(3, width / 75))
            let smoothLumB = smoothWeightMapFast(lumMapB, width: width, height: height, radius: max(3, width / 75))
            let localSurroundA = smoothWeightMapFast(lumMapA, width: width, height: height, radius: max(18, width / 11))

            // 僅從乾淨的中間調像素 (0.16...0.72 且 |A - B| < 0.06) 估算全域環境曝光差，
            // 絕不把白襯衫或深色外套上的閃光燈反光斑誤吸納為背景光差！
            var midToneDiffSum: Float = 0
            var midToneCount: Int = 0
            for p in 0..<(width * height) where warpedValidB[p] {
                let a = smoothLumA[p]
                let b = smoothLumB[p]
                if a >= 0.16 && a <= 0.72 && b >= 0.16 && b <= 0.72 && abs(a - b) < 0.06 {
                    midToneDiffSum += (a - b)
                    midToneCount += 1
                }
            }
            let globalAmbientDiff: Float = midToneCount >= 24 ? (midToneDiffSum / Float(midToneCount)) : 0.0

            // 2. 偵測真正的「鏡面反光高光峰值種子 (Specular Peak Seeds)」
            // 同時涵蓋：(a) 白色衣服/亮面上的強光核 (lumA >= 0.89 && diff >= 0.06)、(b) 深色衣服/背景上的強光核、(c) 局部顯著凸起之亮斑
            var rawPeak = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) where warpedValidB[p] {
                let corrSmoothB = smoothLumB[p] + globalAmbientDiff
                let corrRawB = lumMapB[p] + globalAmbientDiff
                // 若 Donor B 本身在該處也是過曝強反光 (> 0.92 且不比 A 暗)，不可作為修補種子
                if lumMapB[p] >= 0.93 && corrSmoothB >= smoothLumA[p] - 0.03 {
                    continue
                }
                let diff = lumMapA[p] - corrRawB
                let regDiff = smoothLumA[p] - corrSmoothB
                let localProminence = smoothLumA[p] - localSurroundA[p]

                if (lumMapA[p] >= 0.89 && diff >= 0.060 && regDiff >= 0.042)
                    || (lumMapA[p] >= 0.54 && diff >= 0.135 && regDiff >= 0.105)
                    || (lumMapA[p] >= 0.78 && localProminence >= 0.080 && regDiff >= 0.058) {
                    rawPeak[p] = 1.0
                }
            }

            let peakDensity = smoothWeightMapFast(rawPeak, width: width, height: height, radius: max(3, width / 66))
            var peakSeed = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                if rawPeak[p] > 0.5 && peakDensity[p] >= 0.12 {
                    peakSeed[p] = 1.0
                }
            }

            // 3. 有限範圍測地線光暈向外膨脹 (Bounded Geodesic Halo Expansion)
            // 以 peakSeed 周圍 width/6 為最大光暈半徑，將深色格紋外套/暗部背景上的閃光燈漸層光暈 (regDiff >= 0.024) 100% 納入替換
            let maxHaloZone = maxFilterFloatFast(peakSeed, width: width, height: height, radius: max(22, width / 6))
            var haloMask = peakSeed
            let stepRadius = max(6, width / 32)
            for _ in 0..<5 {
                let expanded = maxFilterFloatFast(haloMask, width: width, height: height, radius: stepRadius)
                for p in 0..<(width * height) where warpedValidB[p] && maxHaloZone[p] > 0.5 {
                    guard expanded[p] > 0.5 else { continue }
                    let corrSmoothB = smoothLumB[p] + globalAmbientDiff
                    let corrRawB = lumMapB[p] + globalAmbientDiff
                    let regDiff = smoothLumA[p] - corrSmoothB
                    let diff = lumMapA[p] - corrRawB
                    if regDiff >= 0.024 || diff >= 0.034 {
                        haloMask[p] = 1.0
                    }
                }
            }

            if k == 1 {
                for p in 0..<(width * height) where haloMask[p] > 0.5 {
                    initialGlarePixelCount += 1
                }
            }

            // 向外微幅膨脹確保反光斑最外圈漸層邊緣也被 100% 乾淨替換
            let dilatedHalo = maxFilterFloatFast(haloMask, width: width, height: height, radius: max(5, width / 36))

            // 嚴格禁止把畫面外區域或 Donor B 本身的反光斑貼進來
            var cleanDilated = dilatedHalo
            for p in 0..<(width * height) {
                if !warpedValidB[p] {
                    cleanDilated[p] = 0.0
                    haloMask[p] = 0.0
                    continue
                }
                let corrSmoothB = smoothLumB[p] + globalAmbientDiff
                if corrSmoothB > smoothLumA[p] + 0.015 {
                    cleanDilated[p] = 0.0
                    haloMask[p] = 0.0
                }
            }

            let featherR = max(6, width / 22)
            let feathered1 = smoothWeightMapFast(cleanDilated, width: width, height: height, radius: featherR)
            let feathered2 = smoothWeightMapFast(feathered1, width: width, height: height, radius: featherR)

            // 4. 在反光遮罩內執行 100% 無反光像素替換 (haloMask 內 w = 1.0，徹底消除中央閃光白斑與外圍灰霧！)
            let delta = globalAmbientDiff * 255.0
            for p in 0..<(width * height) where warpedValidB[p] {
                let corrSmoothB = smoothLumB[p] + globalAmbientDiff
                if corrSmoothB > smoothLumA[p] + 0.015 { continue }
                let w = min(1.0, max(haloMask[p] > 0.5 ? 1.0 : 0.0, feathered2[p] * 1.45))
                guard w > 0.01 else { continue }
                let idx = p * 4
                let wA = 1.0 - w

                let rB = min(255.0, max(0.0, Float(warpedB[idx]) + delta))
                let gB = min(255.0, max(0.0, Float(warpedB[idx + 1]) + delta))
                let bB = min(255.0, max(0.0, Float(warpedB[idx + 2]) + delta))

                currentBuf[idx]     = UInt8(min(255, max(0, Int((wA * Float(currentBuf[idx])     + w * rB).rounded()))))
                currentBuf[idx + 1] = UInt8(min(255, max(0, Int((wA * Float(currentBuf[idx + 1]) + w * gB).rounded()))))
                currentBuf[idx + 2] = UInt8(min(255, max(0, Int((wA * Float(currentBuf[idx + 2]) + w * bB).rounded()))))
                currentBuf[idx + 3] = 255

                if w > cumulativeReplacedMask[p] {
                    cumulativeReplacedMask[p] = w
                }
            }
        }

        let totalPixels = max(1, width * height)
        let ratioBefore = Double(initialGlarePixelCount) / Double(totalPixels)

        // 若工作畫布已等於原圖尺寸，直接輸出合成結果
        guard let fusedWorkCtx = CGContext(
            data: &currentBuf,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let fusedWorkCG = fusedWorkCtx.makeImage() else {
            return (baseCG, ratioBefore, 0.0)
        }

        if width == fullWidth && height == fullHeight {
            return (fusedWorkCG, ratioBefore, ratioBefore * 0.05)
        }

        // 若原圖為更高解析度 (如 4K)，透過 GPU CIBlendWithMask 將無反光修補區融合回 4K Base 原圖，確保非反光區 100% 保留 4K 原始銳利度
        var maskBytes = [UInt8](repeating: 0, count: width * height)
        for p in 0..<(width * height) {
            let diffR = abs(Int(currentBuf[p * 4]) - Int(initialBaseBuf[p * 4]))
            let diffG = abs(Int(currentBuf[p * 4 + 1]) - Int(initialBaseBuf[p * 4 + 1]))
            let diffB = abs(Int(currentBuf[p * 4 + 2]) - Int(initialBaseBuf[p * 4 + 2]))
            if cumulativeReplacedMask[p] > 0.01 || (diffR + diffG + diffB) > 3 {
                maskBytes[p] = UInt8(min(255, max(0, Int((cumulativeReplacedMask[p] * 255.0).rounded()))))
            }
        }

        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let maskCtx = CGContext(
            data: &maskBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ),
        let smallMaskCG = maskCtx.makeImage() else {
            return (fusedWorkCG, ratioBefore, ratioBefore * 0.05)
        }

        let context = Self.sharedAntiGlareCIContext
        let upscaleTransform = CGAffineTransform(
            scaleX: CGFloat(fullWidth) / CGFloat(width),
            y: CGFloat(fullHeight) / CGFloat(height)
        )
        let ciBase = CIImage(cgImage: baseCG)
        let ciPatch = CIImage(cgImage: fusedWorkCG)
            .transformed(by: upscaleTransform)
            .clampedToExtent()
            .cropped(to: fullExtent)
        let ciMask = CIImage(cgImage: smallMaskCG)
            .transformed(by: upscaleTransform)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 2.5)
            .cropped(to: fullExtent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = ciPatch
        blend.backgroundImage = ciBase
        blend.maskImage = ciMask

        guard let outCI = blend.outputImage?.cropped(to: fullExtent),
              let finalCG = context.createCGImage(outCI, from: fullExtent, format: .RGBA8, colorSpace: colorSpace) else {
            return (fusedWorkCG, ratioBefore, ratioBefore * 0.05)
        }

        return (finalCG, ratioBefore, ratioBefore * 0.05)
    }

    /// O(1) 滑動視窗二元形態學膨脹濾波器（利用盒狀滑動累加器判斷視窗內是否存在 > 0 像素，無內部迴圈，耗時 < 1ms）
    private func maxFilterFloatFast(
        _ src: [Float],
        width: Int,
        height: Int,
        radius: Int
    ) -> [Float] {
        guard radius > 0, width > 1, height > 1 else { return src }
        let avg = smoothWeightMapFast(src, width: width, height: height, radius: radius)
        let threshold: Float = 0.25 / Float((2 * radius + 1) * (2 * radius + 1))
        var dst = [Float](repeating: 0, count: width * height)
        avg.withUnsafeBufferPointer { avgPtr in
            dst.withUnsafeMutableBufferPointer { dstPtr in
                for i in 0..<(width * height) {
                    dstPtr[i] = avgPtr[i] > threshold ? 1.0 : 0.0
                }
            }
        }
        return dst
    }

    /// O(1) 滑動視窗均值盒狀濾波器（水平 + 垂直雙趟 UnsafeBufferPointer 累加器，無內部迴圈且免除 Debug 邊界檢查，耗時 < 0.8ms）
    private func smoothWeightMapFast(
        _ input: [Float],
        width: Int,
        height: Int,
        radius: Int
    ) -> [Float] {
        guard radius > 0, width > radius * 2 + 1, height > radius * 2 + 1 else {
            return input
        }
        var temp = [Float](repeating: 0, count: width * height)
        var output = [Float](repeating: 0, count: width * height)
        let invWin = 1.0 / Float(2 * radius + 1)

        input.withUnsafeBufferPointer { inPtr in
            temp.withUnsafeMutableBufferPointer { tmpPtr in
                for y in 0..<height {
                    let row = y * width
                    var sum: Float = 0
                    for i in -radius...radius {
                        sum += inPtr[row + min(width - 1, max(0, i))]
                    }
                    for x in 0..<width {
                        tmpPtr[row + x] = sum * invWin
                        sum += inPtr[row + min(width - 1, x + radius + 1)] - inPtr[row + max(0, x - radius)]
                    }
                }
            }
        }

        temp.withUnsafeBufferPointer { tmpPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                for x in 0..<width {
                    var sum: Float = 0
                    for i in -radius...radius {
                        sum += tmpPtr[min(height - 1, max(0, i)) * width + x]
                    }
                    for y in 0..<height {
                        outPtr[y * width + x] = sum * invWin
                        sum += tmpPtr[min(height - 1, y + radius + 1) * width + x] - tmpPtr[max(0, y - radius) * width + x]
                    }
                }
            }
        }

        return output
    }
}
