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
    private var frameCounter: Int = 0

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
        guard isSessionRunning else { return }
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        isSessionRunning = false
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

    func capturePhoto(isBacksideSimulated: Bool = false) async -> UIImage? {
        guard isCameraAvailable else {
            return makeSimulatedCaptureImage(isBackside: isBacksideSimulated)
        }

        return await withCheckedContinuation { continuation in
            self.photoContinuation = continuation
            let settings = AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(flashSetting.avFlashMode) {
                settings.flashMode = flashSetting.avFlashMode
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func makeSimulatedCaptureImage(isBackside: Bool) -> UIImage? {
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
        Task { @MainActor in
            let image = data.flatMap { UIImage(data: $0)?.normalizedImage }
            self.photoContinuation?.resume(returning: image)
            self.photoContinuation = nil
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.45
        request.maximumAspectRatio = 0.95
        request.minimumSize = 0.20
        request.maximumObservations = 1
        request.minimumConfidence = 0.65

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])

        if let rect = request.results?.first {
            // Vision 原點在左下，轉換為 UIKit/SwiftUI 原點在左上 (y = 1 - y)
            let points = [
                CGPoint(x: rect.topLeft.x, y: 1.0 - rect.topLeft.y),
                CGPoint(x: rect.topRight.x, y: 1.0 - rect.topRight.y),
                CGPoint(x: rect.bottomRight.x, y: 1.0 - rect.bottomRight.y),
                CGPoint(x: rect.bottomLeft.x, y: 1.0 - rect.bottomLeft.y)
            ]
            Task { @MainActor in
                withAnimation(.interpolatingSpring(stiffness: 180, damping: 22)) {
                    self.trackedQuadPoints = points
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

    // 正反雙面連續拍攝狀態（先拍正面 -> 提示翻面 -> 再拍背面）
    @State private var pendingFrontImageData: Data? = nil
    @State private var pendingOriginalFrontImageData: Data? = nil
    @State private var pendingFrontPointsJSON: String? = nil
    @State private var pendingFrontOCRDate: Date? = nil
    @State private var pendingFrontFormat: FilmFormat = .mini
    @State private var statusBannerMessage: String? = nil

    // 點擊對焦黃框狀態
    @State private var focusIndicatorPoint: CGPoint? = nil
    @State private var showingLatestDetail: Bool = false

    private let zoomPresets: [CGFloat] = [0.5, 1.0, 2.0]

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
        }
        .onDisappear {
            camera.stop()
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
            // 左側：閃光燈切換
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                camera.flashSetting = camera.flashSetting.next()
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

    // MARK: - 2. Center 4:3 Viewfinder (3×3 九宮格 + 拍立得追蹤框 + 點擊對焦框 + 倍率切換圈)

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

                // 點擊對焦黃色方框 + 太陽圖示（Apple 原生相機對焦指示）
                if let focusPoint = focusIndicatorPoint {
                    AppleFocusBoxIndicator()
                        .position(focusPoint)
                        .transition(.scale(scale: 1.25).combined(with: .opacity))
                }

                // 頂部拍攝狀態提示膠囊（例如正反雙面模式下提示「步驟 1/2：請拍攝正面」）
                VStack {
                    statusPillBanner
                        .padding(.top, 14)

                    Spacer()

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
                .background(Color.yellow, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
        } else if captureMode == .frontAndBack {
            Text(pendingFrontImageData == nil ? "正反雙面 (1/2)：請對準拍立得【正面】" : "正反雙面 (2/2)：請翻面拍攝【背面手寫】")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.yellow, in: Capsule())
        } else if captureMode == .dualGlare {
            Text("防反光模式：微調角度避開眩光")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
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
        VStack(spacing: 18) {
            // 橫向黃字模式選擇列（仿照 Apple 原生相機：防反光 / 拍照 / 正反雙面）
            HStack(spacing: 28) {
                ForEach(ChekiCaptureMode.allCases) { mode in
                    let isSelected = (captureMode == mode)
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.snappy(duration: 0.22)) {
                            captureMode = mode
                            pendingFrontImageData = nil
                            statusBannerMessage = nil
                        }
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
                            .fill(pendingFrontImageData != nil ? Color.yellow : Color.white)
                            .frame(width: 62, height: 62)
                            .scaleEffect(isShutterPressed ? 0.88 : 1.0)
                            .overlay {
                                if isProcessingCapture {
                                    ProgressView()
                                        .tint(.black)
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

                // 右下：模式切換 / 重設雙面狀態圓鈕
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if pendingFrontImageData != nil {
                        withAnimation {
                            pendingFrontImageData = nil
                            statusBannerMessage = "已取消背面拍攝，重新拍攝正面"
                        }
                    } else {
                        withAnimation(.snappy(duration: 0.22)) {
                            captureMode = (captureMode == .single) ? .frontAndBack : .single
                        }
                    }
                } label: {
                    Image(systemName: pendingFrontImageData != nil ? "arrow.counterclockwise" : "rectangle.portrait.rotate")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(captureMode == .frontAndBack ? .yellow : .white)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切換正反雙面拍攝模式")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 22)
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
        defer { isProcessingCapture = false }

        let isCapturingBackside = (captureMode == .frontAndBack && pendingFrontImageData != nil)
        guard let rawImage = await camera.capturePhoto(isBacksideSimulated: isCapturingBackside) else { return }

        let (processedData, originalRawData, pointsJSON, recognizedDate, resolvedFormat) = await processCapturedImage(rawImage)
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
                // 第二步：背面拍攝完成，自動配對存入同一張 ChekiItem
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

                pendingFrontImageData = nil
                pendingOriginalFrontImageData = nil
                pendingFrontPointsJSON = nil
                pendingFrontOCRDate = nil
                pendingFrontFormat = .mini
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation {
                    statusBannerMessage = "正反雙面拍立得已配對典藏！"
                }
            }
        } else {
            // 單張正面拍攝完成
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

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation {
                statusBannerMessage = "已自動正位並存入典藏"
            }
        }
    }

    private func processCapturedImage(_ image: UIImage) async -> (Data?, Data?, String?, Date?, FilmFormat) {
        let normalized = image.normalizedImage
        let rawJPEG = normalized.jpegData(compressionQuality: 0.92)
        guard let cgImage = normalized.cgImage else {
            return (rawJPEG, rawJPEG, nil, nil, .mini)
        }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let defaultInsetRatio = UserDefaults.standard.double(forKey: "defaultBorderInsetPercentage") / 100.0
        let manager = VisionManager()
        do {
            let detection = try await manager.detectQuad(in: cgImage, imageSize: imageSize)
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
            var ocrDate = await manager.recognizeDate(from: cropResult.cgImage)?.date
            if ocrDate == nil {
                ocrDate = await manager.recognizeDate(from: cgImage)?.date
            }
            let jpeg = UIImage(cgImage: cropResult.cgImage).jpegData(compressionQuality: 0.92)
            let pointsJSON = ChekiItem.encodeNormalizedCorners(adjustedCorners, imageSize: imageSize)
            return (jpeg, rawJPEG, pointsJSON, ocrDate, resolvedFormat)
        } catch {
            let ocrDate = await manager.recognizeDate(from: cgImage)?.date
            return (rawJPEG, rawJPEG, nil, ocrDate, .mini)
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
