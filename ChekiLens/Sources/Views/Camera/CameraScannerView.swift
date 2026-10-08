import SwiftUI
import SwiftData
import Combine
@preconcurrency import AVFoundation
import CoreMotion
import Vision
import UIKit

// MARK: - Camera Capture Mode (仿照 Apple 原生相機底部黃字模式轉盤)

enum ChekiCaptureMode: String, CaseIterable, Identifiable {
    case dualGlare = "防反光"
    case single = "拍照"
    case frontAndBack = "正反雙面"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dualGlare:
            return L10n.tr("防反光", "反射防止")
        case .single:
            return L10n.tr("拍照", "写真")
        case .frontAndBack:
            return L10n.tr("正反雙面", "両面撮影")
        }
    }
}

// MARK: - Flash Mode

enum CameraFlashSetting: CaseIterable {
    case off
    case auto
    case on

    var symbolName: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .auto: return "bolt.badge.automatic.fill"
        case .on: return "bolt.fill"
        }
    }

    var label: String {
        switch self {
        case .off: return L10n.tr("關閉", "オフ")
        case .auto: return L10n.tr("自動", "自動")
        case .on: return L10n.tr("開啟", "オン")
        }
    }

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    func next() -> CameraFlashSetting {
        switch self {
        case .off: return .auto
        case .auto: return .on
        case .on: return .off
        }
    }
}

// MARK: - CameraSessionController

@MainActor
final class CameraSessionController: NSObject, ObservableObject {

    struct CapturedPhotoPacket: @unchecked Sendable {
        let rawData: Data
        let image: UIImage
    }

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoSampleQueue = DispatchQueue(label: "com.chekilens.camera.videoSampleQueue", qos: .userInteractive)
    private let motionManager = CMMotionManager()

    @Published var isCameraAvailable: Bool = false
    @Published var isAuthorized: Bool = false
    @Published var isSessionRunning: Bool = false

    /// 畫面正規化座標 (0...1, 原點左上) 的即時追蹤四角 [TL, TR, BR, BL]
    @Published var trackedQuadPoints: [CGPoint]? = nil
    @Published var exposureBias: Float = -0.3
    @Published var zoomFactor: CGFloat = 1.0
    @Published var flashSetting: CameraFlashSetting = .off

    private var videoDevice: AVCaptureDevice?
    private var photoContinuation: CheckedContinuation<CapturedPhotoPacket?, Never>?
    nonisolated(unsafe) private var sampleFrameCounter: Int = 0
    nonisolated(unsafe) private var missedQuadFrameCount: Int = 0
    nonisolated(unsafe) var isPausedForProcessing: Bool = false

    /// 四角合成防反光：拍下第 1 張後立即鎖定四邊形狀並停止 Vision 矩形重抓，改用視覺錨點平移追蹤 (`VNTranslationalImageRegistrationRequest` + 拍立得局部錨點比對) 讓綠框與 1~4 角點死鎖在實體拍立得位置上
    nonisolated(unsafe) var isQuadDetectionLocked: Bool = false
    nonisolated(unsafe) private var shouldCaptureAnchorFrame: Bool = false
    nonisolated(unsafe) private var lockedInitialQuad: [CGPoint]? = nil
    nonisolated(unsafe) private var anchorTrackCGImage: CGImage? = nil
    nonisolated(unsafe) private var prevTrackCGImage: CGImage? = nil
    nonisolated(unsafe) private var trackedVisualOffset: CGPoint = .zero
    nonisolated(unsafe) private static let sharedTrackingCIContext = CIContext(options: [.cacheIntermediates: false])

    private struct ChekiAnchorSample: Sendable {
        let x: Int
        let y: Int
        let r: Float
        let g: Float
        let b: Float
        let gx: Float
        let gy: Float
        let weight: Float
    }
    nonisolated(unsafe) private var anchorSamples: [ChekiAnchorSample] = []

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
        default:
            isAuthorized = false
        }

        guard isAuthorized else {
            simulateQuadForPreview()
            return
        }

        configureSessionIfNeeded()
    }

    func stop() {
        unlockQuadAndStopGyro()
        setTorch(enabled: false)
        if let pending = photoContinuation {
            photoContinuation = nil
            pending.resume(returning: nil)
        }
        guard isSessionRunning else { return }
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        isSessionRunning = false
    }

    /// 鎖定第 1 張拍立得四邊形狀並停止 Vision 矩形偵測，啟動視覺錨點追蹤使綠框與 1,2,3,4 釘在實體拍立得上
    @discardableResult
    func lockQuadAndStartGyro() -> [CGPoint] {
        let baseQuad = trackedQuadPoints ?? [
            CGPoint(x: 0.23, y: 0.14),
            CGPoint(x: 0.77, y: 0.14),
            CGPoint(x: 0.79, y: 0.86),
            CGPoint(x: 0.21, y: 0.86)
        ]
        lockedInitialQuad = baseQuad
        trackedQuadPoints = baseQuad
        trackedVisualOffset = .zero
        anchorTrackCGImage = nil
        prevTrackCGImage = nil
        anchorSamples = []
        shouldCaptureAnchorFrame = true
        isQuadDetectionLocked = true
        return baseQuad
    }

    /// 解除四邊鎖定，恢復一般 Vision 即時偵測
    func unlockQuadAndStopGyro() {
        isQuadDetectionLocked = false
        shouldCaptureAnchorFrame = false
        lockedInitialQuad = nil
        anchorTrackCGImage = nil
        prevTrackCGImage = nil
        anchorSamples = []
        trackedVisualOffset = .zero
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }

    /// Google フォトスキャン 模式：自動開啟或關閉 iPhone 背面常亮補光燈 (LED Torch) 與閃光燈
    func setTorch(enabled: Bool) {
        flashSetting = enabled ? .on : .off
        guard let device = videoDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if enabled && device.isTorchModeSupported(.on) {
                try device.setTorchModeOn(level: 0.85)
            } else if device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {}
    }

    private func configureSessionIfNeeded() {
        guard !isSessionRunning else { return }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            // 模擬器無實體相機時自動啟用模擬取景器與即時追蹤框
            isCameraAvailable = false
            simulateQuadForPreview()
            return
        }

        isCameraAvailable = true
        videoDevice = device

        session.beginConfiguration()
        session.sessionPreset = .photo

        if session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .speed
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoSampleQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

        applyExposureBias(exposureBias)

        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
        isSessionRunning = true
    }

    func simulateQuadForPreview() {
        // 標準 86:54 拍立得在 4:3 取景器中央的預設四角座標
        trackedQuadPoints = [
            CGPoint(x: 0.23, y: 0.14),
            CGPoint(x: 0.77, y: 0.14),
            CGPoint(x: 0.79, y: 0.86),
            CGPoint(x: 0.21, y: 0.86)
        ]
    }

    func applyExposureBias(_ bias: Float) {
        exposureBias = bias
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            let clamped = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, bias))
            device.setExposureTargetBias(clamped, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {}
    }

    func applyZoom(_ factor: CGFloat) {
        zoomFactor = factor
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            let clamped = max(1.0, min(device.activeFormat.videoMaxZoomFactor, factor))
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {}
    }

    func focus(at normalizedPoint: CGPoint) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = normalizedPoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = normalizedPoint
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {}
    }

    /// 零延遲拍攝：直接回傳相機硬體輸出的原始 JPEG Data 與 UIImage（不做 12MP 同步轉正重繪，讓快門瞬間完成存檔）
    func capturePhotoPacket(
        isBacksideSimulated: Bool = false,
        simulatedGlareAngleStep: Int = 0
    ) async -> CapturedPhotoPacket? {
        guard isCameraAvailable, isSessionRunning else {
            guard let simImage = makeSimulatedCaptureImage(
                isBackside: isBacksideSimulated,
                glareAngleStep: simulatedGlareAngleStep
            ), let simData = simImage.jpegData(compressionQuality: 0.90) else {
                return nil
            }
            return CapturedPhotoPacket(rawData: simData, image: simImage)
        }

        // 若前一次快門 continuation 尚未完成，先安全釋放避免 CheckedContinuation 卡死
        if let existing = self.photoContinuation {
            self.photoContinuation = nil
            existing.resume(returning: nil)
        }

        return await withCheckedContinuation { continuation in
            self.photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            // 若常亮 Torch 已開啟則無需再重複觸發瞬間閃燈，否則依 flashSetting 觸發
            if let device = videoDevice, device.hasTorch, device.torchMode == .on {
                if photoOutput.supportedFlashModes.contains(.off) {
                    settings.flashMode = .off
                }
            } else if photoOutput.supportedFlashModes.contains(flashSetting.avFlashMode) {
                settings.flashMode = flashSetting.avFlashMode
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func makeSimulatedCaptureImage(
        isBackside: Bool,
        glareAngleStep: Int = 0
    ) -> UIImage? {
        let size = CGSize(width: 540, height: 860)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // 拍立得白邊基底
            cg.setFillColor(UIColor(white: isBackside ? 0.94 : 0.98, alpha: 1.0).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            let photoRect = CGRect(x: 40, y: 50, width: 460, height: 620)
            cg.saveGState()
            cg.addRect(photoRect)
            cg.clip()

            let colors = isBackside
                ? [UIColor.systemPurple.withAlphaComponent(0.25).cgColor, UIColor.systemIndigo.withAlphaComponent(0.18).cgColor]
                : [UIColor.systemBlue.cgColor, UIColor.systemPink.cgColor]

            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0.0, 1.0]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: photoRect.minX, y: photoRect.minY),
                    end: CGPoint(x: photoRect.maxX, y: photoRect.maxY),
                    options: []
                )
            }

            // 模擬器下若處於四角合成防反光拍攝（Step 1 為中央反光，Step 2~5 為四個角落各自的反光），
            // 驗證多視角合成後能將第 1 張中央強光白斑 100% 互補消除。
            if !isBackside && glareAngleStep >= 1 {
                let glareCenter: CGPoint
                switch glareAngleStep {
                case 1:  glareCenter = CGPoint(x: 270, y: 360) // 第 1 張：中央強光白斑
                case 2:  glareCenter = CGPoint(x: 135, y: 145) // 左上 1 角點強光白斑
                case 3:  glareCenter = CGPoint(x: 405, y: 145) // 右上 2 角點強光白斑
                case 4:  glareCenter = CGPoint(x: 405, y: 575) // 右下 3 角點強光白斑
                default: glareCenter = CGPoint(x: 135, y: 575) // 左下 4 角點強光白斑
                }
                let glareColors = [
                    UIColor(white: 1.0, alpha: 0.96).cgColor,
                    UIColor(white: 1.0, alpha: 0.48).cgColor,
                    UIColor(white: 1.0, alpha: 0.0).cgColor
                ] as CFArray
                if let radial = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: glareColors,
                    locations: [0.0, 0.45, 1.0]
                ) {
                    cg.drawRadialGradient(
                        radial,
                        startCenter: glareCenter,
                        startRadius: 4,
                        endCenter: glareCenter,
                        endRadius: 95,
                        options: []
                    )
                }
            }

            cg.restoreGState()
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate & Video Sample Delegate

