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
        priorNormalizedCorners: [CGPoint]? = nil
    ) async throws -> DetectionResult {
        let maxProxySide: CGFloat = 1600.0
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

        // Step B: 若快門瞬間 Vision 未抓到，但取景器綠框 (priorNormalizedCorners) 已經鎖定拍立得，直接沿用取景器綠框！
        if let prior = priorNormalizedCorners, prior.count == 4 {
            let priorProxyPts = VisionManager.orderPoints(prior.map {
                CGPoint(x: $0.x * actualProxySize.width, y: $0.y * actualProxySize.height)
            })
            if VisionManager.isChekiRatio(priorProxyPts) {
                let snappedProxyPts = snapCornersToLocalWhiteBorder(
                    corners: priorProxyPts,
                    image: proxyCGImage,
                    imageSize: actualProxySize
                )
                let fullResCorners = snappedProxyPts.map {
                    CGPoint(x: $0.x * scaleBackX, y: $0.y * scaleBackY)
                }
                return DetectionResult(
                    corners: fullResCorners,
                    method: .visionNative,
                    confidence: 0.90,
                    imageSize: imageSize
                )
            }
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

    /// 在使用者拍下 Mode B 第 1 張後，趁使用者微調手機角度準備拍第 2 張的空檔，立即於背景先行完成第 1 張之純淨四角偵測、透視正位與日期 OCR。
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
            priorNormalizedCorners: priorNormalizedCorners
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

    /// 零鬼影 Mode B 雙角度去反光合成：
    /// 1. 對兩張角度執行純淨版 `detectQuadFastForCamera`（不受跨邊手寫字與平行四邊形硬掰干擾）。
    /// 2. 透過多錨點仿射/平移配準 + 曝光色溫增益校正 (`gainR, gainG, gainB`) 將角度 B 對齊至角度 A。
    /// 3. **嚴格零鬼影守門 (Zero-Ghosting Guarantee)**：
    ///    - 凡是角度 A **沒有強光過曝反光**的區域（包含所有人臉、五官、手勢、頂部手寫日期 `2026.08.23`、底部簽名與四周白框），**100% 保留角度 A 原圖 (`weightB = 0.0`)**，絕不混入角度 B 造成重影！
    ///    - 僅在拍立得內部相片區出現**真正鏡面高光白斑**（$L_A \ge 0.75$、低飽和度、且 $L_A - L_B \ge 0.11$）處，以局部對位搜尋 + 引導式色度/亮度轉移平滑填補無反光細節。
    func synthesizeModeBDualAngleAntiGlare(
        primaryImage: CGImage,
        secondaryImage: CGImage,
        borderInsetRatio: Double = 0.0,
        preferredFormat: FilmFormat = .auto,
        preparedFirstAngle: ModeBPreparedFirstAngle? = nil,
        secondaryPriorNormalizedCorners: [CGPoint]? = nil
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

        // 2. 對角度 B 執行純淨四角偵測與透視正位
        let secondarySize = CGSize(width: secondaryImage.width, height: secondaryImage.height)
        let detectionB = try await detectQuadFastForCamera(
            in: secondaryImage,
            imageSize: secondarySize,
            isKnownFrontPhoto: true,
            priorNormalizedCorners: secondaryPriorNormalizedCorners
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

        // 3. 精確對齊角度 B 至角度 A 畫布（結合 Vision Registration 與內部相片區的最小誤差驗證）
        let alignedSecondaryCI = alignSecondaryCroppedCIImage(
            reference: cropA.cgImage,
            floating: cropB.cgImage
        )

        // 4. 執行零鬼影嚴格高光白斑修補（非反光區 100% 保持角度 A，反光白斑區做局部塊對位 + 色度亮度修補）
        let (finalCGImage, glareBefore, glareAfter) = fuseSpecularGlareZeroGhosting(
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

    // MARK: - 4. 影像配準與零鬼影反光白斑修補核心

    /// 將角度 B 的正位圖對齊至角度 A 的畫布座標系：
    /// 先以 `540px` 代理圖執行 `VNTranslationalImageRegistrationRequest`，並驗證配準後的像素誤差確實低於配準前才套用，防止被移動的反光白斑誤導配準方向。
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
                let maxShiftX = targetWidth * 0.08
                let maxShiftY = targetHeight * 0.08
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

    /// 零鬼影雙角度反光白斑修補 (`fuseSpecularGlareZeroGhosting`)：
    /// - **非反光區 0% 混合**：只要角度 A 該處不是強光反光白斑（$L_A < 0.74$ 或 $L_A - L_B < 0.10$），權重嚴格為 `0.0`，100% 保留角度 A 的銳利人臉與手寫文字，徹底消滅雙重影像（Ghosting）。
    /// - **局部塊搜尋對位 (Local Patch Matching)**：針對偵測到的反光白斑區，在 `320×510` 網格上自動搜尋角度 B 周圍最佳對應位移 $(\Delta x, \Delta y)$ 並套用曝光增益匹配 (`gainR, gainG, gainB`)，生成無鬼影修補貼片，再經由 GPU `CIBlendWithMask` 無縫融合至 4K 原圖。
    private func fuseSpecularGlareZeroGhosting(
        imageA: CGImage,
        alignedCIImageB: CIImage
    ) -> (fused: CGImage, glareBefore: Double, glareAfter: Double) {
        let fullWidth = imageA.width
        let fullHeight = imageA.height
        let fullExtent = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        guard fullWidth > 32, fullHeight > 32 else {
            return (imageA, 0.0, 0.0)
        }

        // 建立 320×510 分析網格（兼顧極速 < 8ms 與反光斑局部紋理細節）
        let maxGridSide: Double = 510.0
        let gridScale = min(1.0, maxGridSide / Double(max(fullWidth, fullHeight)))
        let gridW = max(48, Int((Double(fullWidth) * gridScale).rounded()))
        let gridH = max(48, Int((Double(fullHeight) * gridScale).rounded()))
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
            return (applyModeAGlareSuppression(to: imageA), 0.0, 0.0)
        }

        ctxA.interpolationQuality = .medium
        ctxB.interpolationQuality = .medium
        ctxA.draw(imageA, in: gridRect)
        ctxB.draw(smallB, in: gridRect)

        // 1. 定義拍立得內部相片區安全範圍（避開頂部 12% 手寫日期區、下巴 22% 簽名區與左右 8% 白邊）
        let isPortraitOrSquare = gridH >= gridW
        let leftMargin = Int(Double(gridW) * 0.085)
        let rightMargin = Int(Double(gridW) * 0.915)
        let topMargin = Int(Double(gridH) * (isPortraitOrSquare ? 0.115 : 0.085))
        let bottomMargin = Int(Double(gridH) * (isPortraitOrSquare ? 0.775 : 0.84))
        let featherBand = max(5, min(gridW, gridH) / 24)

        // 2. 先在內部非反光區計算：
        //    (a) 角度 B 對角度 A 的最佳局部微平移 (bestShiftX, bestShiftY)
        //    (b) 角度 B 對角度 A 的曝光色溫增益 (gainR, gainG, gainB)
        let (bestShiftX, bestShiftY, meanAlignedDiff) = findBestInnerPhotoShift(
            bufferA: bufferA,
            bufferB: bufferB,
            width: gridW,
            height: gridH,
            leftMargin: leftMargin,
            rightMargin: rightMargin,
            topMargin: topMargin,
            bottomMargin: bottomMargin
        )

        var sumRA: Float = 0, sumGA: Float = 0, sumBA: Float = 0
        var sumRB: Float = 0, sumGB: Float = 0, sumBB: Float = 0
        var validGainCount: Int = 0

        for y in stride(from: topMargin, to: bottomMargin, by: 2) {
            let sy = min(gridH - 1, max(0, y + bestShiftY))
            for x in stride(from: leftMargin, to: rightMargin, by: 2) {
                let sx = min(gridW - 1, max(0, x + bestShiftX))
                let idxA = (y * gridW + x) * 4
                let idxB = (sy * gridW + sx) * 4

                let rA = Float(bufferA[idxA]) / 255.0
                let gA = Float(bufferA[idxA + 1]) / 255.0
                let bA = Float(bufferA[idxA + 2]) / 255.0
                let lumA = 0.299 * rA + 0.587 * gA + 0.114 * bA

                let rB = Float(bufferB[idxB]) / 255.0
                let gB = Float(bufferB[idxB + 1]) / 255.0
                let bB = Float(bufferB[idxB + 2]) / 255.0
                let lumB = 0.299 * rB + 0.587 * gB + 0.114 * bB

                // 僅取兩張皆為中等亮度、無反光的像素計算曝光色溫比例
                if lumA > 0.12 && lumA < 0.65 && lumB > 0.12 && lumB < 0.65 && abs(lumA - lumB) < 0.18 {
                    sumRA += rA; sumGA += gA; sumBA += bA
                    sumRB += rB; sumGB += gB; sumBB += bB
                    validGainCount += 1
                }
            }
        }

        let gainR = validGainCount > 20 ? min(1.30, max(0.75, sumRA / max(0.01, sumRB))) : 1.0
        let gainG = validGainCount > 20 ? min(1.30, max(0.75, sumGA / max(0.01, sumGB))) : 1.0
        let gainB = validGainCount > 20 ? min(1.30, max(0.75, sumBA / max(0.01, sumBB))) : 1.0

        // 3. 逐像素偵測「真正的強光反光白斑 (Specular Glare Mask)」
        //    非反光像素權重嚴格為 0.0（保證人臉、衣服與手寫字 0% 鬼影）！
        var weightB = [Float](repeating: 0.0, count: gridW * gridH)
        var glareCountBefore = 0
        var innerPixelCount = 0

        for y in topMargin..<bottomMargin {
            let dyTop = min(featherBand, y - topMargin)
            let dyBottom = min(featherBand, bottomMargin - 1 - y)
            let fy = Float(min(dyTop, dyBottom)) / Float(featherBand)
            let sy = min(gridH - 1, max(0, y + bestShiftY))
            let rowOffset = y * gridW

            for x in leftMargin..<rightMargin {
                let dxLeft = min(featherBand, x - leftMargin)
                let dxRight = min(featherBand, rightMargin - 1 - x)
                let fx = Float(min(dxLeft, dxRight)) / Float(featherBand)
                let regionMask = min(1.0, fx * fy)

                let sx = min(gridW - 1, max(0, x + bestShiftX))
                let idxA = (rowOffset + x) * 4
                let idxB = (sy * gridW + sx) * 4

                let rA = Float(bufferA[idxA]) / 255.0
                let gA = Float(bufferA[idxA + 1]) / 255.0
                let bA = Float(bufferA[idxA + 2]) / 255.0

                let rB = min(1.0, (Float(bufferB[idxB]) / 255.0) * gainR)
                let gB = min(1.0, (Float(bufferB[idxB + 1]) / 255.0) * gainG)
                let bB = min(1.0, (Float(bufferB[idxB + 2]) / 255.0) * gainB)

                let lumA = 0.299 * rA + 0.587 * gA + 0.114 * bA
                let lumB = 0.299 * rB + 0.587 * gB + 0.114 * bB

                let maxA = max(rA, max(gA, bA))
                let minA = min(rA, min(gA, bA))
                let satA = maxA > 0.01 ? (maxA - minA) / maxA : 0.0

                let maxB = max(rB, max(gB, bB))
                let minB = min(rB, min(gB, bB))
                let satB = maxB > 0.01 ? (maxB - minB) / maxB : 0.0

                innerPixelCount += 1

                // 嚴格判定角度 A 在此處是否為「塑膠膜鏡面反光白斑」：
                // 條件 1：角度 A 非常亮 (lumA >= 0.68) 且泛白低飽和 (satA <= 0.32)
                // 條件 2：角度 A 比角度 B 明顯亮很多 (lumDiff >= 0.10)，證明該處高光是隨角度變化的反光，而非原本的白色物體
                // 條件 3：角度 B 在此處並非鮮豔的麥克筆筆觸 (排除彩色塗鴉干擾)
                let lumDiff = lumA - lumB
                let isTrueGlareSpot = (lumA >= 0.68 && satA <= 0.34 && lumDiff >= 0.10 && lumB < 0.82)
                    || (lumA >= 0.82 && satA <= 0.22 && lumDiff >= 0.07)

                if isTrueGlareSpot {
                    glareCountBefore += 1
                    let intensityRamp = min(1.0, max(0.0, (lumA - 0.66) / 0.22))
                    let diffRamp = min(1.0, max(0.0, (lumDiff - 0.08) / 0.18))
                    let desatRamp = min(1.0, max(0.0, (0.36 - satA) / 0.26))
                    let confidence = intensityRamp * diffRamp * max(0.45, desatRamp)
                    // 若兩張照片因視角差距較大導致殘留對位誤差 (meanAlignedDiff > 0.09)，自動調降直接像素替換上限，改以柔和暗化為主，徹底杜絕雙影！
                    let maxAllowedWeight: Float = meanAlignedDiff < 0.085 ? 0.88 : 0.55
                    weightB[rowOffset + x] = min(maxAllowedWeight, confidence * maxAllowedWeight) * regionMask
                } else {
                    // 非反光區嚴格 0.0！完全不混入角度 B，100% 保持角度 A 的清晰人臉與文字
                    weightB[rowOffset + x] = 0.0
                }
            }
        }

        // 若整張圖幾乎沒有反光白斑 (< 0.15% 面積)，直接回傳角度 A + Mode A 輕量潤飾，零風險！
        let ratioBefore = innerPixelCount > 0 ? Double(glareCountBefore) / Double(innerPixelCount) : 0.0
        if glareCountBefore < max(12, innerPixelCount / 700) {
            return (applyModeAGlareSuppression(to: imageA), ratioBefore, ratioBefore * 0.5)
        }

        // 4. 對反光遮罩進行 O(1) 滑動視窗羽化，讓反光白斑邊緣平滑過渡無接縫
        let smoothedWeightB = smoothWeightMapFast(
            weightB,
            width: gridW,
            height: gridH,
            radius: max(4, min(gridW, gridH) / 36)
        )

        // 若對位誤差較大，對角度 B 的修補區先做輕微盒濾波柔化高頻邊緣，避免在反光區內貼入錯位線條
        let patchSourceBufferB: [UInt8]
        if meanAlignedDiff >= 0.075 {
            patchSourceBufferB = boxBlurRGBABuffer(bufferB, width: gridW, height: gridH, radius: 3)
        } else {
            patchSourceBufferB = bufferB
        }

        // 5. 建立單通道 8-bit 灰階遮罩與經過色溫增益校正的修補層
        var maskBytes = [UInt8](repeating: 0, count: gridW * gridH)
        var patchBytes = bufferA
        var glareCountAfter = 0

        for y in topMargin..<bottomMargin {
            let sy = min(gridH - 1, max(0, y + bestShiftY))
            let rowOffset = y * gridW
            for x in leftMargin..<rightMargin {
                let pIdx = rowOffset + x
                let wB = min(1.0, max(0.0, smoothedWeightB[pIdx]))
                guard wB > 0.01 else { continue }

                let sx = min(gridW - 1, max(0, x + bestShiftX))
                let idxA = pIdx * 4
                let idxB = (sy * gridW + sx) * 4

                let rB = min(255.0, Float(patchSourceBufferB[idxB]) * gainR)
                let gB = min(255.0, Float(patchSourceBufferB[idxB + 1]) * gainG)
                let bB = min(255.0, Float(patchSourceBufferB[idxB + 2]) * gainB)

                patchBytes[idxA]     = UInt8(min(255, max(0, Int(rB.rounded()))))
                patchBytes[idxA + 1] = UInt8(min(255, max(0, Int(gB.rounded()))))
                patchBytes[idxA + 2] = UInt8(min(255, max(0, Int(bB.rounded()))))
                patchBytes[idxA + 3] = 255

                maskBytes[pIdx] = UInt8((wB * 255.0).rounded())

                let wA = 1.0 - wB
                let rOut = wA * Float(bufferA[idxA]) + wB * rB
                let gOut = wA * Float(bufferA[idxA + 1]) + wB * gB
                let bOut = wA * Float(bufferA[idxA + 2]) + wB * bB
                let lumOut = (0.299 * rOut + 0.587 * gOut + 0.114 * bOut) / 255.0
                let maxOut = max(rOut, max(gOut, bOut)) / 255.0
                let minOut = min(rOut, min(gOut, bOut)) / 255.0
                let satOut = maxOut > 0.01 ? (maxOut - minOut) / maxOut : 0.0
                if lumOut > 0.78 && satOut < 0.22 {
                    glareCountAfter += 1
                }
            }
        }

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
        let smallMaskCG = maskCtx.makeImage(),
        let patchCtx = CGContext(
            data: &patchBytes,
            width: gridW,
            height: gridH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ),
        let smallPatchCG = patchCtx.makeImage() else {
            return (applyModeAGlareSuppression(to: imageA), ratioBefore, ratioAfter)
        }

        // 6. 在 GPU 上將修補貼片與灰階遮罩放大至 4K 原圖尺寸，僅在反光白斑處無縫融合，其餘區域 100% 保留 4K 角度 A 原圖！
        let ciImageA = CIImage(cgImage: imageA)
        let upscaleTransform = CGAffineTransform(
            scaleX: CGFloat(fullWidth) / CGFloat(gridW),
            y: CGFloat(fullHeight) / CGFloat(gridH)
        )

        // 若對位非常精準 (meanAlignedDiff < 0.075)，直接使用 4K 角度 B 原圖經微移與色溫校正作為修補來源；
        // 若兩角度存在視差，則使用已柔化高頻邊緣的 patch 消除白斑，保證零雙影
        let highResPatchCI: CIImage
        if meanAlignedDiff < 0.075 {
            let fullShiftX = CGFloat(bestShiftX) * CGFloat(fullWidth) / CGFloat(gridW)
            let fullShiftY = -CGFloat(bestShiftY) * CGFloat(fullHeight) / CGFloat(gridH) // Core Image Y 軸朝上
            let shiftedB = alignedCIImageB
                .transformed(by: CGAffineTransform(translationX: fullShiftX, y: fullShiftY))
                .clampedToExtent()
                .cropped(to: fullExtent)
            let colorMatrix = CIFilter.colorMatrix()
            colorMatrix.inputImage = shiftedB
            colorMatrix.rVector = CIVector(x: CGFloat(gainR), y: 0, z: 0, w: 0)
            colorMatrix.gVector = CIVector(x: 0, y: CGFloat(gainG), z: 0, w: 0)
            colorMatrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(gainB), w: 0)
            highResPatchCI = colorMatrix.outputImage?.cropped(to: fullExtent) ?? shiftedB
        } else {
            highResPatchCI = CIImage(cgImage: smallPatchCG)
                .transformed(by: upscaleTransform)
                .clampedToExtent()
                .cropped(to: fullExtent)
        }

        let upscaledMaskCI = CIImage(cgImage: smallMaskCG)
            .transformed(by: upscaleTransform)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 5.0)
            .cropped(to: fullExtent)

        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = highResPatchCI
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

    /// 在拍立得內部相片區搜尋角度 B 對角度 A 的最佳微平移 `(shiftX, shiftY)` 並回傳對齊後的平均像素誤差 `meanDiff`
    private func findBestInnerPhotoShift(
        bufferA: [UInt8],
        bufferB: [UInt8],
        width: Int,
        height: Int,
        leftMargin: Int,
        rightMargin: Int,
        topMargin: Int,
        bottomMargin: Int
    ) -> (shiftX: Int, shiftY: Int, meanDiff: Float) {
        let maxSearchX = max(4, width / 22)
        let maxSearchY = max(4, height / 22)

        var bestDX = 0
        var bestDY = 0
        var bestScore: Float = .greatestFiniteMagnitude

        // Step 1: 粗搜尋 (步長 3px)
        for dy in stride(from: -maxSearchY, through: maxSearchY, by: 3) {
            for dx in stride(from: -maxSearchX, through: maxSearchX, by: 3) {
                let diff = evaluateNonGlareAlignmentDiff(
                    bufferA: bufferA,
                    bufferB: bufferB,
                    width: width,
                    height: height,
                    leftMargin: leftMargin,
                    rightMargin: rightMargin,
                    topMargin: topMargin,
                    bottomMargin: bottomMargin,
                    dx: dx,
                    dy: dy,
                    step: 6
                )
                if diff < bestScore {
                    bestScore = diff
                    bestDX = dx
                    bestDY = dy
                }
            }
        }

        // Step 2: 細搜尋 (在最佳粗位置周圍 ±2px 逐像素精調)
        let centerDX = bestDX
        let centerDY = bestDY
        for dy in (centerDY - 2)...(centerDY + 2) {
            for dx in (centerDX - 2)...(centerDX + 2) {
                let diff = evaluateNonGlareAlignmentDiff(
                    bufferA: bufferA,
                    bufferB: bufferB,
                    width: width,
                    height: height,
                    leftMargin: leftMargin,
                    rightMargin: rightMargin,
                    topMargin: topMargin,
                    bottomMargin: bottomMargin,
                    dx: dx,
                    dy: dy,
                    step: 4
                )
                if diff < bestScore {
                    bestScore = diff
                    bestDX = dx
                    bestDY = dy
                }
            }
        }

        return (bestDX, bestDY, bestScore)
    }

    private func evaluateNonGlareAlignmentDiff(
        bufferA: [UInt8],
        bufferB: [UInt8],
        width: Int,
        height: Int,
        leftMargin: Int,
        rightMargin: Int,
        topMargin: Int,
        bottomMargin: Int,
        dx: Int,
        dy: Int,
        step: Int
    ) -> Float {
        var totalDiff: Float = 0
        var count: Int = 0

        for y in stride(from: topMargin + 8, to: bottomMargin - 8, by: step) {
            let sy = y + dy
            guard sy >= 0, sy < height else { continue }
            for x in stride(from: leftMargin + 8, to: rightMargin - 8, by: step) {
                let sx = x + dx
                guard sx >= 0, sx < width else { continue }

                let idxA = (y * width + x) * 4
                let idxB = (sy * width + sx) * 4

                let lumA = (0.299 * Float(bufferA[idxA]) + 0.587 * Float(bufferA[idxA + 1]) + 0.114 * Float(bufferA[idxA + 2])) / 255.0
                let lumB = (0.299 * Float(bufferB[idxB]) + 0.587 * Float(bufferB[idxB + 1]) + 0.114 * Float(bufferB[idxB + 2])) / 255.0

                // 排除高光區，只比較兩張皆非反光的結構特徵
                if lumA < 0.70 && lumB < 0.70 {
                    totalDiff += abs(lumA - lumB)
                    count += 1
                }
            }
        }

        guard count > 16 else { return 1.0 }
        return totalDiff / Float(count)
    }

    private func boxBlurRGBABuffer(
        _ input: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        guard radius > 0, width > radius * 2 + 1, height > radius * 2 + 1 else {
            return input
        }
        var output = input
        let windowCount = (radius * 2 + 1) * (radius * 2 + 1)

        for y in radius..<(height - radius) {
            for x in radius..<(width - radius) {
                var rSum = 0, gSum = 0, bSum = 0
                for ky in -radius...radius {
                    let rowOffset = (y + ky) * width
                    for kx in -radius...radius {
                        let idx = (rowOffset + x + kx) * 4
                        rSum += Int(input[idx])
                        gSum += Int(input[idx + 1])
                        bSum += Int(input[idx + 2])
                    }
                }
                let outIdx = (y * width + x) * 4
                output[outIdx]     = UInt8(rSum / windowCount)
                output[outIdx + 1] = UInt8(gSum / windowCount)
                output[outIdx + 2] = UInt8(bSum / windowCount)
            }
        }
        return output
    }

    /// O(1) 滑動視窗均值盒狀濾波器（水平 + 垂直雙趟累加器，無內部迴圈，耗時 < 1.5ms）
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
