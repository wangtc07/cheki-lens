import SwiftUI
import SwiftData
import Combine
@preconcurrency import AVFoundation
import Vision
import UIKit

// MARK: - Camera Capture Mode (仿照 Apple 原生相機底部黃字模式轉盤)

enum ChekiCaptureMode: String, CaseIterable, Identifiable {
    case dualGlare = "防反光"
    case single = "拍照"
    case frontAndBack = "正反雙面"

    var id: String { rawValue }
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
        case .off: return "關閉"
        case .auto: return "自動"
        case .on: return "開啟"
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

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoSampleQueue = DispatchQueue(label: "com.chekilens.camera.videoSampleQueue", qos: .userInteractive)

    @Published var isCameraAvailable: Bool = false
    @Published var isAuthorized: Bool = false
    @Published var isSessionRunning: Bool = false

    /// 畫面正規化座標 (0...1, 原點左上) 的即時追蹤四角 [TL, TR, BR, BL]
    @Published var trackedQuadPoints: [CGPoint]? = nil
    @Published var exposureBias: Float = -0.3
    @Published var zoomFactor: CGFloat = 1.0
    @Published var flashSetting: CameraFlashSetting = .off

    private var videoDevice: AVCaptureDevice?
    private var photoContinuation: CheckedContinuation<UIImage?, Never>?
    nonisolated(unsafe) private var sampleFrameCounter: Int = 0
    nonisolated(unsafe) private var missedQuadFrameCount: Int = 0
    nonisolated(unsafe) var isPausedForProcessing: Bool = false

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
        setTorch(enabled: false)
        guard isSessionRunning else { return }
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        isSessionRunning = false
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