extension CameraSessionController: AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // 直接取用硬體 ISP 輸出的原始 JPEG Data 與延遲解碼 UIImage，不在快門路徑上做 12MP 轉正重繪
        let packet: CapturedPhotoPacket? = photo.fileDataRepresentation().flatMap { data in
            guard let img = UIImage(data: data) else { return nil }
            return CapturedPhotoPacket(rawData: data, image: img)
        }
        Task { @MainActor in
            if let cont = self.photoContinuation {
                self.photoContinuation = nil
                cont.resume(returning: packet)
            }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        guard error != nil else { return }
        Task { @MainActor in
            if let cont = self.photoContinuation {
                self.photoContinuation = nil
                cont.resume(returning: nil)
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isPausedForProcessing else { return }
        sampleFrameCounter &+= 1

        // 四角合成防反光：第 1 張鎖定四邊形狀後，停止 Vision 矩形重抓（四邊不再跳動變形），
        // 改以輕量視覺拍立得錨點追蹤計算拍立得在畫面中的剛體平移 (dx, dy)，讓綠框與 1,2,3,4 死鎖在實體拍立得上
        if isQuadDetectionLocked {
            guard shouldCaptureAnchorFrame || sampleFrameCounter % 2 == 0 else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let baseQuad = lockedInitialQuad,
                  baseQuad.count == 4 else { return }
            updateLockedQuadVisualTracking(pixelBuffer: pixelBuffer, baseQuad: baseQuad)
            return
        }

        guard sampleFrameCounter % 3 == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 0.95
        request.minimumSize = 0.18
        request.maximumObservations = 1
        request.minimumConfidence = 0.60

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])

        if let rect = request.results?.first {
            missedQuadFrameCount = 0
            // Vision 原點在左下，轉換為 UIKit/SwiftUI 原點在左上 (y = 1 - y)
            let points = [
                CGPoint(x: rect.topLeft.x, y: 1.0 - rect.topLeft.y),
                CGPoint(x: rect.topRight.x, y: 1.0 - rect.topRight.y),
                CGPoint(x: rect.bottomRight.x, y: 1.0 - rect.bottomRight.y),
                CGPoint(x: rect.bottomLeft.x, y: 1.0 - rect.bottomLeft.y)
            ]
            Task { @MainActor in
                guard !self.isQuadDetectionLocked else { return }
                withAnimation(.interpolatingSpring(stiffness: 200, damping: 24)) {
                    self.trackedQuadPoints = points
                }
            }
        } else {
            missedQuadFrameCount &+= 1
            if missedQuadFrameCount >= 8 {
                Task { @MainActor in
                    guard !self.isQuadDetectionLocked else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.trackedQuadPoints = nil
                    }
                }
            }
        }
    }

    /// 在 120×160 直向縮圖上追蹤已鎖定之拍立得剛體平移，使綠框與 1~4 角點緊貼實體拍立得（即使部分角點移出畫面外亦精準鎖定）
    private nonisolated func updateLockedQuadVisualTracking(
        pixelBuffer: CVPixelBuffer,
        baseQuad: [CGPoint]
    ) {
        let trackW = 120
        let trackH = 160
        let ciImg = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let ext = ciImg.extent
        guard ext.width > 16, ext.height > 16 else { return }

        let scaledCI = ciImg
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(trackW) / ext.width,
                y: CGFloat(trackH) / ext.height
            ))
            .cropped(to: CGRect(x: 0, y: 0, width: trackW, height: trackH))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var curBuf = [UInt8](repeating: 0, count: trackW * trackH * 4)
        guard let curCG = Self.sharedTrackingCIContext.createCGImage(
            scaledCI,
            from: CGRect(x: 0, y: 0, width: trackW, height: trackH)
        ),
        let ctx = CGContext(
            data: &curBuf,
            width: trackW,
            height: trackH,
            bitsPerComponent: 8,
            bytesPerRow: trackW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }
        ctx.interpolationQuality = .low
        ctx.draw(curCG, in: CGRect(x: 0, y: 0, width: trackW, height: trackH))

        let tl = baseQuad[0], tr = baseQuad[1], br = baseQuad[2], bl = baseQuad[3]
        func bilerp(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            let top = CGPoint(x: tl.x + (tr.x - tl.x) * u, y: tl.y + (tr.y - tl.y) * u)
            let bot = CGPoint(x: bl.x + (br.x - bl.x) * u, y: bl.y + (br.y - bl.y) * u)
            return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
        }

        // 首幀：擷取拍立得白邊外框、內框與相片特徵作為錨點模板（自動略過閃光燈反光區 L > 220）
        if shouldCaptureAnchorFrame || anchorSamples.isEmpty {
            var samples: [ChekiAnchorSample] = []
            let gridSteps = 16
            for iv in 0...gridSteps {
                let v = -0.02 + 1.04 * (CGFloat(iv) / CGFloat(gridSteps))
                for iu in 0...gridSteps {
                    let u = -0.02 + 1.04 * (CGFloat(iu) / CGFloat(gridSteps))
                    let pt = bilerp(u, v)
                    let px = Int((pt.x * CGFloat(trackW)).rounded())
                    let py = Int((pt.y * CGFloat(trackH)).rounded())
                    guard px >= 2, px < trackW - 2, py >= 2, py < trackH - 2 else { continue }
                    let idx = (py * trackW + px) * 4
                    let r = Float(curBuf[idx])
                    let g = Float(curBuf[idx + 1])
                    let b = Float(curBuf[idx + 2])
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    // 排除第 1 張中央閃光燈反光白斑，避免追著反光跑
                    if lum > 222.0 && u > 0.12 && u < 0.88 && v > 0.10 && v < 0.78 {
                        continue
                    }
                    let idxL = (py * trackW + (px - 1)) * 4
                    let idxR = (py * trackW + (px + 1)) * 4
                    let idxU = ((py - 1) * trackW + px) * 4
                    let idxD = ((py + 1) * trackW + px) * 4
                    let lumL = 0.299 * Float(curBuf[idxL]) + 0.587 * Float(curBuf[idxL + 1]) + 0.114 * Float(curBuf[idxL + 2])
                    let lumR = 0.299 * Float(curBuf[idxR]) + 0.587 * Float(curBuf[idxR + 1]) + 0.114 * Float(curBuf[idxR + 2])
                    let lumU = 0.299 * Float(curBuf[idxU]) + 0.587 * Float(curBuf[idxU + 1]) + 0.114 * Float(curBuf[idxU + 2])
                    let lumD = 0.299 * Float(curBuf[idxD]) + 0.587 * Float(curBuf[idxD + 1]) + 0.114 * Float(curBuf[idxD + 2])
                    let gx = lumR - lumL
                    let gy = lumD - lumU
                    let isEdge = (u <= 0.08 || u >= 0.92 || v <= 0.08 || v >= 0.92 || abs(v - 0.78) <= 0.06)
                    let weight: Float = isEdge ? 1.6 : 1.0
                    samples.append(ChekiAnchorSample(
                        x: px, y: py, r: r, g: g, b: b, gx: gx, gy: gy, weight: weight
                    ))
                }
            }
            anchorSamples = samples
            anchorTrackCGImage = curCG
            prevTrackCGImage = curCG
            trackedVisualOffset = .zero
            shouldCaptureAnchorFrame = false
            return
        }

        // 先利用相鄰幀 Vision 影像平移註冊取得快速初估位移
        var predDxPx = Int((trackedVisualOffset.x * CGFloat(trackW)).rounded())
        var predDyPx = Int((trackedVisualOffset.y * CGFloat(trackH)).rounded())
        if let prevCG = prevTrackCGImage {
            let regReq = VNTranslationalImageRegistrationRequest(targetedCGImage: curCG)
            let regHandler = VNImageRequestHandler(cgImage: prevCG, options: [:])
            try? regHandler.perform([regReq])
            if let obs = regReq.results?.first {
                let stepDx = -obs.alignmentTransform.tx
                let stepDy = obs.alignmentTransform.ty
                if hypot(stepDx, stepDy) < CGFloat(trackW) * 0.35 {
                    predDxPx += Int(stepDx.rounded())
                    predDyPx += Int(stepDy.rounded())
                }
            }
        }
        prevTrackCGImage = curCG

        let samples = anchorSamples
        let minValidCount = max(14, samples.count / 4)

        func evaluateShift(dx: Int, dy: Int) -> Float {
            var errSum: Float = 0
            var weightSum: Float = 0
            var validCount = 0
            for s in samples {
                let qx = s.x + dx
                let qy = s.y + dy
                guard qx >= 2, qx < trackW - 2, qy >= 2, qy < trackH - 2 else { continue }
                let idx = (qy * trackW + qx) * 4
                let r = Float(curBuf[idx])
                let g = Float(curBuf[idx + 1])
                let b = Float(curBuf[idx + 2])
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                // 若當前像素處於移動後的閃光燈強反光核，跳過不計入誤差
                if lum > 235.0 && (s.r * 0.299 + s.g * 0.587 + s.b * 0.114) < 205.0 {
                    continue
                }
                let idxL = (qy * trackW + (qx - 1)) * 4
                let idxR = (qy * trackW + (qx + 1)) * 4
                let idxU = ((qy - 1) * trackW + qx) * 4
                let idxD = ((qy + 1) * trackW + qx) * 4
                let lumL = 0.299 * Float(curBuf[idxL]) + 0.587 * Float(curBuf[idxL + 1]) + 0.114 * Float(curBuf[idxL + 2])
                let lumR = 0.299 * Float(curBuf[idxR]) + 0.587 * Float(curBuf[idxR + 1]) + 0.114 * Float(curBuf[idxR + 2])
                let lumU = 0.299 * Float(curBuf[idxU]) + 0.587 * Float(curBuf[idxU + 1]) + 0.114 * Float(curBuf[idxU + 2])
                let lumD = 0.299 * Float(curBuf[idxD]) + 0.587 * Float(curBuf[idxD + 1]) + 0.114 * Float(curBuf[idxD + 2])
                let gx = lumR - lumL
                let gy = lumD - lumU

                let colorDiff = (abs(r - s.r) + abs(g - s.g) + abs(b - s.b)) / 3.0
                let gradDiff = (abs(gx - s.gx) + abs(gy - s.gy)) * 0.85
                let cost = min(90.0, colorDiff * 0.38 + gradDiff * 0.62)
                errSum += cost * s.weight
                weightSum += s.weight
                validCount += 1
            }
            guard validCount >= minValidCount, weightSum > 1.0 else {
                return .greatestFiniteMagnitude
            }
            let driftPenalty = hypot(Float(dx - predDxPx), Float(dy - predDyPx)) * 0.18
            return (errSum / weightSum) + driftPenalty
        }

        // 第一階段：粗搜尋（涵蓋相鄰幀預測周圍 ±27px 與基準周圍）
        var bestDx = predDxPx
        var bestDy = predDyPx
        var bestCost = evaluateShift(dx: bestDx, dy: bestDy)

        let searchMinX = max(-85, predDxPx - 27)
        let searchMaxX = min(85, predDxPx + 27)
        let searchMinY = max(-115, predDyPx - 33)
        let searchMaxY = min(115, predDyPx + 33)

        for dy in stride(from: searchMinY, through: searchMaxY, by: 3) {
            for dx in stride(from: searchMinX, through: searchMaxX, by: 3) {
                let c = evaluateShift(dx: dx, dy: dy)
                if c < bestCost {
                    bestCost = c
                    bestDx = dx
                    bestDy = dy
                }
            }
        }

        // 第二階段：1px 精細對位
        let fineCenterDx = bestDx
        let fineCenterDy = bestDy
        for dy in (fineCenterDy - 2)...(fineCenterDy + 2) {
            for dx in (fineCenterDx - 2)...(fineCenterDx + 2) {
                let c = evaluateShift(dx: dx, dy: dy)
                if c < bestCost {
                    bestCost = c
                    bestDx = dx
                    bestDy = dy
                }
            }
        }

        let rawNormDx = CGFloat(bestDx) / CGFloat(trackW)
        let rawNormDy = CGFloat(bestDy) / CGFloat(trackH)
        let smoothedOffset = CGPoint(
            x: trackedVisualOffset.x * 0.30 + rawNormDx * 0.70,
            y: trackedVisualOffset.y * 0.30 + rawNormDy * 0.70
        )
        trackedVisualOffset = smoothedOffset

        let shiftedQuad = baseQuad.map { pt in
            CGPoint(x: pt.x + smoothedOffset.x, y: pt.y + smoothedOffset.y)
        }

        Task { @MainActor in
            guard self.isQuadDetectionLocked else { return }
            self.trackedQuadPoints = shiftedQuad
        }
    }
}

