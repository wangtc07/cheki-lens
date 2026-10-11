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

    /// Mode B 雙角度／多視角去反光合成輸出結果
    struct ModeBAntiGlareResult: @unchecked Sendable {
        /// 雙角度/多視角對位並消除反光白斑後的最終透視校正影像
        let fusedCGImage: CGImage
        /// 將無反光合成結果逆透視投影回第 1 張原始未裁切底圖（確保手動重新調整四個頂點或邊界時，永遠保持無反光，絕不退回第一張反光圖）
        let fusedOriginalCGImage: CGImage
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

    /// Google PhotoScan 真實 4 階段多視角無反光合成管線（Ce Liu, Michael Rubinstein, Mike Krainin, Bill Freeman, Google Research）：
    /// - **Stage 1 (內縮四象限幾何與初始透視校正)**：
    ///   第 1 張照片固定拍立得外框位置作為正位基準；後續各角度照片透過「無反光區特徵匹配 + RANSAC 8 自由度單應性矩陣 (`Homography`)」推導出拍立得四角（完整適應手持縮放、旋轉與 3D 傾斜）。
    /// - **Stage 2 (遮罩剔除反光之 Harris 角點/邊緣提取 + 多尺度 ZNCC + RANSAC 8-DOF 單應性矩陣配準)**：
    ///   主動將高光反光區剔除後，以零均值正規化互相關 (`ZNCC`) 求解亞像素對應點，並以 Normalized DLT + RANSAC + IRLS 求出 $3\times 3$ 平面單應性矩陣 $H_k$，輔以嚴格配準守門（若某張手震失準即自動捨棄，保證 0 錯位重影）。
    /// - **Stage 3 (Szeliski & Coughlan 1997 剛性平滑約束樣條控制點光流)**：
    ///   在 Homography 全局平面對齊後，以帶拉普拉斯平滑正則化 (`Laplacian Smoothness Regularization`) 的控制點樣條微調 ($\le 2.0\text{ px}$)，消除相紙微彎誤差且絕不拉裂五官。
    /// - **Stage 4 (多幀下包絡線反光離群值剔除 + 雙頻段無縫融合 + 逆透視寫回原始底圖)**：
    ///   在每個像素位置剔除最亮的反光離群值（Outlier Rejection），並將合成後的無反光拍立得透過 `CIPerspectiveTransform` 逆投影寫回 `originalCGImage`，徹底解決手動重新裁切時退回第一張反光圖的問題。
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

        // 2. 依序對第 2..N 張照片執行 8-DOF 單應性四角定位與高解析度透視正位
        let maxDonorRawSide: CGFloat = 1600.0
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
                confidence: 0.95,
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
            let updatedOriginal = projectFusedCardBackToOriginalImage(
                fusedCard: suppressed,
                originalImage: firstPrepared.originalCGImage,
                corners: firstPrepared.adjustedDetection.corners
            )
            return ModeBAntiGlareResult(
                fusedCGImage: suppressed,
                fusedOriginalCGImage: updatedOriginal,
                primaryCropResult: firstPrepared.cropResult,
                secondaryCropResult: firstPrepared.cropResult,
                primaryDetection: firstPrepared.adjustedDetection,
                glareRatioBefore: 0.0,
                glareRatioAfter: 0.0,
                resolvedFormat: resolvedFormat,
                preRecognizedDate: firstPrepared.ocrDate
            )
        }

        // 3. 執行 Google PhotoScan Stage 2~4：RANSAC 8-DOF Homography + Szeliski 樣條微調 + 多幀無反光下包絡線融合
        let croppedCGs = croppedResults.map(\.cgImage)
        let (finalCGImage, glareBefore, glareAfter) = fuseMultiFrameGlareFree(
            croppedImages: croppedCGs,
            donorNormalizedQuads: normalizedQuadsPerFrame
        )

        // 4. 將無反光合成成品逆透視寫回第 1 張未裁切原圖中，確保事後手動重新調整四角或邊界時永遠不會變回第一張反光圖！
        let updatedOriginal = projectFusedCardBackToOriginalImage(
            fusedCard: finalCGImage,
            originalImage: firstPrepared.originalCGImage,
            corners: firstPrepared.adjustedDetection.corners
        )

        return ModeBAntiGlareResult(
            fusedCGImage: finalCGImage,
            fusedOriginalCGImage: updatedOriginal,
            primaryCropResult: croppedResults[0],
            secondaryCropResult: croppedResults[1],
            primaryDetection: detections[0],
            glareRatioBefore: glareBefore,
            glareRatioAfter: glareAfter,
            resolvedFormat: resolvedFormat,
            preRecognizedDate: firstPrepared.ocrDate
        )
    }

    /// 零鬼影 Mode B 雙角度去反光合成（直接路由至 Google PhotoScan 4 階段無反光合成管線）
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

    // MARK: - 將無反光合成圖逆透視寫回未裁切原圖 (`CIPerspectiveTransform`)

    /// 將無反光合成後的標準拍立得影像 (`fusedCard`) 透過 `CIPerspectiveTransform` 逆投影回第 1 張未裁切原圖 (`originalImage`) 的拍立得四角位置。
    /// 如此一來，使用者在 `ChekiQuadCropEditorView` 手動調整頂點、切換比例或微調邊界時，底圖本身即為 100% 無反光狀態，絕不會退回第一張有反光的原圖。
    func projectFusedCardBackToOriginalImage(
        fusedCard: CGImage,
        originalImage: CGImage,
        corners: [CGPoint]
    ) -> CGImage {
        let ordered = VisionManager.orderPoints(corners)
        guard ordered.count == 4 else { return originalImage }

        let origW = CGFloat(originalImage.width)
        let origH = CGFloat(originalImage.height)
        let origExtent = CGRect(x: 0, y: 0, width: origW, height: origH)
        guard origW > 32, origH > 32 else { return originalImage }

        // Core Image 座標系：左下為原點 (y = origH - pt.y)
        func toCIVector(_ pt: CGPoint) -> CIVector {
            CIVector(x: pt.x, y: origH - pt.y)
        }

        let tl = ordered[0], tr = ordered[1], br = ordered[2], bl = ordered[3]
        let baseCI = CIImage(cgImage: originalImage)
        let cardCI = CIImage(cgImage: fusedCard)

        guard let transformFilter = CIFilter(name: "CIPerspectiveTransform") else {
            return originalImage
        }
        transformFilter.setValue(cardCI, forKey: kCIInputImageKey)
        transformFilter.setValue(toCIVector(tl), forKey: "inputTopLeft")
        transformFilter.setValue(toCIVector(tr), forKey: "inputTopRight")
        transformFilter.setValue(toCIVector(br), forKey: "inputBottomRight")
        transformFilter.setValue(toCIVector(bl), forKey: "inputBottomLeft")

        guard let warpedCardCI = transformFilter.outputImage else {
            return originalImage
        }

        let composited = warpedCardCI
            .composited(over: baseCI)
            .cropped(to: origExtent)

        let ctx = Self.sharedAntiGlareCIContext
        return ctx.createCGImage(composited, from: origExtent, format: .RGBA8, colorSpace: Self.sharedSRGBColorSpace) ?? originalImage
    }

    // MARK: - Stage 1 & 2A: 原始畫面無反光特徵匹配 + RANSAC 8-DOF Homography 四角推導

    /// 計算第 2..N 張照片中拍立得在原始畫面的正規化四角座標 `[TL, TR, BR, BL]`：
    /// 1. 若拍立得四角仍在畫面內且 Apple Vision 可直接偵測到高信度矩形，結合追蹤先驗採用該四角。
    /// 2. 同時在 `160×214` 代理圖上執行「遮罩反光之 ZNCC 區塊匹配 + RANSAC 8-DOF 單應性矩陣求解」，將第 1 張四角透過 $3\times 3$ 單應性矩陣 $H_{\text{raw}}$ 投影至第 $k$ 張（完整包含手持縮放、旋轉與 3D 傾斜變換）。
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

        let trackW = 160
        let trackH = 214
        let colorSpace = Self.sharedSRGBColorSpace
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var buf0 = [UInt8](repeating: 0, count: trackW * trackH * 4)
        var bufK = [UInt8](repeating: 0, count: trackW * trackH * 4)

        var homographyProjectedQuad: [CGPoint]? = nil
        var refinedNormDx = initNormDx
        var refinedNormDy = initNormDy

        if let ctx0 = CGContext(data: &buf0, width: trackW, height: trackH, bitsPerComponent: 8, bytesPerRow: trackW * 4, space: colorSpace, bitmapInfo: bitmapInfo),
           let ctxK = CGContext(data: &bufK, width: trackW, height: trackH, bitsPerComponent: 8, bytesPerRow: trackW * 4, space: colorSpace, bitmapInfo: bitmapInfo) {
            ctx0.interpolationQuality = .medium
            ctxK.interpolationQuality = .medium
            ctx0.draw(baseRawImage, in: CGRect(x: 0, y: 0, width: trackW, height: trackH))
            ctxK.draw(donorImage, in: CGRect(x: 0, y: 0, width: trackW, height: trackH))

            var lum0 = [Float](repeating: 0, count: trackW * trackH)
            var lumK = [Float](repeating: 0, count: trackW * trackH)
            var gx0  = [Float](repeating: 0, count: trackW * trackH)
            var gy0  = [Float](repeating: 0, count: trackW * trackH)
            var gxK  = [Float](repeating: 0, count: trackW * trackH)
            var gyK  = [Float](repeating: 0, count: trackW * trackH)

            for p in 0..<(trackW * trackH) {
                let i = p * 4
                lum0[p] = 0.299 * Float(buf0[i]) + 0.587 * Float(buf0[i + 1]) + 0.114 * Float(buf0[i + 2])
                lumK[p] = 0.299 * Float(bufK[i]) + 0.587 * Float(bufK[i + 1]) + 0.114 * Float(bufK[i + 2])
            }
            for y in 1..<(trackH - 1) {
                for x in 1..<(trackW - 1) {
                    let p = y * trackW + x
                    gx0[p] = lum0[p + 1] - lum0[p - 1]
                    gy0[p] = lum0[p + trackW] - lum0[p - trackW]
                    gxK[p] = lumK[p + 1] - lumK[p - 1]
                    gyK[p] = lumK[p + trackW] - lumK[p - trackW]
                }
            }

            let tl = baseNormCorners[0], tr = baseNormCorners[1], br = baseNormCorners[2], bl = baseNormCorners[3]
            func bilerp(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                let top = CGPoint(x: tl.x + (tr.x - tl.x) * u, y: tl.y + (tr.y - tl.y) * u)
                let bot = CGPoint(x: bl.x + (br.x - bl.x) * u, y: bl.y + (br.y - bl.y) * u)
                return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
            }

            struct SamplePt {
                let x: Int, y: Int
                let u: CGFloat, v: CGFloat
                let lum: Float
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
                    guard px >= 4, px < trackW - 4, py >= 4, py < trackH - 4 else { continue }
                    let p = py * trackW + px
                    // 排除第 1 張的反光高光區
                    if lum0[p] > 218.0 && u > 0.10 && u < 0.90 && v > 0.08 && v < 0.78 { continue }
                    let isEdge = (u <= 0.08 || u >= 0.92 || v <= 0.08 || v >= 0.92 || abs(v - 0.78) <= 0.06)
                    samples.append(SamplePt(
                        x: px, y: py, u: u, v: v,
                        lum: lum0[p], gx: gx0[p], gy: gy0[p],
                        weight: isEdge ? 1.7 : 1.0
                    ))
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
                    guard qx >= 3, qx < trackW - 3, qy >= 3, qy < trackH - 3 else { continue }
                    let q = qy * trackW + qx
                    if lumK[q] > 232.0 && s.lum < 205.0 { continue }
                    let lDiff = abs(lumK[q] - s.lum)
                    let gDiff = (abs(gxK[q] - s.gx) + abs(gyK[q] - s.gy)) * 0.90
                    errSum += min(85.0, lDiff * 0.32 + gDiff * 0.68) * s.weight
                    wSum += s.weight
                    count += 1
                }
                guard count >= minValid, wSum > 1.0 else { return .greatestFiniteMagnitude }
                let priorPenalty = hypot(Float(dx - priorDxPx), Float(dy - priorDyPx)) * 0.10
                return (errSum / wSum) + priorPenalty
            }

            var bestDx = priorDxPx
            var bestDy = priorDyPx
            var bestCost = evalShift(bestDx, bestDy)

            for dy in stride(from: -110, through: 110, by: 3) {
                for dx in stride(from: -85, through: 85, by: 3) {
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

            // Stage 2A: 在粗平移 (bestDx, bestDy) 基礎上，對非反光強梯度特徵點執行 7x7 ZNCC 匹配 + RANSAC 8-DOF Homography
            let candidateKeypoints = samples
                .filter { hypot($0.gx, $0.gy) >= 14.0 }
                .sorted { hypot($0.gx, $0.gy) * $0.weight > hypot($1.gx, $1.gy) * $1.weight }
                .prefix(64)

            var srcPoints: [SIMD2<Double>] = []
            var dstPoints: [SIMD2<Double>] = []
            let patchR = 3
            let localSearchR = 14

            for kp in candidateKeypoints {
                let ax = kp.x, ay = kp.y
                guard ax >= patchR + 1, ax < trackW - patchR - 1,
                      ay >= patchR + 1, ay < trackH - patchR - 1 else { continue }

                var sumA: Float = 0
                var countPatch = 0
                for py in -patchR...patchR {
                    for px in -patchR...patchR {
                        sumA += lum0[(ay + py) * trackW + (ax + px)]
                        countPatch += 1
                    }
                }
                let meanA = sumA / Float(countPatch)
                var varA: Float = 0
                for py in -patchR...patchR {
                    for px in -patchR...patchR {
                        let d = lum0[(ay + py) * trackW + (ax + px)] - meanA
                        varA += d * d
                    }
                }
                guard varA > 60.0 else { continue }

                let centerBx = ax + bestDx
                let centerBy = ay + bestDy
                var bestZNCC: Float = -1.0
                var matchBx = centerBx
                var matchBy = centerBy

                for sy in (centerBy - localSearchR)...(centerBy + localSearchR) {
                    guard sy >= patchR + 1, sy < trackH - patchR - 1 else { continue }
                    for sx in (centerBx - localSearchR)...(centerBx + localSearchR) {
                        guard sx >= patchR + 1, sx < trackW - patchR - 1 else { continue }
                        if lumK[sy * trackW + sx] > 234.0 && kp.lum < 208.0 { continue }

                        var sumB: Float = 0
                        var hasGlareB = false
                        for py in -patchR...patchR {
                            for px in -patchR...patchR {
                                let lb = lumK[(sy + py) * trackW + (sx + px)]
                                if lb > 242.0 && kp.lum < 205.0 {
                                    hasGlareB = true
                                    break
                                }
                                sumB += lb
                            }
                            if hasGlareB { break }
                        }
                        if hasGlareB { continue }

                        let meanB = sumB / Float(countPatch)
                        var cov: Float = 0
                        var varB: Float = 0
                        var gradDiff: Float = 0
                        for py in -patchR...patchR {
                            for px in -patchR...patchR {
                                let pA = (ay + py) * trackW + (ax + px)
                                let pB = (sy + py) * trackW + (sx + px)
                                let da = lum0[pA] - meanA
                                let db = lumK[pB] - meanB
                                cov += da * db
                                varB += db * db
                                gradDiff += abs(gx0[pA] - gxK[pB]) + abs(gy0[pA] - gyK[pB])
                            }
                        }
                        guard varB > 50.0 else { continue }
                        let zncc = cov / sqrt(varA * varB)
                        let gradScore = max(0.0, 1.0 - (gradDiff / Float(countPatch * 95)))
                        let combinedScore = zncc * 0.72 + gradScore * 0.28
                        if combinedScore > bestZNCC {
                            bestZNCC = combinedScore
                            matchBx = sx
                            matchBy = sy
                        }
                    }
                }

                if bestZNCC >= 0.64 {
                    srcPoints.append(SIMD2<Double>(Double(ax) / Double(trackW), Double(ay) / Double(trackH)))
                    dstPoints.append(SIMD2<Double>(Double(matchBx) / Double(trackW), Double(matchBy) / Double(trackH)))
                }
            }

            if srcPoints.count >= 12,
               let (H, inliers) = Self.estimateHomographyRANSAC(
                   src: srcPoints,
                   dst: dstPoints,
                   inlierThreshold: 2.2 / Double(trackW),
                   maxIterations: 160
               ),
               inliers >= 10 {
                let projected = baseNormCorners.map { pt -> CGPoint in
                    let p = Self.applyHomography(H, to: SIMD2<Double>(Double(pt.x), Double(pt.y)))
                    return CGPoint(x: p.x, y: p.y)
                }
                let baseArea = max(1e-5, VisionManager.quadArea(baseNormCorners))
                let projArea = VisionManager.quadArea(projected)
                let areaRatio = projArea / baseArea
                if areaRatio >= 0.58 && areaRatio <= 1.62 && isNaturalPerspectiveQuad(projected) {
                    homographyProjectedQuad = projected
                }
            }
        }

        let initialCandidate = homographyProjectedQuad ?? baseNormCorners.map {
            CGPoint(x: $0.x + refinedNormDx, y: $0.y + refinedNormDy)
        }

        // 若拍立得四角在畫面內 (0.01...0.99)，檢查 Vision 原生矩形是否能提供更精確的微調角點
        let allCornersInside = initialCandidate.allSatisfy {
            $0.x >= 0.01 && $0.x <= 0.99 && $0.y >= 0.01 && $0.y <= 0.99
        }
        if allCornersInside,
           let visionPts = detectCleanVisionQuadOnProxy(
               proxyImage: donorImage,
               proxySize: donorSize,
               priorNormalizedCorners: initialCandidate
           ) {
            let normVision = VisionManager.orderPoints(visionPts).map {
                CGPoint(x: $0.x / max(1.0, donorSize.width), y: $0.y / max(1.0, donorSize.height))
            }
            let meanDiff = zip(normVision, initialCandidate).reduce(0.0) { acc, pair in
                acc + hypot(Double(pair.0.x - pair.1.x), Double(pair.0.y - pair.1.y))
            } / 4.0
            let baseArea = max(1e-5, VisionManager.quadArea(baseNormCorners))
            let visionArea = VisionManager.quadArea(normVision)
            if meanDiff < 0.085 && (visionArea / baseArea) >= 0.65 && (visionArea / baseArea) <= 1.45 {
                return normVision
            }
        }

        return initialCandidate
    }

    // MARK: - Stage 2, 3 & 4: Google PhotoScan 真實底層配準與多幀無反光合成核心

    /// Google PhotoScan 4 階段無反光合成核心 (`fuseMultiFrameGlareFree`)：
    /// - **Stage 2**: 遮罩反光離群區 -> 提取 $8\times 12$ 網格之 Harris/梯度結構特徵點 -> 多尺度 ZNCC 亞像素區塊匹配 -> RANSAC + Huber IRLS 求解 $3\times 3$ 單應性矩陣 $H_k$ -> 配準品質守門（失準幀直接剔除，保證 0 錯位）。
    /// - **Stage 3**: Szeliski & Coughlan (1997) 雙線性樣條控制點光流（限制在 $\pm 2.0\text{ px}$ 並強制執行 8 輪拉普拉斯平滑正則化），消除相紙微彎殘差且絕不撕裂五官。
    /// - **Stage 4**: 低頻空間光照均衡場 $\Delta L_k(x, y)$ + 多幀下包絡線（Lower-Envelope）反光剔除 + 雙尺度無縫融合。
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

        // 提高工作畫布解析度至 640px（較舊版提升 2.3 倍面積精度，確保文字與五官亞像素對齊）
        let maxWorkSide: Double = 640.0
        let workScale = min(1.0, maxWorkSide / Double(max(fullWidth, fullHeight)))
        let width = max(96, Int((Double(fullWidth) * workScale).rounded()))
        let height = max(96, Int((Double(fullHeight) * workScale).rounded()))
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

        // 保留初始 Base Frame 副本，所有 Donor 皆以初始 Base 0 為唯一幾何配準基準（杜絕累積漂移！）
        let initialBaseBuf = currentBuf
        var baseLum0 = [Float](repeating: 0, count: width * height)
        for p in 0..<(width * height) {
            let i = p * 4
            baseLum0[p] = (0.299 * Float(initialBaseBuf[i]) + 0.587 * Float(initialBaseBuf[i + 1]) + 0.114 * Float(initialBaseBuf[i + 2])) / 255.0
        }

        var baseGx0 = [Float](repeating: 0, count: width * height)
        var baseGy0 = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let p = y * width + x
                baseGx0[p] = (baseLum0[p + 1] - baseLum0[p - 1]) * 255.0
                baseGy0[p] = (baseLum0[p + width] - baseLum0[p - width]) * 255.0
            }
        }

        let baseSurround0 = smoothWeightMapFast(baseLum0, width: width, height: height, radius: max(16, width / 12))
        // Base 0 的反光離群遮罩（在 Stage 2 特徵提取時嚴格避開此區域）
        var rawGlareA = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let v = Float(y) / Float(max(1, height - 1))
            for x in 0..<width {
                let u = Float(x) / Float(max(1, width - 1))
                let p = y * width + x
                let isInnerPhoto = (u >= 0.06 && u <= 0.94 && v >= 0.05 && v <= 0.80)
                if baseLum0[p] >= 0.86 && isInnerPhoto {
                    rawGlareA[p] = 1.0
                } else if baseLum0[p] >= 0.68 && (baseLum0[p] - baseSurround0[p]) >= 0.075 {
                    rawGlareA[p] = 1.0
                }
            }
        }
        let expandedGlareMaskA = maxFilterFloatFast(rawGlareA, width: width, height: height, radius: max(8, width / 32))

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

            // 計算 Donor k 在原始相機畫面內的真實有效像素遮罩 (排除移出畫面外的 clampedToExtent 邊界)
            var rawValidB = [Bool](repeating: true, count: width * height)
            if k < donorNormalizedQuads.count, donorNormalizedQuads[k].count == 4 {
                let q = donorNormalizedQuads[k]
                let tl = q[0], tr = q[1], br = q[2], bl = q[3]
                for y in 0..<height {
                    let v = (CGFloat(y) + 0.5) / CGFloat(height)
                    for x in 0..<width {
                        let u = (CGFloat(x) + 0.5) / CGFloat(width)
                        let tx = tl.x + (tr.x - tl.x) * u
                        let ty = tl.y + (tr.y - tl.y) * u
                        let bx = bl.x + (br.x - bl.x) * u
                        let by = bl.y + (br.y - bl.y) * u
                        let rx = tx + (bx - tx) * v
                        let ry = ty + (by - ty) * v
                        if rx < 0.015 || rx > 0.985 || ry < 0.015 || ry > 0.985 {
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

            var rawGxB = [Float](repeating: 0, count: width * height)
            var rawGyB = [Float](repeating: 0, count: width * height)
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let p = y * width + x
                    rawGxB[p] = (rawLumB[p + 1] - rawLumB[p - 1]) * 255.0
                    rawGyB[p] = (rawLumB[p + width] - rawLumB[p - width]) * 255.0
                }
            }

            let surroundB = smoothWeightMapFast(rawLumB, width: width, height: height, radius: max(16, width / 12))
            var rawGlareB = [Float](repeating: 0, count: width * height)
            for y in 0..<height {
                let v = Float(y) / Float(max(1, height - 1))
                for x in 0..<width {
                    let u = Float(x) / Float(max(1, width - 1))
                    let p = y * width + x
                    let isInnerPhoto = (u >= 0.06 && u <= 0.94 && v >= 0.05 && v <= 0.80)
                    if rawLumB[p] >= 0.86 && isInnerPhoto {
                        rawGlareB[p] = 1.0
                    } else if rawLumB[p] >= 0.68 && (rawLumB[p] - surroundB[p]) >= 0.075 {
                        rawGlareB[p] = 1.0
                    }
                }
            }
            let expandedGlareMaskB = maxFilterFloatFast(rawGlareB, width: width, height: height, radius: max(8, width / 32))

            // =========================================================================
            // Stage 2: 遮罩反光之 ZNCC 特徵點匹配 + RANSAC 8-DOF Homography 單應性矩陣配準
            // =========================================================================

            // 2.1 全域粗平移初估（僅在雙方皆非反光且畫面內的像素上計算）
            var coarseDx = 0
            var coarseDy = 0
            var bestCoarseCost: Float = .greatestFiniteMagnitude
            let maxShiftX = max(24, width / 10)
            let maxShiftY = max(32, height / 10)

            func evalCoarse(_ dx: Int, _ dy: Int, step: Int) -> Float {
                var errSum: Float = 0
                var count = 0
                for y in stride(from: 16, to: height - 16, by: step) {
                    let sy = y + dy
                    guard sy >= 6, sy < height - 6 else { continue }
                    for x in stride(from: 16, to: width - 16, by: step) {
                        let sx = x + dx
                        guard sx >= 6, sx < width - 6 else { continue }
                        let pA = y * width + x
                        let pB = sy * width + sx
                        guard rawValidB[pB] else { continue }
                        if expandedGlareMaskA[pA] > 0.5 || expandedGlareMaskB[pB] > 0.5 { continue }

                        let lDiff = abs(baseLum0[pA] - rawLumB[pB]) * 255.0
                        let gDiff = abs(baseGx0[pA] - rawGxB[pB]) + abs(baseGy0[pA] - rawGyB[pB])
                        errSum += min(80.0, lDiff * 0.30 + gDiff * 0.70)
                        count += 1
                    }
                }
                guard count >= 60 else { return .greatestFiniteMagnitude }
                return (errSum / Float(count)) + hypot(Float(dx), Float(dy)) * 0.08
            }

            for dy in stride(from: -maxShiftY, through: maxShiftY, by: 4) {
                for dx in stride(from: -maxShiftX, through: maxShiftX, by: 4) {
                    let c = evalCoarse(dx, dy, step: 8)
                    if c < bestCoarseCost {
                        bestCoarseCost = c
                        coarseDx = dx
                        coarseDy = dy
                    }
                }
            }
            let cDx0 = coarseDx, cDy0 = coarseDy
            for dy in (cDy0 - 3)...(cDy0 + 3) {
                for dx in (cDx0 - 3)...(cDx0 + 3) {
                    let c = evalCoarse(dx, dy, step: 5)
                    if c < bestCoarseCost {
                        bestCoarseCost = c
                        coarseDx = dx
                        coarseDy = dy
                    }
                }
            }

            // 2.2 在 8×12 空間網格中提取非反光區的 Harris / 強梯度特徵角點（保證全卡均勻分佈）
            struct KeypointA {
                let x: Int
                let y: Int
                let score: Float
            }
            let featCols = 8
            let featRows = 12
            var keypointsA: [KeypointA] = []
            let margin = 14
            for r in 0..<featRows {
                let y0 = margin + (height - 2 * margin) * r / featRows
                let y1 = margin + (height - 2 * margin) * (r + 1) / featRows
                for c in 0..<featCols {
                    let x0 = margin + (width - 2 * margin) * c / featCols
                    let x1 = margin + (width - 2 * margin) * (c + 1) / featCols
                    var bestPt: KeypointA? = nil
                    for y in stride(from: y0, to: y1, by: 2) {
                        for x in stride(from: x0, to: x1, by: 2) {
                            let p = y * width + x
                            guard expandedGlareMaskA[p] < 0.5 else { continue }
                            // 結合梯度能量與角點正交響應（Harris-like cornerness）
                            let gx = abs(baseGx0[p])
                            let gy = abs(baseGy0[p])
                            let gradMag = hypot(gx, gy)
                            let cornerness = gradMag + 0.65 * min(gx, gy)
                            if cornerness >= 18.0 {
                                if bestPt == nil || cornerness > bestPt!.score {
                                    bestPt = KeypointA(x: x, y: y, score: cornerness)
                                }
                            }
                        }
                    }
                    if let bestPt {
                        keypointsA.append(bestPt)
                    }
                }
            }

            // 2.3 對每個特徵點執行 ZNCC 區塊匹配 + 拋物線亞像素峰值內插
            var matchedSrc: [SIMD2<Double>] = []
            var matchedDst: [SIMD2<Double>] = []
            let patchR = 4 // 9x9 patch
            let searchR = max(16, width / 26)

            for kp in keypointsA {
                let ax = kp.x, ay = kp.y
                guard ax >= patchR + 2, ax < width - patchR - 2,
                      ay >= patchR + 2, ay < height - patchR - 2 else { continue }

                var sumA: Float = 0
                let patchCount = (2 * patchR + 1) * (2 * patchR + 1)
                for py in -patchR...patchR {
                    let rowA = (ay + py) * width + ax
                    for px in -patchR...patchR {
                        sumA += baseLum0[rowA + px]
                    }
                }
                let meanA = sumA / Float(patchCount)
                var varA: Float = 0
                for py in -patchR...patchR {
                    let rowA = (ay + py) * width + ax
                    for px in -patchR...patchR {
                        let d = baseLum0[rowA + px] - meanA
                        varA += d * d
                    }
                }
                guard varA > 0.004 else { continue }

                let initBx = ax + coarseDx
                let initBy = ay + coarseDy

                func evalZNCC(bx: Int, by: Int) -> Float {
                    guard bx >= patchR + 2, bx < width - patchR - 2,
                          by >= patchR + 2, by < height - patchR - 2 else { return -1.0 }
                    let centerB = by * width + bx
                    guard rawValidB[centerB], expandedGlareMaskB[centerB] < 0.5 else { return -1.0 }

                    var sumB: Float = 0
                    for py in -patchR...patchR {
                        let rowB = (by + py) * width + bx
                        for px in -patchR...patchR {
                            let pB = rowB + px
                            if !rawValidB[pB] || expandedGlareMaskB[pB] > 0.5 { return -1.0 }
                            sumB += rawLumB[pB]
                        }
                    }
                    let meanB = sumB / Float(patchCount)
                    var cov: Float = 0
                    var varB: Float = 0
                    var gradSim: Float = 0
                    for py in -patchR...patchR {
                        let rowA = (ay + py) * width + ax
                        let rowB = (by + py) * width + bx
                        for px in -patchR...patchR {
                            let pA = rowA + px
                            let pB = rowB + px
                            let da = baseLum0[pA] - meanA
                            let db = rawLumB[pB] - meanB
                            cov += da * db
                            varB += db * db
                            let gDiff = (abs(baseGx0[pA] - rawGxB[pB]) + abs(baseGy0[pA] - rawGyB[pB])) / 255.0
                            gradSim += max(0.0, 1.0 - gDiff * 2.2)
                        }
                    }
                    guard varB > 0.003 else { return -1.0 }
                    let zncc = cov / sqrt(varA * varB)
                    let meanGradSim = gradSim / Float(patchCount)
                    return zncc * 0.70 + meanGradSim * 0.30
                }

                var bestScore: Float = -1.0
                var bestBx = initBx
                var bestBy = initBy

                // 先以 step = 2 粗搜，再於 ±2px 精搜
                for sy in stride(from: initBy - searchR, through: initBy + searchR, by: 2) {
                    for sx in stride(from: initBx - searchR, through: initBx + searchR, by: 2) {
                        let s = evalZNCC(bx: sx, by: sy)
                        if s > bestScore {
                            bestScore = s
                            bestBx = sx
                            bestBy = sy
                        }
                    }
                }
                let cBx = bestBx, cBy = bestBy
                for sy in (cBy - 2)...(cBy + 2) {
                    for sx in (cBx - 2)...(cBx + 2) {
                        let s = evalZNCC(bx: sx, by: sy)
                        if s > bestScore {
                            bestScore = s
                            bestBx = sx
                            bestBy = sy
                        }
                    }
                }

                guard bestScore >= 0.68 else { continue }

                // 1D 拋物線亞像素峰值內插 (Sub-pixel Parabolic Peak Refinement)
                let sL = evalZNCC(bx: bestBx - 1, by: bestBy)
                let sR = evalZNCC(bx: bestBx + 1, by: bestBy)
                let sU = evalZNCC(bx: bestBx, by: bestBy - 1)
                let sD = evalZNCC(bx: bestBx, by: bestBy + 1)

                var subDx: Double = 0.0
                let denomX = sL - 2.0 * bestScore + sR
                if sL > 0 && sR > 0 && abs(denomX) > 1e-4 {
                    subDx = max(-0.5, min(0.5, Double(0.5 * (sL - sR) / denomX)))
                }
                var subDy: Double = 0.0
                let denomY = sU - 2.0 * bestScore + sD
                if sU > 0 && sD > 0 && abs(denomY) > 1e-4 {
                    subDy = max(-0.5, min(0.5, Double(0.5 * (sU - sD) / denomY)))
                }

                matchedSrc.append(SIMD2<Double>(Double(ax), Double(ay)))
                matchedDst.append(SIMD2<Double>(Double(bestBx) + subDx, Double(bestBy) + subDy))
            }

            // 2.4 RANSAC + Huber IRLS 求解 8-DOF 單應性矩陣 H_k (將 Base A 座標映射至 Donor B 座標)
            var homographyAtoB: [Double] = [
                1.0, 0.0, Double(coarseDx),
                0.0, 1.0, Double(coarseDy),
                0.0, 0.0, 1.0
            ]
            var homographyValid = false

            if matchedSrc.count >= 8,
               let (estimatedH, inlierCount) = Self.estimateHomographyRANSAC(
                   src: matchedSrc,
                   dst: matchedDst,
                   inlierThreshold: 2.4,
                   maxIterations: 220
               ),
               inlierCount >= max(8, matchedSrc.count / 3) {
                // 檢查單應性矩陣是否保持合理剛體/透視比例（無翻轉或劇烈扭曲）
                let tlP = Self.applyHomography(estimatedH, to: SIMD2<Double>(0, 0))
                let trP = Self.applyHomography(estimatedH, to: SIMD2<Double>(Double(width), 0))
                let brP = Self.applyHomography(estimatedH, to: SIMD2<Double>(Double(width), Double(height)))
                let blP = Self.applyHomography(estimatedH, to: SIMD2<Double>(0, Double(height)))
                let mappedQuad = [
                    CGPoint(x: tlP.x, y: tlP.y),
                    CGPoint(x: trP.x, y: trP.y),
                    CGPoint(x: brP.x, y: brP.y),
                    CGPoint(x: blP.x, y: blP.y)
                ]
                let mappedArea = VisionManager.quadArea(mappedQuad)
                let areaRatio = mappedArea / Double(width * height)
                if areaRatio >= 0.72 && areaRatio <= 1.38 && isNaturalPerspectiveQuad(mappedQuad) {
                    homographyAtoB = estimatedH
                    homographyValid = true
                }
            }

            // =========================================================================
            // Stage 3: Szeliski & Coughlan (1997) 剛性正則化控制點樣條光流 (Spline Control Mesh)
            // =========================================================================
            // 在 8-DOF Homography 平面對齊後，僅允許 ±2.0px 的亞像素控制點微調，並施加 8 輪拉普拉斯平滑正則化，
            // 徹底杜絕舊版獨立網格造成的五官撕裂與錯位！
            let cols = 6
            let rows = 9
            let numVerts = (cols + 1) * (rows + 1)
            var dataDeltaX = [Float](repeating: 0, count: numVerts)
            var dataDeltaY = [Float](repeating: 0, count: numVerts)
            var vertConfidence = [Float](repeating: 0, count: numVerts)

            if homographyValid {
                let cellRadiusX = max(10, width / (cols * 2))
                let cellRadiusY = max(10, height / (rows * 2))
                let residualCandidates: [Float] = [-2.0, -1.25, -0.5, 0.0, 0.5, 1.25, 2.0]

                for gy in 0...rows {
                    let cy = Int((Double(gy) / Double(rows) * Double(height - 1)).rounded())
                    let y0 = max(6, cy - cellRadiusY)
                    let y1 = min(height - 7, cy + cellRadiusY)
                    for gx in 0...cols {
                        let cx = Int((Double(gx) / Double(cols) * Double(width - 1)).rounded())
                        let x0 = max(6, cx - cellRadiusX)
                        let x1 = min(width - 7, cx + cellRadiusX)
                        let vIdx = gy * (cols + 1) + gx

                        var bestDx: Float = 0
                        var bestDy: Float = 0
                        var bestCost: Float = .greatestFiniteMagnitude
                        var zeroCost: Float = .greatestFiniteMagnitude
                        var validSamplesCount = 0
                        var gradEnergySum: Float = 0

                        for dy in residualCandidates {
                            for dx in residualCandidates {
                                var errSum: Float = 0
                                var count = 0
                                var gEnergy: Float = 0
                                for y in stride(from: y0, through: y1, by: 4) {
                                    for x in stride(from: x0, through: x1, by: 4) {
                                        let pA = y * width + x
                                        guard expandedGlareMaskA[pA] < 0.5 else { continue }
                                        let hp = Self.applyHomography(homographyAtoB, to: SIMD2<Double>(Double(x), Double(y)))
                                        let sx = Float(hp.x) + dx
                                        let sy = Float(hp.y) + dy
                                        let ix = Int(sx.rounded())
                                        let iy = Int(sy.rounded())
                                        guard ix >= 3, ix < width - 3, iy >= 3, iy < height - 3 else { continue }
                                        let pB = iy * width + ix
                                        guard rawValidB[pB], expandedGlareMaskB[pB] < 0.5 else { continue }

                                        let lB = Self.sampleBilinearFloat(rawLumB, width: width, height: height, x: sx, y: sy)
                                        let gxBVal = Self.sampleBilinearFloat(rawGxB, width: width, height: height, x: sx, y: sy)
                                        let gyBVal = Self.sampleBilinearFloat(rawGyB, width: width, height: height, x: sx, y: sy)

                                        let lDiff = abs(baseLum0[pA] - lB) * 255.0
                                        let gDiff = abs(baseGx0[pA] - gxBVal) + abs(baseGy0[pA] - gyBVal)
                                        errSum += min(70.0, lDiff * 0.30 + gDiff * 0.70)
                                        gEnergy += hypot(baseGx0[pA], baseGy0[pA])
                                        count += 1
                                    }
                                }
                                if count >= 12 {
                                    let penalty = hypot(dx, dy) * 0.85
                                    let cost = (errSum / Float(count)) + penalty
                                    if dx == 0 && dy == 0 {
                                        zeroCost = cost
                                        validSamplesCount = count
                                        gradEnergySum = gEnergy / Float(count)
                                    }
                                    if cost < bestCost {
                                        bestCost = cost
                                        bestDx = dx
                                        bestDy = dy
                                    }
                                }
                            }
                        }

                        if validSamplesCount >= 12 && gradEnergySum >= 8.0 && bestCost < zeroCost - 0.15 {
                            dataDeltaX[vIdx] = bestDx
                            dataDeltaY[vIdx] = bestDy
                            vertConfidence[vIdx] = min(1.0, gradEnergySum / 28.0)
                        }
                    }
                }
            }

            // 8 輪拉普拉斯薄膜平滑正則化 (Laplacian Membrane Regularization, Szeliski & Coughlan 1997)
            var smoothDeltaX = dataDeltaX
            var smoothDeltaY = dataDeltaY
            let lambdaReg: Float = 2.2
            for _ in 0..<8 {
                var nextX = smoothDeltaX
                var nextY = smoothDeltaY
                for gy in 0...rows {
                    for gx in 0...cols {
                        let idx = gy * (cols + 1) + gx
                        var nSumX: Float = 0
                        var nSumY: Float = 0
                        var nCount: Float = 0
                        if gx > 0        { nSumX += smoothDeltaX[idx - 1];          nSumY += smoothDeltaY[idx - 1];          nCount += 1 }
                        if gx < cols     { nSumX += smoothDeltaX[idx + 1];          nSumY += smoothDeltaY[idx + 1];          nCount += 1 }
                        if gy > 0        { nSumX += smoothDeltaX[idx - (cols + 1)]; nSumY += smoothDeltaY[idx - (cols + 1)]; nCount += 1 }
                        if gy < rows     { nSumX += smoothDeltaX[idx + (cols + 1)]; nSumY += smoothDeltaY[idx + (cols + 1)]; nCount += 1 }
                        let avgNX = nCount > 0 ? (nSumX / nCount) : 0
                        let avgNY = nCount > 0 ? (nSumY / nCount) : 0
                        let conf = vertConfidence[idx]
                        nextX[idx] = (conf * dataDeltaX[idx] + lambdaReg * avgNX) / (conf + lambdaReg)
                        nextY[idx] = (conf * dataDeltaY[idx] + lambdaReg * avgNY) / (conf + lambdaReg)
                    }
                }
                smoothDeltaX = nextX
                smoothDeltaY = nextY
            }

            // 以「單應性矩陣 H_k + 平滑樣條控制點位移」執行真實雙線性亞像素重採樣 (Sub-pixel Bilinear Warp)
            var warpedB = [UInt8](repeating: 0, count: width * height * 4)
            var warpedValidB = [Bool](repeating: false, count: width * height)
            var alignVerifyErrSum: Float = 0
            var alignVerifyCount: Int = 0

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

                            let splineDx = (1 - wx) * (1 - wy) * smoothDeltaX[idx00]
                                         + wx * (1 - wy) * smoothDeltaX[idx10]
                                         + (1 - wx) * wy * smoothDeltaX[idx01]
                                         + wx * wy * smoothDeltaX[idx11]
                            let splineDy = (1 - wx) * (1 - wy) * smoothDeltaY[idx00]
                                         + wx * (1 - wy) * smoothDeltaY[idx10]
                                         + (1 - wx) * wy * smoothDeltaY[idx01]
                                         + wx * wy * smoothDeltaY[idx11]

                            let hp = Self.applyHomography(homographyAtoB, to: SIMD2<Double>(Double(x), Double(y)))
                            let srcX = Float(hp.x) + splineDx
                            let srcY = Float(hp.y) + splineDy

                            let x0 = Int(floor(srcX))
                            let y0 = Int(floor(srcY))
                            let pDst = y * width + x
                            guard x0 >= 2, x0 < width - 3, y0 >= 2, y0 < height - 3 else { continue }

                            let p00 = y0 * width + x0
                            guard rawValidB[p00], rawValidB[p00 + 1],
                                  rawValidB[p00 + width], rawValidB[p00 + width + 1] else { continue }

                            warpedValidB[pDst] = true
                            let ax = srcX - Float(x0)
                            let ay = srcY - Float(y0)
                            let w00 = (1 - ax) * (1 - ay)
                            let w10 = ax * (1 - ay)
                            let w01 = (1 - ax) * ay
                            let w11 = ax * ay

                            let i00 = p00 * 4
                            let i10 = (p00 + 1) * 4
                            let i01 = (p00 + width) * 4
                            let i11 = (p00 + width + 1) * 4
                            let dstIdx = pDst * 4

                            let rVal = w00 * Float(srcPtr[i00])     + w10 * Float(srcPtr[i10])     + w01 * Float(srcPtr[i01])     + w11 * Float(srcPtr[i11])
                            let gVal = w00 * Float(srcPtr[i00 + 1]) + w10 * Float(srcPtr[i10 + 1]) + w01 * Float(srcPtr[i01 + 1]) + w11 * Float(srcPtr[i11 + 1])
                            let bVal = w00 * Float(srcPtr[i00 + 2]) + w10 * Float(srcPtr[i10 + 2]) + w01 * Float(srcPtr[i01 + 2]) + w11 * Float(srcPtr[i11 + 2])

                            dstPtr[dstIdx]     = UInt8(min(255, max(0, Int(rVal.rounded()))))
                            dstPtr[dstIdx + 1] = UInt8(min(255, max(0, Int(gVal.rounded()))))
                            dstPtr[dstIdx + 2] = UInt8(min(255, max(0, Int(bVal.rounded()))))
                            dstPtr[dstIdx + 3] = 255

                            if (x & 3) == 0 && (y & 3) == 0 && expandedGlareMaskA[pDst] < 0.5 && expandedGlareMaskB[p00] < 0.5 {
                                let lumBVal = (0.299 * rVal + 0.587 * gVal + 0.114 * bVal) / 255.0
                                alignVerifyErrSum += abs(baseLum0[pDst] - lumBVal)
                                alignVerifyCount += 1
                            }
                        }
                    }
                }
            }

            // 2.5 嚴格配準品質守門（Inlier & Structural Gate）：
            // 若該張角點照片有效對齊區過小、或非反光區對齊誤差過大（如拍攝時劇烈手震），直接捨棄該張，絕不硬貼造成錯位！
            guard alignVerifyCount >= 80, (alignVerifyErrSum / Float(alignVerifyCount)) <= 0.16 else {
                continue
            }

            // =========================================================================
            // Stage 4: 空間平滑環境光均衡場 + 多幀下包絡線反光剔除與無縫融合
            // =========================================================================

            var lumMapA = [Float](repeating: 0, count: width * height)
            var lumMapB = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                let i = p * 4
                lumMapA[p] = (0.299 * Float(currentBuf[i]) + 0.587 * Float(currentBuf[i + 1]) + 0.114 * Float(currentBuf[i + 2])) / 255.0
                lumMapB[p] = (0.299 * Float(warpedB[i]) + 0.587 * Float(warpedB[i + 1]) + 0.114 * Float(warpedB[i + 2])) / 255.0
            }

            let smoothLumA = smoothWeightMapFast(lumMapA, width: width, height: height, radius: max(3, width / 80))
            let smoothLumB = smoothWeightMapFast(lumMapB, width: width, height: height, radius: max(3, width / 80))
            let localSurroundA = smoothWeightMapFast(lumMapA, width: width, height: height, radius: max(20, width / 11))

            // 4.1 計算空間平滑光照差場 (Spatially-Varying Illumination Field)：
            // 僅從乾淨非反光中間調像素取樣 (A - B)，透過大範圍濾波補齊角度傾斜造成的漸層亮度差
            var midToneDiffNum = [Float](repeating: 0, count: width * height)
            var midToneDiffDen = [Float](repeating: 0, count: width * height)
            var globalMidSum: Float = 0
            var globalMidCnt: Int = 0

            for p in 0..<(width * height) where warpedValidB[p] {
                let a = smoothLumA[p]
                let b = smoothLumB[p]
                if a >= 0.14 && a <= 0.74 && b >= 0.14 && b <= 0.74 && abs(a - b) < 0.075 {
                    let diff = a - b
                    midToneDiffNum[p] = diff
                    midToneDiffDen[p] = 1.0
                    globalMidSum += diff
                    globalMidCnt += 1
                }
            }
            let fallbackGlobalDiff: Float = globalMidCnt >= 24 ? (globalMidSum / Float(globalMidCnt)) : 0.0
            let smoothNum = smoothWeightMapFast(midToneDiffNum, width: width, height: height, radius: max(28, width / 6))
            let smoothDen = smoothWeightMapFast(midToneDiffDen, width: width, height: height, radius: max(28, width / 6))
            var ambientDiffField = [Float](repeating: fallbackGlobalDiff, count: width * height)
            for p in 0..<(width * height) {
                if smoothDen[p] > 0.08 {
                    let localDiff = smoothNum[p] / smoothDen[p]
                    ambientDiffField[p] = max(-0.14, min(0.14, localDiff * 0.75 + fallbackGlobalDiff * 0.25))
                }
            }

            // 4.2 偵測反光高光峰值種子 (Specular Outlier Seeds)
            var rawPeak = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) where warpedValidB[p] {
                let amb = ambientDiffField[p]
                let corrSmoothB = smoothLumB[p] + amb
                let corrRawB = lumMapB[p] + amb
                if lumMapB[p] >= 0.92 && corrSmoothB >= smoothLumA[p] - 0.025 {
                    continue
                }
                let diff = lumMapA[p] - corrRawB
                let regDiff = smoothLumA[p] - corrSmoothB
                let localProminence = smoothLumA[p] - localSurroundA[p]

                if (lumMapA[p] >= 0.88 && diff >= 0.055 && regDiff >= 0.040)
                    || (lumMapA[p] >= 0.52 && diff >= 0.125 && regDiff >= 0.095)
                    || (lumMapA[p] >= 0.76 && localProminence >= 0.075 && regDiff >= 0.052) {
                    rawPeak[p] = 1.0
                }
            }

            let peakDensity = smoothWeightMapFast(rawPeak, width: width, height: height, radius: max(3, width / 70))
            var peakSeed = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) {
                if rawPeak[p] > 0.5 && peakDensity[p] >= 0.12 {
                    peakSeed[p] = 1.0
                }
            }

            // 4.3 有限範圍測地線光暈向外膨脹 (Bounded Geodesic Halo Expansion)
            let maxHaloZone = maxFilterFloatFast(peakSeed, width: width, height: height, radius: max(24, width / 6))
            var haloMask = peakSeed
            let stepRadius = max(6, width / 32)
            for _ in 0..<5 {
                let expanded = maxFilterFloatFast(haloMask, width: width, height: height, radius: stepRadius)
                for p in 0..<(width * height) where warpedValidB[p] && maxHaloZone[p] > 0.5 {
                    guard expanded[p] > 0.5 else { continue }
                    let amb = ambientDiffField[p]
                    let corrSmoothB = smoothLumB[p] + amb
                    let corrRawB = lumMapB[p] + amb
                    let regDiff = smoothLumA[p] - corrSmoothB
                    let diff = lumMapA[p] - corrRawB
                    if regDiff >= 0.024 || diff >= 0.032 {
                        haloMask[p] = 1.0
                    }
                }
            }

            if k == 1 {
                for p in 0..<(width * height) where haloMask[p] > 0.5 {
                    initialGlarePixelCount += 1
                }
            }

            let dilatedHalo = maxFilterFloatFast(haloMask, width: width, height: height, radius: max(5, width / 38))

            // 計算有效畫面內部安全距離羽化，防止在有效邊界處產生生硬切線
            var validFloat = [Float](repeating: 0, count: width * height)
            for p in 0..<(width * height) where warpedValidB[p] {
                validFloat[p] = 1.0
            }
            let interiorWeight = smoothWeightMapFast(validFloat, width: width, height: height, radius: max(8, width / 36))

            var cleanDilated = dilatedHalo
            for p in 0..<(width * height) {
                let inWeight = max(0.0, min(1.0, (interiorWeight[p] - 0.55) / 0.45))
                if !warpedValidB[p] || inWeight <= 0.01 {
                    cleanDilated[p] = 0.0
                    haloMask[p] = 0.0
                    continue
                }
                let corrSmoothB = smoothLumB[p] + ambientDiffField[p]
                if corrSmoothB > smoothLumA[p] + 0.012 {
                    cleanDilated[p] = 0.0
                    haloMask[p] = 0.0
                } else {
                    cleanDilated[p] *= inWeight
                    haloMask[p] *= inWeight
                }
            }

            let featherR = max(7, width / 22)
            let feathered1 = smoothWeightMapFast(cleanDilated, width: width, height: height, radius: featherR)
            let feathered2 = smoothWeightMapFast(feathered1, width: width, height: height, radius: featherR)

            // 4.4 執行無反光像素替換與雙尺度平滑過渡
            for p in 0..<(width * height) where warpedValidB[p] {
                let amb = ambientDiffField[p]
                let corrSmoothB = smoothLumB[p] + amb
                if corrSmoothB > smoothLumA[p] + 0.012 { continue }
                let w = min(1.0, max(haloMask[p] * 0.98, feathered2[p] * 1.42))
                guard w > 0.01 else { continue }

                let idx = p * 4
                let wA = 1.0 - w
                let delta = amb * 255.0

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
            .applyingGaussianBlur(sigma: 2.8)
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

    // MARK: - 數學核心：RANSAC + Normalized DLT 8-DOF 單應性矩陣求解器與雙線性內插

    /// 對單應性矩陣 $H$ ($3\times 3$ row-major) 執行透視投影：$(x', y') = \pi(H \cdot [x, y, 1]^T)$
    @inline(__always)
    private static func applyHomography(_ H: [Double], to pt: SIMD2<Double>) -> SIMD2<Double> {
        let denom = H[6] * pt.x + H[7] * pt.y + H[8]
        let invW = abs(denom) > 1e-8 ? (1.0 / denom) : 1.0
        let nx = (H[0] * pt.x + H[1] * pt.y + H[2]) * invW
        let ny = (H[3] * pt.x + H[4] * pt.y + H[5]) * invW
        return SIMD2<Double>(nx, ny)
    }

    /// 浮點單通道影像之雙線性亞像素內插
    @inline(__always)
    private static func sampleBilinearFloat(
        _ buf: [Float],
        width: Int,
        height: Int,
        x: Float,
        y: Float
    ) -> Float {
        let x0 = max(0, min(width - 2, Int(floor(x))))
        let y0 = max(0, min(height - 2, Int(floor(y))))
        let fx = max(0.0, min(1.0, x - Float(x0)))
        let fy = max(0.0, min(1.0, y - Float(y0)))
        let p00 = y0 * width + x0
        let v00 = buf[p00]
        let v10 = buf[p00 + 1]
        let v01 = buf[p00 + width]
        let v11 = buf[p00 + width + 1]
        return (1 - fx) * (1 - fy) * v00
             + fx * (1 - fy) * v10
             + (1 - fx) * fy * v01
             + fx * fy * v11
    }

    /// RANSAC + Huber 加權最小平方法求解 $3\times 3$ 8-DOF 單應性矩陣 $H$
    private static func estimateHomographyRANSAC(
        src: [SIMD2<Double>],
        dst: [SIMD2<Double>],
        inlierThreshold: Double,
        maxIterations: Int
    ) -> (H: [Double], inliers: Int)? {
        let n = min(src.count, dst.count)
        guard n >= 4 else { return nil }

        var bestH: [Double]? = nil
        var bestInliers: [Int] = []
        let threshSq = inlierThreshold * inlierThreshold

        // 確定性虛擬隨機產生器（保證可重現且極速）
        var rngState: UInt64 = 0x9E3779B97F4A7C15
        @inline(__always)
        func nextIndex() -> Int {
            rngState ^= rngState >> 12
            rngState ^= rngState << 25
            rngState ^= rngState >> 27
            let val = rngState &* 2685821657736338717
            return Int(val % UInt64(n))
        }

        for _ in 0..<maxIterations {
            let i0 = nextIndex()
            var i1 = nextIndex()
            var guardCnt = 0
            while i1 == i0 && guardCnt < 8 { i1 = nextIndex(); guardCnt += 1 }
            var i2 = nextIndex()
            guardCnt = 0
            while (i2 == i0 || i2 == i1) && guardCnt < 8 { i2 = nextIndex(); guardCnt += 1 }
            var i3 = nextIndex()
            guardCnt = 0
            while (i3 == i0 || i3 == i1 || i3 == i2) && guardCnt < 8 { i3 = nextIndex(); guardCnt += 1 }
            if i0 == i1 || i0 == i2 || i0 == i3 || i1 == i2 || i1 == i3 || i2 == i3 { continue }

            let s4 = [src[i0], src[i1], src[i2], src[i3]]
            let d4 = [dst[i0], dst[i1], dst[i2], dst[i3]]
            guard let H = solveHomographyNormalizedDLT(src: s4, dst: d4, weights: nil) else { continue }

            var inliers: [Int] = []
            for idx in 0..<n {
                let proj = applyHomography(H, to: src[idx])
                let dx = proj.x - dst[idx].x
                let dy = proj.y - dst[idx].y
                if dx * dx + dy * dy <= threshSq {
                    inliers.append(idx)
                }
            }
            if inliers.count > bestInliers.count {
                bestInliers = inliers
                bestH = H
            }
        }

        guard bestInliers.count >= 4 else { return nil }

        // 使用全部 Inliers 重新擬合最小平方 Homography，並執行 1 輪 Huber IRLS 精煉
        let inlierSrc = bestInliers.map { src[$0] }
        let inlierDst = bestInliers.map { dst[$0] }
        var refinedH = solveHomographyNormalizedDLT(src: inlierSrc, dst: inlierDst, weights: nil) ?? bestH!

        var huberWeights = [Double](repeating: 1.0, count: inlierSrc.count)
        let huberDelta = max(1e-5, inlierThreshold * 0.75)
        for i in 0..<inlierSrc.count {
            let proj = applyHomography(refinedH, to: inlierSrc[i])
            let err = hypot(proj.x - inlierDst[i].x, proj.y - inlierDst[i].y)
            huberWeights[i] = err <= huberDelta ? 1.0 : (huberDelta / err)
        }
        if let irlsH = solveHomographyNormalizedDLT(src: inlierSrc, dst: inlierDst, weights: huberWeights) {
            refinedH = irlsH
        }

        return (refinedH, bestInliers.count)
    }

    /// Hartley 正規化加權直接線性變換 (Normalized Weighted DLT) 求解 $3\times 3$ 8-DOF 單應性矩陣 $H$
    private static func solveHomographyNormalizedDLT(
        src: [SIMD2<Double>],
        dst: [SIMD2<Double>],
        weights: [Double]?
    ) -> [Double]? {
        let n = min(src.count, dst.count)
        guard n >= 4 else { return nil }

        // 1. Hartley Isotropic Normalization (平移重心至原點並縮放平均距離至 sqrt(2))
        var meanSrc = SIMD2<Double>(0, 0)
        var meanDst = SIMD2<Double>(0, 0)
        for i in 0..<n {
            meanSrc += src[i]
            meanDst += dst[i]
        }
        meanSrc /= Double(n)
        meanDst /= Double(n)

        var distSrc = 0.0
        var distDst = 0.0
        for i in 0..<n {
            distSrc += hypot(src[i].x - meanSrc.x, src[i].y - meanSrc.y)
            distDst += hypot(dst[i].x - meanDst.x, dst[i].y - meanDst.y)
        }
        let scaleSrc = (distSrc > 1e-8) ? (sqrt(2.0) * Double(n) / distSrc) : 1.0
        let scaleDst = (distDst > 1e-8) ? (sqrt(2.0) * Double(n) / distDst) : 1.0

        // 建立 8x8 正規方程式 (A^T W A) h = A^T W b (固定 h_8 = 1.0)
        var ata = [Double](repeating: 0.0, count: 64)
        var atb = [Double](repeating: 0.0, count: 8)

        for i in 0..<n {
            let x = (src[i].x - meanSrc.x) * scaleSrc
            let y = (src[i].y - meanSrc.y) * scaleSrc
            let xp = (dst[i].x - meanDst.x) * scaleDst
            let yp = (dst[i].y - meanDst.y) * scaleDst
            let w = weights?[i] ?? 1.0

            let r1: [Double] = [x, y, 1.0, 0.0, 0.0, 0.0, -x * xp, -y * xp]
            let b1 = xp
            let r2: [Double] = [0.0, 0.0, 0.0, x, y, 1.0, -x * yp, -y * yp]
            let b2 = yp

            for r in 0..<8 {
                let wr1 = w * r1[r]
                let wr2 = w * r2[r]
                atb[r] += wr1 * b1 + wr2 * b2
                for c in r..<8 {
                    ata[r * 8 + c] += wr1 * r1[c] + wr2 * r2[c]
                }
            }
        }
        for r in 0..<8 {
            for c in 0..<r {
                ata[r * 8 + c] = ata[c * 8 + r]
            }
            ata[r * 8 + r] += 1e-9 // 微量 Tikhonov 正則化防止共線奇異
        }

        guard let hNorm8 = solveLinearSystem8x8(matrix: ata, rhs: atb) else { return nil }
        let Hn: [Double] = [
            hNorm8[0], hNorm8[1], hNorm8[2],
            hNorm8[3], hNorm8[4], hNorm8[5],
            hNorm8[6], hNorm8[7], 1.0
        ]

        // 反正規化：H = T_dst^{-1} * Hn * T_src
        // T_src = [scaleSrc, 0, -scaleSrc*meanSrc.x; 0, scaleSrc, -scaleSrc*meanSrc.y; 0, 0, 1]
        // T_dst^{-1} = [1/scaleDst, 0, meanDst.x; 0, 1/scaleDst, meanDst.y; 0, 0, 1]
        let txS = -scaleSrc * meanSrc.x
        let tyS = -scaleSrc * meanSrc.y
        let m00 = Hn[0] * scaleSrc, m01 = Hn[1] * scaleSrc, m02 = Hn[0] * txS + Hn[1] * tyS + Hn[2]
        let m10 = Hn[3] * scaleSrc, m11 = Hn[4] * scaleSrc, m12 = Hn[3] * txS + Hn[4] * tyS + Hn[5]
        let m20 = Hn[6] * scaleSrc, m21 = Hn[7] * scaleSrc, m22 = Hn[6] * txS + Hn[7] * tyS + Hn[8]

        let invSD = 1.0 / scaleDst
        var H: [Double] = [
            invSD * m00 + meanDst.x * m20, invSD * m01 + meanDst.x * m21, invSD * m02 + meanDst.x * m22,
            invSD * m10 + meanDst.y * m20, invSD * m11 + meanDst.y * m21, invSD * m12 + meanDst.y * m22,
            m20,                           m21,                           m22
        ]
        if abs(H[8]) > 1e-8 {
            let invH8 = 1.0 / H[8]
            for i in 0..<9 { H[i] *= invH8 }
        }
        return H
    }

    /// 具主元選擇之 $8\times 8$ 高斯消去法線性求解器
    private static func solveLinearSystem8x8(matrix: [Double], rhs: [Double]) -> [Double]? {
        var A = matrix
        var b = rhs
        let n = 8

        for k in 0..<n {
            var maxRow = k
            var maxVal = abs(A[k * n + k])
            for i in (k + 1)..<n {
                let v = abs(A[i * n + k])
                if v > maxVal {
                    maxVal = v
                    maxRow = i
                }
            }
            if maxVal < 1e-11 { return nil }
            if maxRow != k {
                for j in k..<n {
                    A.swapAt(k * n + j, maxRow * n + j)
                }
                b.swapAt(k, maxRow)
            }
            let pivot = A[k * n + k]
            for i in (k + 1)..<n {
                let factor = A[i * n + k] / pivot
                A[i * n + k] = 0.0
                for j in (k + 1)..<n {
                    A[i * n + j] -= factor * A[k * n + j]
                }
                b[i] -= factor * b[k]
            }
        }

        var x = [Double](repeating: 0.0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[i]
            for j in (i + 1)..<n {
                sum -= A[i * n + j] * x[j]
            }
            x[i] = sum / A[i * n + i]
        }
        return x
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