    func capturePhoto(
        isBacksideSimulated: Bool = false,
        simulatedGlareAngleStep: Int = 0
    ) async -> UIImage? {
        guard isCameraAvailable else {
            return makeSimulatedCaptureImage(
                isBackside: isBacksideSimulated,
                glareAngleStep: simulatedGlareAngleStep
            )
        }

        return await withCheckedContinuation { continuation in
            self.photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
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

            // 模擬器下若處於 Google フォトスキャン 四邊閃光拍攝（Step 1~4），在四個不同角落繪製模擬閃光燈強光白斑，
            // 驗證多視角合成後能將四個角落各自的白斑 100% 互補消除。
            if !isBackside && glareAngleStep >= 1 {
                let glareCenter: CGPoint
                switch (glareAngleStep - 1) % 4 {
                case 0: glareCenter = CGPoint(x: 175, y: 185) // 左上強光白斑
                case 1: glareCenter = CGPoint(x: 365, y: 185) // 右上強光白斑
                case 2: glareCenter = CGPoint(x: 365, y: 475) // 右下強光白斑
                default: glareCenter = CGPoint(x: 175, y: 475) // 左下強光白斑
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
        let data = photo.fileDataRepresentation()
        // 在背景執行緒先行完成 12MP 影像方向正規化，避免阻塞 MainActor
        let normalizedImage = data.flatMap { UIImage(data: $0)?.normalizedImage }
        Task { @MainActor in
            self.photoContinuation?.resume(returning: normalizedImage)
            self.photoContinuation = nil
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 當正在處理快門影像合成時暫停即時追蹤，避免與 Vision 搶佔 Neural Engine
        guard !isPausedForProcessing else { return }
        sampleFrameCounter &+= 1
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
                withAnimation(.interpolatingSpring(stiffness: 200, damping: 24)) {
                    self.trackedQuadPoints = points
                }
            }
        } else {
            missedQuadFrameCount &+= 1
            if missedQuadFrameCount >= 8 {
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.trackedQuadPoints = nil
                    }
                }
            }
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

    // 正反雙面連續拍攝狀態（先拍正面 -> 提示翻面 -> 再拍背面）
    @State private var pendingFrontImageData: Data? = nil
    @State private var pendingOriginalFrontImageData: Data? = nil
    @State private var pendingFrontPointsJSON: String? = nil
    @State private var pendingFrontOCRDate: Date? = nil
    @State private var pendingFrontFormat: FilmFormat = .mini

    // Task 5.4 & 6.1: Google フォトスキャン (PhotoScan) 四邊閃光對準去反光連續拍攝狀態
    @State private var isPhotoScanSessionActive: Bool = false
    @State private var photoScanCapturedImages: [UIImage] = []
    @State private var photoScanCapturedQuads: [[CGPoint]?] = []
    @State private var photoScanCornerCompleted: [Bool] = [false, false, false, false]
    @State private var photoScanDwellCornerIndex: Int? = nil
    @State private var photoScanDwellProgress: CGFloat = 0.0
    @State private var pendingModeBFirstRawJPEG: Data? = nil
    @State private var pendingModeBPreparedTask: Task<VisionManager.ModeBPreparedFirstAngle?, Never>? = nil
    @State private var statusBannerMessage: String? = nil

    private let photoScanDwellTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

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
        .onReceive(photoScanDwellTimer) { _ in
            handlePhotoScanAlignmentTick()
        }
        .sheet(isPresented: $showingLatestDetail) {
            if let latest = chekiItems.first {
                NavigationStack {
                    ChekiDetailView(item: latest)
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

    // MARK: - 2. Center 4:3 Viewfinder (3×3 九宮格 + 拍立得追蹤框 + Google フォトスキャン 四角圓點導引 + 倍率切換圈)

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

                // 拍立得虛線追蹤框與四角 L 型錨點
                if let quad = camera.trackedQuadPoints, quad.count == 4 {
                    ChekiQuadTrackingOverlay(normalizedPoints: quad)
                }

                // Google フォトスキャン (PhotoScan) 風格：四邊角點圓圈對準與中央進度環導引
                if captureMode == .dualGlare && isPhotoScanSessionActive {
                    PhotoScanFourCornerOverlay(
                        quadPoints: camera.trackedQuadPoints ?? Self.defaultPreviewQuad,
                        cornerCompleted: photoScanCornerCompleted,
                        activeTargetIndex: nextUncapturedCornerIndex,
                        dwellCornerIndex: photoScanDwellCornerIndex,
                        dwellProgress: photoScanDwellProgress,
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
                    ? "⚡️ 請移動手機將中央圓環對準四邊白點 (\(completedCornerCount)/4) 或按快門"
                    : "⚡️ フォトスキャン防反光：閃光燈已開啟，請按快門開始四邊對準"
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
                        withAnimation(.snappy(duration: 0.22)) {
                            captureMode = mode
                            pendingFrontImageData = nil
                            statusBannerMessage = nil
                        }
                        // 切換至「防反光」時比照 Google フォトスキャン 自動開啟常亮補光燈與閃燈；離開時關閉
                        camera.setTorch(enabled: mode == .dualGlare)
                    } label: {
                        Text(mode.rawValue)
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
                                        Image(systemName: "viewfinder.circle.fill")
                                            .font(.system(size: 18, weight: .bold))
                                        Text("\(completedCornerCount)/4")
                                            .font(.system(size: 10, weight: .heavy, design: .rounded))
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
                            statusBannerMessage = "已重設四邊防反光掃描，請重新按快門開始"
                        }
                    } else if pendingFrontImageData != nil {
                        withAnimation {
                            pendingFrontImageData = nil
                            statusBannerMessage = "已取消背面拍攝，重新拍攝正面"
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

    // MARK: - Google フォトスキャン 四邊圓點對準與自動快門邏輯

    private func resetPhotoScanState() {
        pendingModeBPreparedTask?.cancel()
        pendingModeBPreparedTask = nil
        pendingModeBFirstRawJPEG = nil
        isPhotoScanSessionActive = false
        photoScanCapturedImages.removeAll()
        photoScanCapturedQuads.removeAll()
        photoScanCornerCompleted = [false, false, false, false]
        photoScanDwellCornerIndex = nil
        photoScanDwellProgress = 0.0
    }

    /// 每 0.05 秒檢查取景器中央圓環 `(0.5, 0.5)` 是否已對準拍立得四邊任一尚未拍攝的目標圓點
    @MainActor
    private func handlePhotoScanAlignmentTick() {
        guard captureMode == .dualGlare,
              isPhotoScanSessionActive,
              !isProcessingCapture,
              let quad = camera.trackedQuadPoints,
              quad.count == 4 else {
            photoScanDwellCornerIndex = nil
            photoScanDwellProgress = 0.0
            return
        }

        let targetPoints = Self.computeFourCornerTargetPoints(from: quad)
        let center = CGPoint(x: 0.5, y: 0.5)

        // 找出距離中央對準環最近且尚未拍攝的角點圓點
        var matchedCorner: Int? = nil
        var minDistance: CGFloat = .greatestFiniteMagnitude

        for idx in 0..<4 where !photoScanCornerCompleted[idx] {
            let pt = targetPoints[idx]
            let dist = hypot(pt.x - center.x, pt.y - center.y)
            if dist < minDistance {
                minDistance = dist
                matchedCorner = idx
            }
        }

        // 當中央圓環套入目標圓點 (正規化距離 <= 0.135) 時，累積進度環；約 0.35 秒填滿自動觸發拍攝！
        if let cornerIdx = matchedCorner, minDistance <= 0.135 {
            if photoScanDwellCornerIndex == cornerIdx {
                photoScanDwellProgress = min(1.0, photoScanDwellProgress + 0.15)
                if photoScanDwellProgress >= 1.0 {
                    photoScanDwellProgress = 0.0
                    photoScanDwellCornerIndex = nil
                    Task {
                        await capturePhotoScanCorner(index: cornerIdx)
                    }
                }
            } else {
                photoScanDwellCornerIndex = cornerIdx
                photoScanDwellProgress = 0.15
                UISelectionFeedbackGenerator().selectionChanged()
            }
        } else {
            photoScanDwellCornerIndex = nil
            photoScanDwellProgress = max(0.0, photoScanDwellProgress - 0.20)
        }
    }

    /// 根據拍立得外框四角 `[TL, TR, BR, BL]` 雙線性內插出四個象限目標圓點位置 `(左上, 右上, 右下, 左下)`
    static func computeFourCornerTargetPoints(from quad: [CGPoint]) -> [CGPoint] {
        guard quad.count == 4 else { return defaultPreviewQuad }
        let uvCoords: [(CGFloat, CGFloat)] = [
            (0.25, 0.24), // 0: 左上
            (0.75, 0.24), // 1: 右上
            (0.75, 0.76), // 2: 右下
            (0.25, 0.76)  // 3: 左下
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
        // Google フォトスキャン (PhotoScan) 防反光模式：開啟閃光燈 + 對準四邊角點合成
        if captureMode == .dualGlare {
            if !isPhotoScanSessionActive {
                await startPhotoScanSession()
            } else if let nextCorner = nextUncapturedCornerIndex {
                await capturePhotoScanCorner(index: nextCorner)
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
        try? await Task.sleep(nanoseconds: 90_000_000)
        withAnimation(.easeInOut(duration: 0.12)) {
            isShutterPressed = false
            showCaptureFlash = false
        }

        isProcessingCapture = true
        camera.isPausedForProcessing = true
        let lockedPreviewQuad = camera.trackedQuadPoints
        defer {
            isProcessingCapture = false
            camera.isPausedForProcessing = false
        }

        let isCapturingBackside = (captureMode == .frontAndBack && pendingFrontImageData != nil)
        guard let rawImage = await camera.capturePhoto(isBacksideSimulated: isCapturingBackside) else { return }

        let (processedData, originalRawData, pointsJSON, recognizedDate, resolvedFormat) = await processCapturedImage(
            rawImage,
            applyModeASuppression: false,
            isKnownFrontPhoto: !isCapturingBackside,
            priorNormalizedCorners: lockedPreviewQuad
        )
        let now = Date()

        if captureMode == .frontAndBack {
            if pendingFrontImageData == nil {
                // 第一步：已拍下正面，等待翻面拍背面
                pendingFrontImageData = processedData
                pendingOriginalFrontImageData = originalRawData
                pendingFrontPointsJSON = pointsJSON
                pendingFrontOCRDate = recognizedDate
                pendingFrontFormat = resolvedFormat
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation {
                    statusBannerMessage = "正面已鎖定！請將拍立得翻至背面再按一次快門"
                }
            } else {
                // 第二步：背面拍攝完成，自動配對存入同一張 ChekiItem 並同步寫入 iOS 原生相簿
                let finalOCR = pendingFrontOCRDate ?? recognizedDate
                let captureDate = finalOCR.map { ChekiItem.mergeRecognizedDate($0, into: now) } ?? now
                let format = pendingFrontFormat.concreteFormat
                let newItem = ChekiItem(
                    frontImageData: pendingFrontImageData,
                    backImageData: processedData,
                    originalFrontImageData: pendingOriginalFrontImageData ?? pendingFrontImageData,
                    originalBackImageData: originalRawData ?? processedData,
                    capturedAt: captureDate,
                    ocrDate: finalOCR != nil ? captureDate : nil,
                    filmFormat: format,
                    detectedAspectRatio: format.aspectRatio,
                    perspectivePointsJSON: pendingFrontPointsJSON,
                    backPerspectivePointsJSON: pointsJSON,
                    processingState: .completed,
                    idolMember: defaultMember
                )
                modelContext.insert(newItem)
                try? modelContext.save()

                Task { @MainActor in
                    await syncCapturedItemToPhotoLibrary(newItem)
                }

                pendingFrontImageData = nil
                pendingOriginalFrontImageData = nil
                pendingFrontPointsJSON = nil
                pendingFrontOCRDate = nil
                pendingFrontFormat = .mini
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation {
                    statusBannerMessage = "正反雙面拍立得已配對並同步至系統相簿！"
                }
            }
        } else {
            // 單張正面拍攝完成 -> 存入 SwiftData 並同步寫入 iOS 原生相簿
            let captureDate = recognizedDate.map { ChekiItem.mergeRecognizedDate($0, into: now) } ?? now
            let format = resolvedFormat.concreteFormat
            let newItem = ChekiItem(
                frontImageData: processedData,
                backImageData: nil,
                originalFrontImageData: originalRawData ?? processedData,
                capturedAt: captureDate,
                ocrDate: recognizedDate != nil ? captureDate : nil,
                filmFormat: format,
                detectedAspectRatio: format.aspectRatio,
                perspectivePointsJSON: pointsJSON,
                processingState: .completed,
                idolMember: defaultMember
            )
            modelContext.insert(newItem)
            try? modelContext.save()

            Task { @MainActor in
                await syncCapturedItemToPhotoLibrary(newItem)
            }

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation {
                statusBannerMessage = "已自動正位並存入系統相簿"
            }
        }
    }

    /// 啟動 Google フォトスキャン 四邊閃光掃描：先開啟閃光補光燈並拍下基準框，隨即浮現四個角點圓圈引導
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
        try? await Task.sleep(nanoseconds: 80_000_000)
        withAnimation(.easeInOut(duration: 0.12)) {
            isShutterPressed = false
            showCaptureFlash = false
        }

        isProcessingCapture = true
        let lockedQuad = camera.trackedQuadPoints
        guard let baseImage = await camera.capturePhoto(
            isBacksideSimulated: false,
            simulatedGlareAngleStep: 1
        ) else {
            isProcessingCapture = false
            return
        }
        isProcessingCapture = false

        photoScanCapturedImages = [baseImage]
        photoScanCapturedQuads = [lockedQuad]
        photoScanCornerCompleted = [false, false, false, false]
        photoScanDwellCornerIndex = nil
        photoScanDwellProgress = 0.0

        let defaultInsetRatio = UserDefaults.standard.double(forKey: "defaultBorderInsetPercentage") / 100.0
        let rawCG = baseImage.cgImage
        pendingModeBFirstRawJPEG = nil

        Task.detached(priority: .utility) {
            let jpeg = baseImage.jpegData(compressionQuality: 0.90)
            await MainActor.run {
                self.pendingModeBFirstRawJPEG = jpeg
            }
        }

        pendingModeBPreparedTask?.cancel()
        pendingModeBPreparedTask = Task.detached(priority: .userInitiated) {
            guard let cgA = rawCG else { return nil }
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
            statusBannerMessage = "⚡️ 請移動手機將中央圓環對準 4 個角點圓圈 (0/4)"
        }
    }

    /// 拍攝 Google フォトスキャン 指定的第 `index` 個角落 (0:左上, 1:右上, 2:右下, 3:左下)
    @MainActor
    private func capturePhotoScanCorner(index: Int) async {
        guard isPhotoScanSessionActive,
              index >= 0, index < 4,
              !photoScanCornerCompleted[index],
              !isProcessingCapture else { return }

        isProcessingCapture = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.easeInOut(duration: 0.06)) {
            showCaptureFlash = true
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        withAnimation(.easeInOut(duration: 0.10)) {
            showCaptureFlash = false
        }

        let lockedQuad = camera.trackedQuadPoints
        guard let cornerImage = await camera.capturePhoto(
            isBacksideSimulated: false,
            simulatedGlareAngleStep: index + 2
        ) else {
            isProcessingCapture = false
            return
        }

        photoScanCapturedImages.append(cornerImage)
        photoScanCapturedQuads.append(lockedQuad)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            photoScanCornerCompleted[index] = true
        }
        isProcessingCapture = false

        let doneCount = completedCornerCount
        if doneCount >= 4 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation {
                statusBannerMessage = "✨ 四邊角點 (4/4) 掃描完成！正在執行無反光合成..."
            }
            await completePhotoScanMultiFrameCapture()
        } else {
            let cornerNames = ["左上", "右上", "右下", "左下"]
            let nextIdx = nextUncapturedCornerIndex ?? 0
            withAnimation {
                statusBannerMessage = "已鎖定\(cornerNames[index]) (\(doneCount)/4)！請對準【\(cornerNames[nextIdx])】圓點"
            }
        }
    }

    /// 執行 Google フォトスキャン 多視角無反光合成，並存入 SwiftData 與 iOS 原生相簿
    @MainActor
    private func completePhotoScanMultiFrameCapture() async {
        let capturedImages = photoScanCapturedImages
        let capturedQuads = photoScanCapturedQuads
        let preparedTask = pendingModeBPreparedTask
        let cachedRawJPEGA = pendingModeBFirstRawJPEG

        guard let firstImage = capturedImages.first else {
            resetPhotoScanState()
            return
        }

        isProcessingCapture = true
        camera.isPausedForProcessing = true
        defer {
            isProcessingCapture = false
            camera.isPausedForProcessing = false
            resetPhotoScanState()
        }

        let cgImages = capturedImages.compactMap(\.cgImage)
        guard cgImages.count >= 2 else { return }

        let defaultInsetRatio = UserDefaults.standard.double(forKey: "defaultBorderInsetPercentage") / 100.0
        let now = Date()
        let preparedFirstAngle = await preparedTask?.value

        let synthesisOutcome: (
            fusedJPEG: Data?,
            rawJPEGA: Data?,
            pointsJSON: String?,
            ocrDate: Date?,
            format: FilmFormat
        )? = await Task.detached(priority: .userInitiated) {
            let manager = VisionManager()
            do {
                let result = try await manager.synthesizePhotoScanMultiFrameAntiGlare(
                    rawImages: cgImages,
                    priorNormalizedQuads: capturedQuads,
                    borderInsetRatio: defaultInsetRatio,
                    preferredFormat: .auto,
                    preparedFirstAngle: preparedFirstAngle
                )
                let fusedJPEG = UIImage(cgImage: result.fusedCGImage).jpegData(compressionQuality: 0.92)
                let rawJPEGA = cachedRawJPEGA ?? firstImage.jpegData(compressionQuality: 0.90)
                let imageSizeA = CGSize(width: cgImages[0].width, height: cgImages[0].height)
                let pointsJSON = ChekiItem.encodeNormalizedCorners(result.primaryDetection.corners, imageSize: imageSizeA)

                let ocrDate: Date?
                if let preDate = result.preRecognizedDate {
                    ocrDate = preDate
                } else {
                    ocrDate = await manager.recognizeDate(from: result.fusedCGImage)?.date
                }
                return (fusedJPEG, rawJPEGA, pointsJSON, ocrDate, result.resolvedFormat.concreteFormat)
            } catch {
                return nil
            }
        }.value

        if let outcome = synthesisOutcome, let fusedJPEG = outcome.fusedJPEG {
            let captureDate = outcome.ocrDate.map { ChekiItem.mergeRecognizedDate($0, into: now) } ?? now
            let format = outcome.format
            let newItem = ChekiItem(
                frontImageData: fusedJPEG,
                backImageData: nil,
                originalFrontImageData: outcome.rawJPEGA ?? fusedJPEG,
                capturedAt: captureDate,
                ocrDate: outcome.ocrDate != nil ? captureDate : nil,
                filmFormat: format,
                detectedAspectRatio: format.aspectRatio,
                perspectivePointsJSON: outcome.pointsJSON,
                processingState: .completed,
                idolMember: defaultMember
            )
            modelContext.insert(newItem)
            try? modelContext.save()

            Task { @MainActor in
                await syncCapturedItemToPhotoLibrary(newItem)
            }

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation {
                statusBannerMessage = "✨ フォトスキャン四邊去反光合成完成！已同步至系統相簿"
            }
        } else {
            let (processedData, originalRawData, pointsJSON, recognizedDate, resolvedFormat) = await processCapturedImage(
                firstImage,
                applyModeASuppression: true,
                isKnownFrontPhoto: true,
                priorNormalizedCorners: capturedQuads.first ?? nil
            )
            let captureDate = recognizedDate.map { ChekiItem.mergeRecognizedDate($0, into: now) } ?? now
            let format = resolvedFormat.concreteFormat
            let newItem = ChekiItem(
                frontImageData: processedData,
                backImageData: nil,
                originalFrontImageData: originalRawData ?? processedData,
                capturedAt: captureDate,
                ocrDate: recognizedDate != nil ? captureDate : nil,
                filmFormat: format,
                detectedAspectRatio: format.aspectRatio,
                perspectivePointsJSON: pointsJSON,
                processingState: .completed,
                idolMember: defaultMember
            )
            modelContext.insert(newItem)
            try? modelContext.save()

            Task { @MainActor in
                await syncCapturedItemToPhotoLibrary(newItem)
            }

            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation {
                statusBannerMessage = "已透過反光抑制正位並存入系統相簿"
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
        return await Task.detached(priority: .userInitiated) {
            let normalized = image.normalizedImage
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
        let albumName = useGroupMemberAlbums ? (member?.stageName ?? "ChekiLens") : "ChekiLens"
        let folderName: String? = useGroupMemberAlbums ? member?.group?.name : nil

        // 嘗試取得或建立相簿（即使 album 為 nil，updateOrSaveImage 仍會將照片存入系統相簿「最近項目」）
        let album = try? await PhotoLibraryManager.shared.getOrCreateAlbum(
            albumName: albumName,
            inFolder: folderName
        )

        if let frontData = item.frontImageData,
           let frontUIImage = UIImage(data: frontData) {
            if let frontAssetId = try? await PhotoLibraryManager.shared.updateOrSaveImage(
                frontUIImage,
                originalImageData: item.originalFrontImageData,
                existingAssetIdentifier: item.frontAssetIdentifier,
                creationDate: frontSyncDate,
                to: album
            ) {
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
                item.backAssetIdentifier = backAssetId
                item.isSyncedToPhotoLibrary = true
            }
        }

        try? modelContext.save()
    }
}

// MARK: - Google フォトスキャン 四邊角點圓圈對準與中央進度環 (PhotoScanFourCornerOverlay)

private struct PhotoScanFourCornerOverlay: View {
    let quadPoints: [CGPoint]
    let cornerCompleted: [Bool]
    let activeTargetIndex: Int?
    let dwellCornerIndex: Int?
    let dwellProgress: CGFloat
    let onTapCorner: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let normalizedTargets = CameraScannerView.computeFourCornerTargetPoints(from: quadPoints)
            let screenTargets = normalizedTargets.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            let centerPoint = CGPoint(x: w * 0.5, y: h * 0.5)

            ZStack {
                // 1. 中央對準目標方向虛線（由畫面中央指向下一個待拍攝的角點圓圈）
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

                // 2. 四個角落目標圓點（仿照 Google フォトスキャン 白色實心圓點 -> 完成後變為綠色打勾圓點；也支援直接點擊觸發該角拍攝）
                ForEach(0..<min(4, screenTargets.count), id: \.self) { idx in
                    let isDone = cornerCompleted[idx]
                    let isCurrentTarget = (activeTargetIndex == idx)
                    let isDwelling = (dwellCornerIndex == idx)

                    Button {
                        if !isDone {
                            onTapCorner(idx)
                        }
                    } label: {
                        ZStack {
                            if isCurrentTarget && !isDone {
                                Circle()
                                    .strokeBorder(Color.cyan.opacity(0.85), lineWidth: 2.5)
                                    .frame(width: 44, height: 44)
                            }

                            Circle()
                                .fill(isDone ? Color.green : (isDwelling ? Color.cyan : Color.white))
                                .frame(width: 28, height: 28)
                                .shadow(color: .black.opacity(0.45), radius: 5, x: 0, y: 2)

                            if isDone {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(idx + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.black.opacity(0.75))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .position(screenTargets[idx])
                }

                // 3. 取景器正中央 Google フォトスキャン 空心對準圓環 + 自動快門進度弧
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.65), lineWidth: 3.0)
                        .frame(width: 58, height: 58)

                    if dwellProgress > 0.01 {
                        Circle()
                            .trim(from: 0, to: dwellProgress)
                            .stroke(
                                Color.cyan,
                                style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 58, height: 58)
                    }
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