// MARK: - CameraPreviewRepresentable

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class VideoPreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> VideoPreviewUIView {
        let view = VideoPreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: VideoPreviewUIView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

// MARK: - CameraScannerView (Task 4.3: Apple 原生相機風格即時掃描視圖)

/// Task 4.3: 嚴格遵循 Apple iOS 原生相機 (Camera.app) 介面規範之拍立得掃描器
/// - 頂部黑色控制列：閃光燈、曝光補償顯示 (`-0.3` 黃色指示)、展開控制抽屜按鈕 (`chevron.up`)、關閉按鈕
/// - 中央 4:3 取景窗：3×3 九宮格輔助線、即時拍立得四角追蹤框、點擊對焦黃框與太陽曝光標示、底部 `0.5 / 1× / 2` 倍率切換圈
/// - 底部黑色快門區：Apple 相機黃字模式橫向轉盤（`防反光` / `拍照` / `正反雙面`）、左下角最新拍立得縮圖、中央雙層白色快門鈕、右側翻面/切換鈕
struct CameraScannerView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]

    var defaultMember: IdolMember? = nil

    @StateObject private var camera = CameraSessionController()

    // Apple 原生相機狀態
    @State private var captureMode: ChekiCaptureMode = .single
    @State private var showGridOverlay: Bool = true
    @State private var showSecondaryControlsDrawer: Bool = false
    @State private var isShutterPressed: Bool = false
    @State private var showCaptureFlash: Bool = false
    @State private var isProcessingCapture: Bool = false

    @AppStorage("isProLifetimeUnlocked") private var isProLifetimeUnlocked: Bool = false

    // 正反雙面連續拍攝狀態（先拍正面 -> 提示翻面 -> 再拍背面；正面裁切於背景進行，不阻塞快門）
    @State private var pendingFrontImageData: Data? = nil
    @State private var pendingOriginalFrontImageData: Data? = nil
    @State private var pendingFrontCropTask: Task<(Data?, Data?, String?, Date?, FilmFormat), Never>? = nil

    // Task 5.4 & 6.1: Google フォトスキャン (PhotoScan) 四角合成防反光連續拍攝狀態（首張固定四邊 + 陀螺儀移動 + 四角手動按快門）
    @State private var isPhotoScanSessionActive: Bool = false
    @State private var photoScanCapturedImages: [UIImage] = []
    @State private var photoScanCapturedQuads: [[CGPoint]?] = []
    @State private var photoScanCornerCompleted: [Bool] = [false, false, false, false]
    @State private var pendingModeBFirstRawJPEG: Data? = nil
    @State private var pendingModeBPreparedTask: Task<VisionManager.ModeBPreparedFirstAngle?, Never>? = nil
    @State private var statusBannerMessage: String? = nil

    // 點擊對焦黃框狀態
    @State private var focusIndicatorPoint: CGPoint? = nil
    @State private var showingLatestDetail: Bool = false

    private let zoomPresets: [CGFloat] = [0.5, 1.0, 2.0]

    private var completedCornerCount: Int {
        photoScanCornerCompleted.filter { $0 }.count
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // 1. Apple 原生相機頂部控制列
                topCameraControlBar

                // 可展開的次級控制抽屜（曝光補償滑桿 / 九宮格開關）
                if showSecondaryControlsDrawer {
                    secondaryControlsDrawer
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 8)

                // 2. 中央 4:3 標準相機取景器
                viewfinderContainer

                Spacer(minLength: 8)

                // 3. Apple 原生相機底部模式轉盤與快門操作區
                bottomCameraDeck
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task {
            await camera.start()
            if captureMode == .dualGlare {
                camera.setTorch(enabled: true)
            }
        }
        .onDisappear {
            camera.stop()
        }
        .sheet(isPresented: $showingLatestDetail) {
            if let latest = chekiItems.first(where: { !$0.isDeleted && $0.modelContext != nil }) {
                NavigationStack {
                    ChekiDetailView(itemID: latest.id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("返回相機") {
                                    showingLatestDetail = false
                                }
                            }
                        }
                }
            }
        }
    }

    // MARK: - 1. Top Camera Control Bar (Apple 原生相機頂部圖示列)

    private var topCameraControlBar: some View {
        HStack(spacing: 18) {
            // 左側：閃光燈 / 常亮補光燈切換
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let nextFlash = camera.flashSetting.next()
                camera.flashSetting = nextFlash
                if captureMode == .dualGlare {
                    camera.setTorch(enabled: nextFlash != .off)
                } else if nextFlash == .off {
                    camera.setTorch(enabled: false)
                }
            } label: {
                Image(systemName: camera.flashSetting.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(camera.flashSetting == .off ? .white : .yellow)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("閃光燈：\(camera.flashSetting.label)")

            // 左側：曝光補償指示膠囊（如 露出 -0.3）
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showSecondaryControlsDrawer.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plusminus.circle")
                        .font(.system(size: 14, weight: .semibold))
                    Text(String(format: "%+.1f", camera.exposureBias))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(abs(camera.exposureBias) > 0.05 ? .yellow : .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.14), in: Capsule())
            }
            .accessibilityLabel("曝光補償")

            Spacer()

            // 中央：展開/收合次級控制列按鈕 (`chevron.up` / `chevron.down`)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showSecondaryControlsDrawer.toggle()
                }
            } label: {
                Image(systemName: showSecondaryControlsDrawer ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(showSecondaryControlsDrawer ? .yellow : .white)
            }
            .accessibilityLabel("相機進階控制")

            Spacer()

            // 右側：九宮格快速切換
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeInOut(duration: 0.18)) {
                    showGridOverlay.toggle()
                }
            } label: {
                Image(systemName: "squareshape.split.3x3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(showGridOverlay ? .yellow : .white.opacity(0.65))
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("九宮格輔助線")

            // 右側：關閉相機返回
            Button {
                camera.setTorch(enabled: false)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.16), in: Circle())
            }
            .accessibilityLabel("關閉相機")
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var secondaryControlsDrawer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sun.min.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)

                Slider(
                    value: Binding(
                        get: { camera.exposureBias },
                        set: { camera.applyExposureBias($0) }
                    ),
                    in: -2.0...2.0,
                    step: 0.1
                )
                .tint(.yellow)

                Image(systemName: "sun.max.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)

                Button("重設") {
                    camera.applyExposureBias(-0.3)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08))
    }

    // MARK: - 2. Center 4:3 Viewfinder (3×3 九宮格 + 拍立得追蹤框 + 四角陀螺儀對準導引 + 倍率切換圈)

    private var viewfinderContainer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                // 相機即時預覽流（若為模擬器則顯示擬真取景背景）
                if camera.isCameraAvailable {
                    CameraPreviewView(session: camera.session)
                } else {
                    simulatedViewfinderBackground(size: geo.size)
                }

                // 3×3 九宮格輔助線（Apple 原生相機細白線）
                if showGridOverlay {
                    CameraGridLinesOverlay()
                }

                // 拍立得虛線追蹤框與四角 L 型錨點（首張拍攝後即由陀螺儀平滑帶動，不再受 Vision 跳動影響）
                if let quad = camera.trackedQuadPoints, quad.count == 4 {
                    ChekiQuadTrackingOverlay(normalizedPoints: quad)
                }

                // 四角合成防反光：陀螺儀追蹤之四個角落圓點與中央準星（移動至四角後分別手動按快門拍攝）
                if captureMode == .dualGlare && isPhotoScanSessionActive {
                    PhotoScanFourCornerOverlay(
                        quadPoints: camera.trackedQuadPoints ?? Self.defaultPreviewQuad,
                        cornerCompleted: photoScanCornerCompleted,
                        activeTargetIndex: activePhotoScanCornerIndex,
                        onTapCorner: { cornerIdx in
                            Task { await capturePhotoScanCorner(index: cornerIdx) }
                        }
                    )
                }

                // 點擊對焦黃色方框 + 太陽圖示（Apple 原生相機對焦指示）
                if let focusPoint = focusIndicatorPoint {
                    AppleFocusBoxIndicator()
                        .position(focusPoint)
                        .transition(.scale(scale: 1.25).combined(with: .opacity))
                }

                // 頂部拍攝狀態提示膠囊 & 底部提前合成按鈕 / 倍率切換圈
                VStack {
                    statusPillBanner
                        .padding(.top, 14)

                    Spacer()

                    if captureMode == .dualGlare && isPhotoScanSessionActive && completedCornerCount >= 1 {
                        Button {
                            Task { await completePhotoScanMultiFrameCapture() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                Text("立即合成無反光照片 (\(completedCornerCount)/4 角點)")
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.cyan, in: Capsule())
                            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessingCapture)
                        .padding(.bottom, 8)
                    }

                    // 取景窗底部：Apple 原生相機倍率切換圓鈕 (`0.5` / `1×` / `2`)
                    zoomDialBar
                        .padding(.bottom, 14)
                }

                // 快門瞬間黑幕閃動回饋
                if showCaptureFlash {
                    Color.black
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { event in
                        let location = event.location
                        let normalized = CGPoint(
                            x: max(0, min(1, location.x / max(width, 1))),
                            y: max(0, min(1, location.y / max(height, 1)))
                        )
                        camera.focus(at: normalized)
                        triggerFocusIndicator(at: location)
                    }
            )
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }

    private static let defaultPreviewQuad: [CGPoint] = [
        CGPoint(x: 0.23, y: 0.14),
        CGPoint(x: 0.77, y: 0.14),
        CGPoint(x: 0.79, y: 0.86),
        CGPoint(x: 0.21, y: 0.86)
    ]

    private var nextUncapturedCornerIndex: Int? {
        photoScanCornerCompleted.firstIndex(of: false)
    }

    /// 根據陀螺儀移動後的四角位置，找出目前最接近取景器中央 `(0.5, 0.5)` 且尚未拍攝的角點；若未特別靠近則依序指向下一個未拍角點
    private var activePhotoScanCornerIndex: Int? {
        guard isPhotoScanSessionActive else { return nil }
        let quad = camera.trackedQuadPoints ?? Self.defaultPreviewQuad
        let targets = Self.computeFourCornerTargetPoints(from: quad)
        let center = CGPoint(x: 0.5, y: 0.5)

        var closestIdx: Int? = nil
        var minDist: CGFloat = .greatestFiniteMagnitude
        for idx in 0..<min(4, targets.count) where !photoScanCornerCompleted[idx] {
            let d = hypot(targets[idx].x - center.x, targets[idx].y - center.y)
            if d < minDist {
                minDist = d
                closestIdx = idx
            }
        }
        if let closestIdx, minDist <= 0.24 {
            return closestIdx
        }
        return nextUncapturedCornerIndex
    }

    private func simulatedViewfinderBackground(size: CGSize) -> some View {
        ZStack {
            // 模擬木紋/深色桌面環境
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.14, blue: 0.16),
                    Color(red: 0.08, green: 0.08, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 模擬取景器中央放置的實體拍立得卡片
            VStack(spacing: 0) {
                ZStack {
                    LinearGradient(
                        colors: pendingFrontImageData == nil
                            ? [Color.indigo.opacity(0.85), Color.pink.opacity(0.85)]
                            : [Color.gray.opacity(0.35), Color.purple.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    if pendingFrontImageData != nil {
                        VStack(spacing: 8) {
                            Text("2026.10.06")
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(.black.opacity(0.75))
                            Text("いつもありがとう♡")
                                .font(.caption2)
                                .foregroundStyle(.black.opacity(0.65))
                        }
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 12)
                .padding(.bottom, 38)
            }
            .frame(width: size.width * 0.54, height: size.height * 0.72)
            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 10)
        }
    }

    @ViewBuilder
    private var statusPillBanner: some View {
        if let statusBannerMessage {
            Text(statusBannerMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background((captureMode == .dualGlare ? Color.cyan : Color.yellow), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        } else if captureMode == .frontAndBack {
            Text(pendingFrontImageData == nil ? "正反雙面 (1/2)：請對準拍立得【正面】" : "正反雙面 (2/2)：請翻面拍攝【背面手寫】")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.yellow, in: Capsule())
        } else if captureMode == .dualGlare {
            Text(
                isPhotoScanSessionActive
                    ? "⚡️ 四邊已固定：請移動至四個角，分別按快門 (\(completedCornerCount)/4)"
                    : "⚡️ 四角防反光：請先對準拍立得按第 1 次快門固定四邊位置"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.cyan, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        } else {
            Text("已鎖定 86×54mm 拍立得邊框")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private var zoomDialBar: some View {
        HStack(spacing: 8) {
            ForEach(zoomPresets, id: \.self) { preset in
                let isSelected = abs(camera.zoomFactor - preset) < 0.1
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        camera.applyZoom(preset)
                    }
                } label: {
                    Text(preset == 0.5 ? ".5" : (isSelected ? "\(Int(preset))×" : "\(Int(preset))"))
                        .font(.system(size: isSelected ? 13 : 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? .yellow : .white)
                        .frame(width: isSelected ? 36 : 30, height: isSelected ? 36 : 30)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(isSelected ? 0.25 : 0.1), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.black.opacity(0.35), in: Capsule())
    }

    // MARK: - 3. Bottom Camera Deck (Apple 原生相機模式轉盤 + 快門 + 縮圖預覽)

    private var bottomCameraDeck: some View {
        let isWaitingSecondStep = (pendingFrontImageData != nil || isPhotoScanSessionActive)

        return VStack(spacing: 18) {
            // 橫向黃字模式選擇列（仿照 Apple 原生相機：防反光 / 拍照 / 正反雙面）
            HStack(spacing: 28) {
                ForEach(ChekiCaptureMode.allCases) { mode in
                    let isSelected = (captureMode == mode)
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        resetPhotoScanState()
                        pendingFrontCropTask?.cancel()
                        pendingFrontCropTask = nil
                        withAnimation(.snappy(duration: 0.22)) {
                            captureMode = mode
                            pendingFrontImageData = nil
                            pendingOriginalFrontImageData = nil
                            statusBannerMessage = nil
                        }
                        // 切換至「防反光」時比照 Google フォトスキャン 自動開啟常亮補光燈與閃燈；離開時關閉
                        camera.setTorch(enabled: mode == .dualGlare)
                    } label: {
                        Text(mode.displayName)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .tracking(0.8)
                            .foregroundStyle(isSelected ? .yellow : .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)

            // 快門主控制列（左：最新相片縮圖，中：雙圈白色快門，右：翻面/取消配對）
            HStack {
                // 左下：最新拍立得縮圖預覽井
                Button {
                    if !chekiItems.isEmpty {
                        showingLatestDetail = true
                    }
                } label: {
                    ZStack {
                        if let latestData = chekiItems.first?.frontImageData,
                           let uiImage = UIImage(data: latestData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 50, height: 50)
                                .overlay {
                                    Image(systemName: "photo.on.rectangle")
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("檢視最新拍攝的拍立得")

                Spacer()

                // 中央：Apple 原生相機經典雙環白色快門鈕
                Button {
                    Task { await handleShutterTap() }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 4)
                            .frame(width: 74, height: 74)

                        Circle()
                            .fill(
                                isPhotoScanSessionActive
                                    ? Color.cyan
                                    : (pendingFrontImageData != nil ? Color.yellow : Color.white)
                            )
                            .frame(width: 62, height: 62)
                            .scaleEffect(isShutterPressed ? 0.88 : 1.0)
                            .overlay {
                                if isProcessingCapture {
                                    ProgressView()
                                        .tint(.black)
                                } else if isPhotoScanSessionActive {
                                    VStack(spacing: 1) {
                                        Image(systemName: "camera.shutter.button.fill")
                                            .font(.system(size: 16, weight: .bold))
                                        Text("\(completedCornerCount)/4")
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                    }
                                    .foregroundStyle(.black)
                                } else if pendingFrontImageData != nil {
                                    Image(systemName: "rectangle.portrait.rotate")
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.black)
                                }
                            }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isProcessingCapture)
                .accessibilityLabel("快門拍攝")

                Spacer()

                // 右下：模式切換 / 重設雙面或四邊掃描狀態圓鈕
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if isPhotoScanSessionActive {
                        resetPhotoScanState()
                        withAnimation {
                            statusBannerMessage = L10n.tr(
                                "已重設四邊防反光掃描，請重新按快門固定首張位置",
                                "四隅の反射防止スキャンをリセットしました。もう一度シャッターを押して枠を固定してください"
                            )
                        }
                    } else if pendingFrontImageData != nil {
                        pendingFrontCropTask?.cancel()
                        pendingFrontCropTask = nil
                        withAnimation {
                            pendingFrontImageData = nil
                            pendingOriginalFrontImageData = nil
                            statusBannerMessage = L10n.tr(
                                "已取消背面拍攝，重新拍攝正面",
                                "裏面の撮影をキャンセルしました。表面から撮り直してください"
                            )
                        }
                    } else {
                        let nextMode: ChekiCaptureMode = (captureMode == .single) ? .frontAndBack : .single
                        withAnimation(.snappy(duration: 0.22)) {
                            captureMode = nextMode
                        }
                        camera.setTorch(enabled: nextMode == .dualGlare)
                    }
                } label: {
                    Image(systemName: isWaitingSecondStep ? "arrow.counterclockwise" : "rectangle.portrait.rotate")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle((captureMode == .frontAndBack || isWaitingSecondStep) ? .yellow : .white)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切換正反雙面拍攝模式或重設")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 22)
        }
    }

    // MARK: - 四角防反光：首張固定四邊 + 陀螺儀移動 + 四角手動按快門

    private func resetPhotoScanState() {
        camera.unlockQuadAndStopGyro()
        pendingModeBPreparedTask?.cancel()
        pendingModeBPreparedTask = nil
        pendingModeBFirstRawJPEG = nil
        isPhotoScanSessionActive = false
        photoScanCapturedImages.removeAll()
        photoScanCapturedQuads.removeAll()
        photoScanCornerCompleted = [false, false, false, false]
    }

    /// 根據拍立得外框四角 `[TL, TR, BR, BL]` 雙線性內插出四個角落目標圓點位置 `(左上 1, 右上 2, 右下 3, 左下 4)`
    static func computeFourCornerTargetPoints(from quad: [CGPoint]) -> [CGPoint] {
        guard quad.count == 4 else { return defaultPreviewQuad }
        let uvCoords: [(CGFloat, CGFloat)] = [
            (0.08, 0.08), // 0: 左上角 1
            (0.92, 0.08), // 1: 右上角 2
            (0.92, 0.92), // 2: 右下角 3
            (0.08, 0.92)  // 3: 左下角 4
        ]
        return uvCoords.map { (u, v) in
            let topX = quad[0].x + (quad[1].x - quad[0].x) * u
            let topY = quad[0].y + (quad[1].y - quad[0].y) * u
            let botX = quad[3].x + (quad[2].x - quad[3].x) * u
            let botY = quad[3].y + (quad[2].y - quad[3].y) * u
            return CGPoint(
                x: topX + (botX - topX) * v,
                y: topY + (botY - topY) * v
            )
        }
    }

    // MARK: - Actions & Vision Processing

    private func triggerFocusIndicator(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.15)) {
            focusIndicatorPoint = point
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    focusIndicatorPoint = nil
                }
            }
        }
    }

    @MainActor
    private func handleShutterTap() async {
        // 四角合成防反光模式：第 1 下快門先固定四邊並啟動陀螺儀追蹤；接著移動到四個角分別手動按快門
        if captureMode == .dualGlare {
            if !isPhotoScanSessionActive {
                await startPhotoScanSession()
            } else if let targetCorner = activePhotoScanCornerIndex {
                await capturePhotoScanCorner(index: targetCorner)
            } else {
                await completePhotoScanMultiFrameCapture()
            }
            return
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.08)) {
            isShutterPressed = true
            showCaptureFlash = true
        }
        try? await Task.sleep(nanoseconds: 70_000_000)
        withAnimation(.easeInOut(duration: 0.10)) {
            isShutterPressed = false
            showCaptureFlash = false
        }

        isProcessingCapture = true
        let lockedPreviewQuad = camera.trackedQuadPoints
        let isCapturingBackside = (captureMode == .frontAndBack && pendingFrontImageData != nil)
        guard let packet = await camera.capturePhotoPacket(isBacksideSimulated: isCapturingBackside) else {
            isProcessingCapture = false
            return
        }

        // 先取得原始圖片後立刻結束 loading，讓使用者操作完全不卡頓；裁切與 OCR 改於背景執行
        isProcessingCapture = false
        let now = Date()
        let context = modelContext
        let member = defaultMember

        if captureMode == .frontAndBack {
            if pendingFrontImageData == nil {
                // 第一步：立即記錄正面原圖並解鎖快門，同時在背景預先裁切正面
                pendingFrontImageData = packet.rawData
                pendingOriginalFrontImageData = packet.rawData
                pendingFrontCropTask?.cancel()
                let rawFrontImage = packet.image
                let frontQuad = lockedPreviewQuad
                pendingFrontCropTask = Task {
                    await self.processCapturedImage(
                        rawFrontImage,
                        applyModeASuppression: false,
                        isKnownFrontPhoto: true,
                        priorNormalizedCorners: frontQuad
                    )
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation {
                    statusBannerMessage = L10n.tr(
                        "正面已儲存！請將拍立得翻至背面再按一次快門",
                        "表面を保存しました！チェキを裏返してもう一度シャッターを押してください"
                    )
                }
            } else {
                // 第二步：立即以正反面原圖存入 SwiftData 並解鎖快門，背景完成正反面裁切後自動更新並同步相簿
                let frontRawData = pendingFrontImageData ?? packet.rawData
                let frontOrigData = pendingOriginalFrontImageData ?? frontRawData
                let frontTask = pendingFrontCropTask
                let rawBackImage = packet.image
                let backRawData = packet.rawData
                let backQuad = lockedPreviewQuad

                pendingFrontImageData = nil
                pendingOriginalFrontImageData = nil
                pendingFrontCropTask = nil

                let newItem = ChekiItem(
                    frontImageData: frontRawData,
                    backImageData: backRawData,
                    originalFrontImageData: frontOrigData,
                    originalBackImageData: backRawData,
                    capturedAt: now,
                    ocrDate: nil,
                    filmFormat: .mini,
                    detectedAspectRatio: FilmFormat.mini.aspectRatio,
                    perspectivePointsJSON: nil,
                    backPerspectivePointsJSON: nil,
                    processingState: .detecting,
                    idolMember: member
                )
                context.insert(newItem)
                try? context.save()

                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation {
                    statusBannerMessage = L10n.tr(
                        "正反雙面已儲存！背景自動裁切正位中...",
                        "両面を保存しました！バックグラウンドで自動トリミング中..."
                    )
                }

                Task { @MainActor in
                    let frontResult = await frontTask?.value
                    let (backProcessed, backOriginalRaw, backPointsJSON, backOCRDate, _) = await self.processCapturedImage(
                        rawBackImage,
                        applyModeASuppression: false,
                        isKnownFrontPhoto: false,
                        priorNormalizedCorners: backQuad
                    )
                    guard !newItem.isDeleted, newItem.modelContext != nil else { return }

                    if let frontProcessed = frontResult?.0 {
                        newItem.frontImageData = frontProcessed
                    }
                    if let frontOrig = frontResult?.1 {
                        newItem.originalFrontImageData = frontOrig
                    }
                    newItem.perspectivePointsJSON = frontResult?.2

                    if let backProcessed {
                        newItem.backImageData = backProcessed
                    }
                    if let backOriginalRaw {
                        newItem.originalBackImageData = backOriginalRaw
                    }
                    newItem.backPerspectivePointsJSON = backPointsJSON

                    let format = (frontResult?.4 ?? .mini).concreteFormat
                    newItem.filmFormat = format
                    newItem.detectedAspectRatio = format.aspectRatio

                    if let finalOCR = frontResult?.3 ?? backOCRDate {
                        let captureDate = ChekiItem.mergeRecognizedDate(finalOCR, into: now)
                        newItem.capturedAt = captureDate
                        newItem.ocrDate = captureDate
                    }
                    newItem.processingState = .completed
                    try? context.save()

                    await self.syncCapturedItemToPhotoLibrary(newItem)
                    guard !newItem.isDeleted, newItem.modelContext != nil else { return }
                    withAnimation {
                        self.statusBannerMessage = L10n.tr(
                            "正反雙面拍立得已完成背景裁切並同步至系統相簿！",
                            "両面チェキの自動トリミングと「写真」アプリへの同期が完了しました！"
                        )
                    }
                }
            }
        } else {
            // 單張正面拍攝：先立即存入原始圖片並結束 loading，再於背景執行裁切、OCR 與系統相簿同步
            let rawData = packet.rawData
            let rawImage = packet.image
            let newItem = ChekiItem(
                frontImageData: rawData,
                backImageData: nil,
                originalFrontImageData: rawData,
                capturedAt: now,
                ocrDate: nil,
                filmFormat: .mini,
                detectedAspectRatio: FilmFormat.mini.aspectRatio,
                perspectivePointsJSON: nil,
                processingState: .detecting,
                idolMember: member
            )
            context.insert(newItem)
            try? context.save()

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation {
                statusBannerMessage = L10n.tr(
                    "已儲存照片！背景自動裁切中...",
                    "写真を保存しました！バックグラウンドで自動トリミング中..."
                )
            }

            Task { @MainActor in
                let (processedData, originalRawData, pointsJSON, recognizedDate, resolvedFormat) = await self.processCapturedImage(
                    rawImage,
                    applyModeASuppression: false,
                    isKnownFrontPhoto: true,
                    priorNormalizedCorners: lockedPreviewQuad
                )
                guard !newItem.isDeleted, newItem.modelContext != nil else { return }
                if let processedData {
                    newItem.frontImageData = processedData
                }
                if let originalRawData {
                    newItem.originalFrontImageData = originalRawData
                }
                newItem.perspectivePointsJSON = pointsJSON
                let format = resolvedFormat.concreteFormat
                newItem.filmFormat = format
                newItem.detectedAspectRatio = format.aspectRatio
                if let recognizedDate {
                    let captureDate = ChekiItem.mergeRecognizedDate(recognizedDate, into: now)
                    newItem.capturedAt = captureDate
                    newItem.ocrDate = captureDate
                }
                newItem.processingState = .completed
                try? context.save()

                await self.syncCapturedItemToPhotoLibrary(newItem)
                guard !newItem.isDeleted, newItem.modelContext != nil else { return }
                withAnimation {
                    self.statusBannerMessage = L10n.tr(
                        "已自動正位並存入系統相簿",
                        "自動補正して「写真」アプリに保存しました"
                    )
                }
            }
        }
    }

    /// 啟動四角防反光掃描：拍下第 1 張後立即固定四邊位置、停止 Vision 偵測並啟動陀螺儀追蹤，讓使用者移動到四個角分別按快門
    @MainActor
    private func startPhotoScanSession() async {
        if camera.flashSetting == .off {
            camera.setTorch(enabled: true)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.08)) {
            isShutterPressed = true
            showCaptureFlash = true
        }
        try? await Task.sleep(nanoseconds: 65_000_000)
        withAnimation(.easeInOut(duration: 0.10)) {
            isShutterPressed = false
            showCaptureFlash = false
        }

        isProcessingCapture = true
        // 第一張快門瞬間立即鎖定當前四邊並停止 Vision 偵測，改由陀螺儀移動
        let lockedQuad = camera.lockQuadAndStartGyro()
        guard let packet = await camera.capturePhotoPacket(
            isBacksideSimulated: false,
            simulatedGlareAngleStep: 1
        ) else {
            camera.unlockQuadAndStopGyro()
            isProcessingCapture = false
            return
        }
        isProcessingCapture = false

        let baseImage = packet.image
        photoScanCapturedImages = [baseImage]
        photoScanCapturedQuads = [lockedQuad]
        photoScanCornerCompleted = [false, false, false, false]
        pendingModeBFirstRawJPEG = packet.rawData

        let defaultInsetRatio = UserDefaults.standard.double(forKey: "defaultBorderInsetPercentage") / 100.0

        pendingModeBPreparedTask?.cancel()
        pendingModeBPreparedTask = Task.detached(priority: .utility) {
            let normalized = baseImage.normalizedImage(maxDimension: 2048)
            guard let cgA = normalized.cgImage else { return nil }
            let manager = VisionManager()
            return try? await manager.prepareModeBFirstAngle(
                primaryImage: cgA,
                borderInsetRatio: defaultInsetRatio,
                preferredFormat: .auto,
                priorNormalizedCorners: lockedQuad
            )
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            isPhotoScanSessionActive = true
            statusBannerMessage = L10n.tr(
                "⚡️ 四邊已固定！請移動至【左上 1】角點並按快門 (0/4)",
                "⚡️ 枠を固定しました！【左上 1】に合わせてシャッターを押してください (0/4)"
            )
        }
    }

    /// 手動按快門拍攝指定的第 `index` 個角落 (0:左上, 1:右上, 2:右下, 3:左下)
    @MainActor
    private func capturePhotoScanCorner(index: Int) async {
        guard isPhotoScanSessionActive,
              index >= 0, index < 4,
              !photoScanCornerCompleted[index],
              !isProcessingCapture else { return }

        isProcessingCapture = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.easeInOut(duration: 0.06)) {
            isShutterPressed = true
            showCaptureFlash = true
        }
        try? await Task.sleep(nanoseconds: 55_000_000)
        withAnimation(.easeInOut(duration: 0.09)) {
            isShutterPressed = false
            showCaptureFlash = false
        }

        let lockedQuad = camera.trackedQuadPoints
        guard let packet = await camera.capturePhotoPacket(
            isBacksideSimulated: false,
            simulatedGlareAngleStep: index + 2
        ) else {
            isProcessingCapture = false
            return
        }

        photoScanCapturedImages.append(packet.image)
        photoScanCapturedQuads.append(lockedQuad)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            photoScanCornerCompleted[index] = true
        }
        isProcessingCapture = false

        let doneCount = completedCornerCount
        if doneCount >= 4 {
            await completePhotoScanMultiFrameCapture()
        } else {
            let cornerNames = L10n.isJapanese
                ? ["左上 1", "右上 2", "右下 3", "左下 4"]
                : ["左上 1", "右上 2", "右下 3", "左下 4"]
            let nextIdx = activePhotoScanCornerIndex ?? nextUncapturedCornerIndex ?? 0
            withAnimation {
                statusBannerMessage = L10n.tr(
                    "已拍 \(cornerNames[index]) (\(doneCount)/4)！請移至【\(cornerNames[nextIdx])】按快門",
                    "\(cornerNames[index]) を撮影 (\(doneCount)/4)！次は【\(cornerNames[nextIdx])】でシャッターを押してください"
                )
            }
        }
    }

    /// 四角拍攝完成：立即先將基準原圖存入 SwiftData 並結束 loading，再於背景執行四角防反光合成與相簿同步
    @MainActor
    private func completePhotoScanMultiFrameCapture() async {
        let capturedImages = photoScanCapturedImages
        let capturedQuads = photoScanCapturedQuads
        let preparedTask = pendingModeBPreparedTask
        let cachedRawJPEGA = pendingModeBFirstRawJPEG
        let context = modelContext
        let member = defaultMember

        guard let firstImage = capturedImages.first else {
            resetPhotoScanState()
            return
        }

        // 先行重設四角掃描狀態並解除陀螺儀鎖定，立刻結束 loading 讓畫面零卡頓
        pendingModeBPreparedTask = nil
        pendingModeBFirstRawJPEG = nil
        isPhotoScanSessionActive = false
        photoScanCapturedImages.removeAll()
        photoScanCapturedQuads.removeAll()
        photoScanCornerCompleted = [false, false, false, false]
        camera.unlockQuadAndStopGyro()
        isProcessingCapture = false
        camera.isPausedForProcessing = false

        let now = Date()
        let initialRawData = cachedRawJPEGA ?? firstImage.jpegData(compressionQuality: 0.90)
        let newItem = ChekiItem(
            frontImageData: initialRawData,
            backImageData: nil,
            originalFrontImageData: initialRawData,
            capturedAt: now,
            ocrDate: nil,
            filmFormat: .mini,
            detectedAspectRatio: FilmFormat.mini.aspectRatio,
            perspectivePointsJSON: nil,
            processingState: .detecting,
            idolMember: member
        )
        context.insert(newItem)
        try? context.save()

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation {
            statusBannerMessage = L10n.tr(
                "✨ 已儲存照片！背景正在執行四角防反光合成...",
                "✨ 写真を保存しました！バックグラウンドで四隅の反射除去を合成中..."
            )
        }

        let defaultInsetRatio = UserDefaults.standard.double(forKey: "defaultBorderInsetPercentage") / 100.0

        // 背景非阻塞執行四角合成與裁切，完成後自動更新 ChekiItem 並同步至系統相簿
        Task { @MainActor in
            let preparedFirstAngle = await preparedTask?.value

            let synthesisOutcome: (
                fusedJPEG: Data?,
                rawJPEGA: Data?,
                pointsJSON: String?,
                ocrDate: Date?,
                format: FilmFormat
            )? = await Task.detached(priority: .utility) {
                let normalizedCGs: [CGImage] = capturedImages.compactMap { img in
                    img.normalizedImage(maxDimension: 2048).cgImage
                }
                guard normalizedCGs.count >= 2 else { return nil }
                let manager = VisionManager()
                do {
                    let result = try await manager.synthesizePhotoScanMultiFrameAntiGlare(
                        rawImages: normalizedCGs,
                        priorNormalizedQuads: capturedQuads,
                        borderInsetRatio: defaultInsetRatio,
                        preferredFormat: .auto,
                        preparedFirstAngle: preparedFirstAngle
                    )
                    let fusedJPEG = UIImage(cgImage: result.fusedCGImage).jpegData(compressionQuality: 0.92)
                    let normalizedFirstJPEG = UIImage(cgImage: normalizedCGs[0]).jpegData(compressionQuality: 0.90) ?? initialRawData
                    let imageSizeA = CGSize(width: normalizedCGs[0].width, height: normalizedCGs[0].height)
                    let pointsJSON = ChekiItem.encodeNormalizedCorners(result.primaryDetection.corners, imageSize: imageSizeA)

                    let ocrDate: Date?
                    if let preDate = result.preRecognizedDate {
                        ocrDate = preDate
                    } else {
                        ocrDate = await manager.recognizeDate(from: result.fusedCGImage)?.date
                    }
                    return (fusedJPEG, normalizedFirstJPEG, pointsJSON, ocrDate, result.resolvedFormat.concreteFormat)
                } catch {
                    return nil
                }
            }.value

            guard !newItem.isDeleted, newItem.modelContext != nil else { return }

            if let outcome = synthesisOutcome, let fusedJPEG = outcome.fusedJPEG {
                newItem.frontImageData = fusedJPEG
                if let rawJPEGA = outcome.rawJPEGA {
                    newItem.originalFrontImageData = rawJPEGA
                }
                newItem.perspectivePointsJSON = outcome.pointsJSON
                let format = outcome.format
                newItem.filmFormat = format
                newItem.detectedAspectRatio = format.aspectRatio
                if let ocrDate = outcome.ocrDate {
                    let captureDate = ChekiItem.mergeRecognizedDate(ocrDate, into: now)
                    newItem.capturedAt = captureDate
                    newItem.ocrDate = captureDate
                }
                newItem.processingState = .completed
                try? context.save()

                await self.syncCapturedItemToPhotoLibrary(newItem)
                guard !newItem.isDeleted, newItem.modelContext != nil else { return }
                withAnimation {
                    self.statusBannerMessage = L10n.tr(
                        "✨ 四角去反光合成完成！已同步至系統相簿",
                        "✨ 四隅の反射除去合成が完了し、「写真」アプリに同期しました！"
                    )
                }
            } else {
                let (processedData, originalRawData, pointsJSON, recognizedDate, resolvedFormat) = await self.processCapturedImage(
                    firstImage,
                    applyModeASuppression: true,
                    isKnownFrontPhoto: true,
                    priorNormalizedCorners: capturedQuads.first ?? nil
                )
                guard !newItem.isDeleted, newItem.modelContext != nil else { return }
                if let processedData {
                    newItem.frontImageData = processedData
                }
                if let originalRawData {
                    newItem.originalFrontImageData = originalRawData
                }
                newItem.perspectivePointsJSON = pointsJSON
                let format = resolvedFormat.concreteFormat
                newItem.filmFormat = format
                newItem.detectedAspectRatio = format.aspectRatio
                if let recognizedDate {
                    let captureDate = ChekiItem.mergeRecognizedDate(recognizedDate, into: now)
                    newItem.capturedAt = captureDate
                    newItem.ocrDate = captureDate
                }
                newItem.processingState = .completed
                try? context.save()

                await self.syncCapturedItemToPhotoLibrary(newItem)
                guard !newItem.isDeleted, newItem.modelContext != nil else { return }
                withAnimation {
                    self.statusBannerMessage = L10n.tr(
                        "已透過反光抑制正位並存入系統相簿",
                        "反射抑制・自動補正して「写真」アプリに保存しました"
                    )
                }
            }
        }
    }

    private func processCapturedImage(
        _ image: UIImage,
        applyModeASuppression: Bool = false,
        isKnownFrontPhoto: Bool = true,
        priorNormalizedCorners: [CGPoint]? = nil
    ) async -> (Data?, Data?, String?, Date?, FilmFormat) {
        let defaultInsetRatio = UserDefaults.standard.double(forKey: "defaultBorderInsetPercentage") / 100.0
        return await Task.detached(priority: .utility) {
            let normalized = image.normalizedImage(maxDimension: 2400)
            let rawJPEG = normalized.jpegData(compressionQuality: 0.90)
            guard let cgImage = normalized.cgImage else {
                return (rawJPEG, rawJPEG, nil, nil, .mini)
            }
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let manager = VisionManager()
            do {
                let detection = try await manager.detectQuadFastForCamera(
                    in: cgImage,
                    imageSize: imageSize,
                    isKnownFrontPhoto: isKnownFrontPhoto,
                    priorNormalizedCorners: priorNormalizedCorners
                )
                let adjustedCorners = await manager.applyBorderInset(
                    corners: detection.corners,
                    imageSize: imageSize,
                    ratio: defaultInsetRatio
                )
                let cropResult = try await manager.perspectiveCorrect(
                    image: cgImage,
                    corners: adjustedCorners,
                    detection: detection,
                    format: .auto
                )
                let resolvedFormat = FilmFormat.resolvedConcreteFormat(
                    preferred: .auto,
                    specName: cropResult.filmSpecification?.format.rawValue,
                    outputSize: cropResult.outputSize
                )
                let finalCGImage = applyModeASuppression
                    ? await manager.applyModeAGlareSuppression(to: cropResult.cgImage)
                    : cropResult.cgImage
                let ocrDate = await manager.recognizeDate(from: finalCGImage)?.date
                let jpeg = UIImage(cgImage: finalCGImage).jpegData(compressionQuality: 0.92)
                let pointsJSON = ChekiItem.encodeNormalizedCorners(adjustedCorners, imageSize: imageSize)
                return (jpeg, rawJPEG, pointsJSON, ocrDate, resolvedFormat)
            } catch {
                let ocrDate = await manager.recognizeDate(from: cgImage)?.date
                return (rawJPEG, rawJPEG, nil, ocrDate, .mini)
            }
        }.value
    }

    /// 將相機新拍攝的拍立得自動同步寫入 iOS 原生系統相簿 (`Photos.app`)
    @MainActor
    private func syncCapturedItemToPhotoLibrary(_ item: ChekiItem) async {
        guard item.modelContext != nil, !item.isDeleted else { return }
        let autoSync = (UserDefaults.standard.object(forKey: "autoSyncToPhotosLibrary") as? Bool)
            ?? (UserDefaults.standard.object(forKey: "autoSyncToPhotos") as? Bool)
            ?? true
        guard autoSync else { return }

        let overwriteExif = UserDefaults.standard.object(forKey: "overwriteExifDateWithOCR") as? Bool ?? true
        let useGroupMemberAlbums = UserDefaults.standard.object(forKey: "createGroupMemberAlbumsInPhotos") as? Bool ?? true
        let timelineStrategy = UserDefaults.standard.string(forKey: "backsideTimelineStrategy") ?? BacksideTimelineStrategy.sameSecond.rawValue

        let frontSyncDate = overwriteExif ? item.displayDate : item.capturedAt
        let backSyncDate = (timelineStrategy == BacksideTimelineStrategy.plusOneSecond.rawValue)
            ? frontSyncDate.addingTimeInterval(1.0)
            : frontSyncDate

        let member: IdolMember? = item.idolMember ?? defaultMember
        let albumName = useGroupMemberAlbums ? (member?.albumTitle ?? "ChekiLens") : "ChekiLens"
        let folderName: String? = useGroupMemberAlbums ? member?.group?.name : nil

        // 嘗試取得或建立相簿（即使 album 為 nil，updateOrSaveImage 仍會將照片存入系統相簿「最近項目」）
        let album = try? await PhotoLibraryManager.shared.getOrCreateAlbum(
            albumName: albumName,
            inFolder: folderName
        )
        guard item.modelContext != nil, !item.isDeleted else { return }

        if let frontData = item.frontImageData,
           let frontUIImage = UIImage(data: frontData) {
            if let frontAssetId = try? await PhotoLibraryManager.shared.updateOrSaveImage(
                frontUIImage,
                originalImageData: item.originalFrontImageData,
                existingAssetIdentifier: item.frontAssetIdentifier,
                creationDate: frontSyncDate,
                to: album
            ) {
                guard item.modelContext != nil, !item.isDeleted else {
                    await PhotoLibraryManager.shared.deleteAssetsFromSystemPhotoLibrary(identifiers: [frontAssetId])
                    return
                }
                item.frontAssetIdentifier = frontAssetId
                item.isSyncedToPhotoLibrary = true
                item.isDateWrittenToAlbum = overwriteExif && (item.ocrDate != nil)
            }
        }

        if let backData = item.backImageData,
           let backUIImage = UIImage(data: backData) {
            if let backAssetId = try? await PhotoLibraryManager.shared.updateOrSaveImage(
                backUIImage,
                originalImageData: item.originalBackImageData,
                existingAssetIdentifier: item.backAssetIdentifier,
                creationDate: backSyncDate,
                to: album
            ) {
                guard item.modelContext != nil, !item.isDeleted else {
                    await PhotoLibraryManager.shared.deleteAssetsFromSystemPhotoLibrary(identifiers: [backAssetId])
                    return
                }
                item.backAssetIdentifier = backAssetId
                item.isSyncedToPhotoLibrary = true
            }
        }

        try? modelContext.save()
    }
}

// MARK: - 四角合成防反光：陀螺儀移動四角圓點與中央準星導引 (PhotoScanFourCornerOverlay)

private struct PhotoScanFourCornerOverlay: View {
    let quadPoints: [CGPoint]
    let cornerCompleted: [Bool]
    let activeTargetIndex: Int?
    let onTapCorner: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let normalizedTargets = CameraScannerView.computeFourCornerTargetPoints(from: quadPoints)
            let screenTargets = normalizedTargets.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            let centerPoint = CGPoint(x: w * 0.5, y: h * 0.5)

            ZStack {
                // 1. 中央對準目標方向虛線（由畫面中央指向目前待按下快門的角點圓圈）
                if let activeIdx = activeTargetIndex, activeIdx < screenTargets.count {
                    let targetPt = screenTargets[activeIdx]
                    Path { path in
                        path.move(to: centerPoint)
                        path.addLine(to: targetPt)
                    }
                    .stroke(
                        Color.cyan.opacity(0.75),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [6, 6])
                    )
                }

                // 2. 四個角落目標圓點（隨陀螺儀平滑位移；移動到該角後按底部快門或直接點選圓點即可拍攝）
                ForEach(0..<min(4, screenTargets.count), id: \.self) { idx in
                    let isDone = cornerCompleted[idx]
                    let isCurrentTarget = (activeTargetIndex == idx)

                    Button {
                        if !isDone {
                            onTapCorner(idx)
                        }
                    } label: {
                        ZStack {
                            if isCurrentTarget && !isDone {
                                Circle()
                                    .strokeBorder(Color.cyan, lineWidth: 2.5)
                                    .frame(width: 46, height: 46)
                            }

                            Circle()
                                .fill(isDone ? Color.green : (isCurrentTarget ? Color.cyan : Color.white))
                                .frame(width: 30, height: 30)
                                .shadow(color: .black.opacity(0.45), radius: 5, x: 0, y: 2)

                            if isDone {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(idx + 1)")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.black.opacity(0.85))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .position(screenTargets[idx])
                }

                // 3. 取景器正中央對準圓環（對準角點後手動按下快門）
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.75), lineWidth: 3.0)
                        .frame(width: 58, height: 58)

                    Circle()
                        .fill(Color.cyan.opacity(0.85))
                        .frame(width: 6, height: 6)
                }
                .position(centerPoint)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 3×3 九宮格輔助線 (CameraGridLinesOverlay)

private struct CameraGridLinesOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Path { path in
                // 垂直三分線
                path.move(to: CGPoint(x: w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: w / 3.0, y: h))
                path.move(to: CGPoint(x: w * 2.0 / 3.0, y: 0))
                path.addLine(to: CGPoint(x: w * 2.0 / 3.0, y: h))

                // 水平三分線
                path.move(to: CGPoint(x: 0, y: h / 3.0))
                path.addLine(to: CGPoint(x: w, y: h / 3.0))
                path.move(to: CGPoint(x: 0, y: h * 2.0 / 3.0))
                path.addLine(to: CGPoint(x: w, y: h * 2.0 / 3.0))
            }
            .stroke(Color.white.opacity(0.32), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 拍立得四角虛線與轉角追蹤框 (ChekiQuadTrackingOverlay)

private struct ChekiQuadTrackingOverlay: View {
    let normalizedPoints: [CGPoint]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pts = normalizedPoints.map { CGPoint(x: $0.x * w, y: $0.y * h) }

            ZStack {
                // 綠色/黃色虛線四邊形追蹤框
                Path { path in
                    guard pts.count == 4 else { return }
                    path.move(to: pts[0])
                    path.addLine(to: pts[1])
                    path.addLine(to: pts[2])
                    path.addLine(to: pts[3])
                    path.closeSubpath()
                }
                .stroke(
                    Color.green.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.8, dash: [6, 5])
                )

                // 四個角落高亮錨點
                ForEach(0..<min(pts.count, 4), id: \.self) { idx in
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 8, height: 8)
                        .position(pts[idx])
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Apple 原生相機點擊對焦黃框 (AppleFocusBoxIndicator)

private struct AppleFocusBoxIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .strokeBorder(Color.yellow, lineWidth: 1.5)
                .frame(width: 72, height: 72)

            Image(systemName: "sun.max.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    CameraScannerView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}
