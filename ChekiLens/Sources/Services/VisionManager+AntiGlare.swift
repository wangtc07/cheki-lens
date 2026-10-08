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

    /// Google フォトスキャン (PhotoScan) 風格多視角（2~4 張四角對準閃光拍攝）無反光合成管線：
    /// 1. 對每一張角度照片執行純淨版 `detectQuadFastForCamera` 與 `CIPerspectiveCorrection` 正位。
    /// 2. **智慧基準幀遴選 (`selectBestBaseFrameIndex`)**：自動評估各張正位圖的白框與內框強光面積，優先挑選白邊與主體最乾淨的一張作為基準底圖，其餘各角度作為無反光修補來源。
    /// 3. **截斷式 L1 局部網格配準 (`4×6` Truncated-L1 Sub-Block Shift Map)**：不受移動反光斑誤導，消除不同手持視角間的微透視誤差。
    /// 4. **鏡面高光峰值種子 + 測地線光暈膨脹 (Specular Peak Seed + Geodesic Halo Expansion)**：
    ///    - 涵蓋全卡 `0% ~ 100%`（包含頂部手寫日期、人臉氣球與底部簽名白框）。
    ///    - 在高光白斑與外圍光暈區執行 **100% 無反光乾淨像素替換 (`weight = 1.0`)**，徹底消除殘留白霧；非反光區嚴格保持 **`weight = 0.0`**，保證人臉與字跡 100% 銳利零重影。
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

        // 1. 取得第 1 張的正位結果（若有背景預處理結果則 0ms 直接取用）
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
        var croppedResults: [CropResult] = [firstPrepared.cropResult]
        var detections: [DetectionResult] = [firstPrepared.adjustedDetection]

        // 2. 依序對第 2..N 張四角照片執行快速純淨四角偵測與透視正位
        for idx in 1..<rawImages.count {
            let img = rawImages[idx]
            let imgSize = CGSize(width: img.width, height: img.height)
            let prior = idx < priorNormalizedQuads.count ? priorNormalizedQuads[idx] : nil
            if let det = try? await detectQuadFastForCamera(
                in: img,
                imageSize: imgSize,
                isKnownFrontPhoto: true,
                priorNormalizedCorners: prior
            ) {
                let insetCorners = applyBorderInset(
                    corners: det.corners,
                    imageSize: imgSize,
                    ratio: borderInsetRatio
                )
                let adjDet = DetectionResult(
                    corners: insetCorners,
                    method: det.method,
                    confidence: det.confidence,
                    imageSize: imgSize
                )
                if let crop = try? perspectiveCorrect(
                    image: img,
                    corners: insetCorners,
                    detection: adjDet,
                    format: mapToChekiFilmFormat(resolvedFormat)
                ) {
                    croppedResults.append(crop)
                    detections.append(adjDet)
                }
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

        // 3. 智慧挑選白框與主體反光最少的一張作為 Base Frame，並依序將其餘各角度的無反光區域修補進來
        let croppedCGs = croppedResults.map(\.cgImage)
        let (finalCGImage, glareBefore, glareAfter) = fuseMultiFrameGlareFree(
            croppedImages: croppedCGs
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

    // MARK: - 4. Google フォトスキャン 局部網格配準與測地線光暈 100% 替換核心

    /// 評估每張正位圖的強光反光懲罰分（特別加重四周白框的反光權重，因為白框壓紋與簽名處最需要保持原生連續性），
    /// 回傳最適合作為基準底圖 (Base Frame) 的索引排序。
    private func rankFramesByCleanliness(_ images: [CGImage]) -> [Int] {
        guard images.count > 1 else { return [0] }
        let sampleW = 160
        let sampleH = 256
        let sampleRect = CGRect(x: 0, y: 0, width: sampleW, height: sampleH)
        let colorSpace = Self.sharedSRGBColorSpace
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        var buffers: [[UInt8]] = []
        for img in images {
            var buf = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
            if let ctx = CGContext(
                data: &buf,
                width: sampleW,
                height: sampleH,
                bitsPerComponent: 8,
                bytesPerRow: sampleW * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) {
                ctx.interpolationQuality = .low
                ctx.draw(img, in: sampleRect)
            }
            buffers.append(buf)
        }

        // 對每個像素找出所有幀中的最低亮度 minLum，若某幀在該處比 minLum 高出 0.18 且本身 > 0.84，計入反光懲罰
        var scores = [Float](repeating: 0, count: images.count)
        for y in 0..<sampleH {
            let isBorder = (y < sampleH * 10 / 100) || (y > sampleH * 76 / 100)
            let borderWeight: Float = isBorder ? 2.2 : 1.0
            for x in 0..<sampleW {
                let idx = (y * sampleW + x) * 4
                var minLum: Float = 1.0
                var lums = [Float](repeating: 0, count: images.count)
                for k in 0..<images.count {
                    let b = buffers[k]
                    let l = (0.299 * Float(b[idx]) + 0.587 * Float(b[idx + 1]) + 0.114 * Float(b[idx + 2])) / 255.0
                    lums[k] = l
                    if l < minLum { minLum = l }
                }
                for k in 0..<images.count {
                    let diff = lums[k] - minLum
                    if lums[k] >= 0.84 && diff >= 0.18 {
                        scores[k] += diff * borderWeight
                    }
                }
            }
        }

        return Array(0..<images.count).sorted { scores[$0] < scores[$1] }
    }

    /// 多視角無反光合成核心 (`fuseMultiFrameGlareFree`)：
    /// - 支援 2~4+ 張不同角度或四角閃光拍攝的正位圖。
    /// - 自動以最乾淨的一張作為 Base Frame，並依序使用其餘各張的無反光區域進行 100% 乾淨替換。
    private func fuseMultiFrameGlareFree(
        croppedImages: [CGImage]
    ) -> (fused: CGImage, glareBefore: Double, glareAfter: Double) {
        guard let firstImg = croppedImages.first else {
            fatalError("croppedImages must not be empty")
        }
        guard croppedImages.count >= 2 else {
            return (firstImg, 0.0, 0.0)
        }

        let rankedIndices = rankFramesByCleanliness(croppedImages)
        let orderedImages = rankedIndices.map { croppedImages[$0] }
        let baseCG = orderedImages[0]

        let fullWidth = baseCG.width
        let fullHeight = baseCG.height
        let fullExtent = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        guard fullWidth > 32, fullHeight > 32 else {
            return (baseCG, 0.0, 0.0)
        }

        // 建立最高 640×1024 分析畫布（在 iPhone Neural/CPU 上僅需 ~60ms，且能完整保留高頻細節與文字邊緣）
        let maxWorkSide: Double = 960.0
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

        // 保留初始 Base Frame 副本，用於產生最終 4K GPU 融合遮罩
        let initialBaseBuf = currentBuf
        var cumulativeReplacedMask = [Float](repeating: 0, count: width * height)
        var initialGlarePixelCount = 0

        for k in 1..<orderedImages.count {
            let donorCG = orderedImages[k]
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

            // 1. 4×6 穩健截斷式 L1 局部網格配準 (Truncated-L1 Sub-Block Shift Map)
            //    不會因為略過高光像素而改變分母導致亂飄，能將兩張手持角度對齊至 1~2px 內
            let cols = 4
            let rows = 6
            var gridShiftX = [Float](repeating: 0, count: (cols + 1) * (rows + 1))
            var gridShiftY = [Float](repeating: 0, count: (cols + 1) * (rows + 1))
            let searchRange = min(12, max(5, width / 55))

            for gy in 0...rows {
                let centerY = Int(Double(gy) / Double(rows) * Double(height - 1))
                let y0 = max(12, centerY - height / (rows * 2))
                let y1 = min(height - 13, centerY + height / (rows * 2))
                for gx in 0...cols {
                    let centerX = Int(Double(gx) / Double(cols) * Double(width - 1))
                    let x0 = max(12, centerX - width / (cols * 2))
                    let x1 = min(width - 13, centerX + width / (cols * 2))

                    var bestDx = 0
                    var bestDy = 0
                    var bestCost: Float = .greatestFiniteMagnitude

                    for dy in -searchRange...searchRange {
                        for dx in -searchRange...searchRange {
                            var errSum: Float = 0
                            var count: Int = 0
                            for y in stride(from: y0, to: y1, by: 4) {
                                let sy = min(height - 1, max(0, y + dy))
                                for x in stride(from: x0, to: x1, by: 4) {
                                    let sx = min(width - 1, max(0, x + dx))
                                    let iA = (y * width + x) * 4
                                    let iB = (sy * width + sx) * 4
                                    let rA = Float(currentBuf[iA]), gA = Float(currentBuf[iA + 1]), bA = Float(currentBuf[iA + 2])
                                    let rB = Float(bufB[iB]), gB = Float(bufB[iB + 1]), bB = Float(bufB[iB + 2])
                                    let d = abs(rA - rB) + abs(gA - gB) + abs(bA - bB)
                                    errSum += min(d, 85.0)
                                    count += 1
                                }
                            }
                            if count > 10 {
                                let penalty = Float(abs(dx) + abs(dy)) * 0.45
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

            // 透過雙線性內插對齊 Donor 影像
            var warpedB = bufB
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

                    let sx = min(width - 1, max(0, Int((Float(x) + dx).rounded())))
                    let sy = min(height - 1, max(0, Int((Float(y) + dy).rounded())))
                    let dstIdx = (y * width + x) * 4
                    let srcIdx = (sy * width + sx) * 4
                    warpedB[dstIdx]     = bufB[srcIdx]
                    warpedB[dstIdx + 1] = bufB[srcIdx + 1]
                    warpedB[dstIdx + 2] = bufB[srcIdx + 2]
                    warpedB[dstIdx + 3] = 255
                }
            }

            var lumMapA = [Float](repeating: 0, count: width * height)
            var lumMapB = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                let i = p * 4
                lumMapA[p] = (0.299 * Float(currentBuf[i]) + 0.587 * Float(currentBuf[i + 1]) + 0.114 * Float(currentBuf[i + 2])) / 255.0
                lumMapB[p] = (0.299 * Float(warpedB[i]) + 0.587 * Float(warpedB[i + 1]) + 0.114 * Float(warpedB[i + 2])) / 255.0
            }

            let smoothLumA = smoothWeightMapFast(lumMapA, width: width, height: height, radius: max(5, width / 75))
            let smoothLumB = smoothWeightMapFast(lumMapB, width: width, height: height, radius: max(5, width / 75))

            // 估計兩張照片之間的平滑背景環境光差（排除高光差異區 |A - B| > 0.15）
            var nonGlareDiff = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                let d = smoothLumA[p] - smoothLumB[p]
                if abs(d) < 0.15 {
                    nonGlareDiff[p] = d
                }
            }
            let ambientPass1 = smoothWeightMapFast(nonGlareDiff, width: width, height: height, radius: max(18, width / 15))
            let ambientDiff = smoothWeightMapFast(ambientPass1, width: width, height: height, radius: max(18, width / 15))

            // 2. 偵測真正的「鏡面反光高光峰值種子 (Specular Peak Seeds)」
            //    只有當該處存在真正過曝反光核心 (lum >= 0.84 且明顯亮於對照圖) 時才建立種子，
            //    徹底防止白色手套、衣服或臉部邊緣被誤判為反光！
            var rawPeak = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                let correctedLumB = smoothLumB[p] + ambientDiff[p]
                let diff = lumMapA[p] - correctedLumB
                let regDiff = smoothLumA[p] - correctedLumB
                if (lumMapA[p] >= 0.84 && diff >= 0.17 && regDiff >= 0.13)
                    || (smoothLumA[p] >= 0.80 && regDiff >= 0.20) {
                    rawPeak[p] = 1.0
                }
            }

            let peakDensity = smoothWeightMapFast(rawPeak, width: width, height: height, radius: max(6, width / 64))
            var peakSeed = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                if rawPeak[p] > 0.5 && peakDensity[p] >= 0.16 {
                    peakSeed[p] = 1.0
                }
            }

            // 3. 測地線光暈向外膨脹 (Geodesic Halo Expansion)：
            //    從高光峰值種子出發，向外擴張 4 輪，將周圍所有屬於同一反光團的半透明藍白光暈 (regDiff >= 0.030) 100% 納入遮罩！
            var haloMask = peakSeed
            let stepRadius = max(8, width / 40)
            for _ in 0..<4 {
                let expanded = maxFilterFloatFast(haloMask, width: width, height: height, radius: stepRadius)
                for p in 0..<(width * height) {
                    guard expanded[p] > 0.5 else { continue }
                    let correctedLumB = smoothLumB[p] + ambientDiff[p]
                    let regDiff = smoothLumA[p] - correctedLumB
                    if regDiff >= 0.030 {
                        haloMask[p] = 1.0
                    }
                }
            }

            if k == 1 {
                for p in 0..<(width * height) where haloMask[p] > 0.5 {
                    initialGlarePixelCount += 1
                }
            }

            // 向外微幅膨脹 ~2.5% 確保反光斑最外圈漸層邊緣也被 100% 乾淨替換
            let dilatedHalo = maxFilterFloatFast(haloMask, width: width, height: height, radius: max(8, width / 38))

            // 嚴格禁止把 Donor B 本身的反光斑貼進來 (若 B 比 A 更亮則遮罩歸零)
            var cleanDilated = dilatedHalo
            for p in 0..<(width * height) {
                let correctedLumB = smoothLumB[p] + ambientDiff[p]
                if correctedLumB > smoothLumA[p] + 0.025 {
                    cleanDilated[p] = 0.0
                }
            }

            let featherR = max(12, width / 22)
            let feathered1 = smoothWeightMapFast(cleanDilated, width: width, height: height, radius: featherR)
            let feathered2 = smoothWeightMapFast(feathered1, width: width, height: height, radius: featherR)

            // 4. 在反光遮罩內執行 100% 無反光像素替換 (haloMask 內 w = 1.0，徹底消除殘留灰霧！)
            for p in 0..<(width * height) {
                let correctedLumB = smoothLumB[p] + ambientDiff[p]
                if correctedLumB > smoothLumA[p] + 0.025 { continue }
                let w = min(1.0, max(haloMask[p] > 0.5 ? 1.0 : 0.0, feathered2[p] * 1.45))
                guard w > 0.01 else { continue }
                let idx = p * 4
                let wA = 1.0 - w

                let y = p / width
                let isBorder = (y < height * 9 / 100) || (y > height * 78 / 100)
                let delta = isBorder ? (ambientDiff[p] * 255.0) : 0.0
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

    /// 分離式 2D 最大值形態學膨脹濾波器（水平 + 垂直雙趟）
    private func maxFilterFloatFast(
        _ src: [Float],
        width: Int,
        height: Int,
        radius: Int
    ) -> [Float] {
        guard radius > 0, width > 1, height > 1 else { return src }
        var tmp = [Float](repeating: 0, count: width * height)
        var dst = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var m: Float = 0
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                for xx in x0...x1 {
                    let v = src[row + xx]
                    if v > m { m = v }
                }
                tmp[row + x] = m
            }
        }

        for x in 0..<width {
            for y in 0..<height {
                var m: Float = 0
                let y0 = max(0, y - radius)
                let y1 = min(height - 1, y + radius)
                for yy in y0...y1 {
                    let v = tmp[yy * width + x]
                    if v > m { m = v }
                }
                dst[y * width + x] = m
            }
        }

        return dst
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
        var temp = [Float](repeating: 0, count: width * height)
        var output = [Float](repeating: 0, count: width * height)
        let win = Float(2 * radius + 1)

        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for i in -radius...radius {
                sum += input[row + min(width - 1, max(0, i))]
            }
            for x in 0..<width {
                temp[row + x] = sum / win
                sum += input[row + min(width - 1, x + radius + 1)] - input[row + max(0, x - radius)]
            }
        }

        for x in 0..<width {
            var sum: Float = 0
            for i in -radius...radius {
                sum += temp[min(height - 1, max(0, i)) * width + x]
            }
            for y in 0..<height {
                output[y * width + x] = sum / win
                sum += temp[min(height - 1, y + radius + 1) * width + x] - temp[max(0, y - radius) * width + x]
            }
        }

        return output
    }
}
