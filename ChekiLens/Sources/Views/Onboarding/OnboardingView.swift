import SwiftUI
import Photos
import AVFoundation

// MARK: - Onboarding Feature Model

private struct OnboardingFeature: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
}

// MARK: - OnboardingView (Task 4.1)

/// Task 4.1: 遵循 Apple Human Interface Guidelines 的 3 頁導引視圖
/// - 採用 SwiftUI 原生 `NavigationStack`、`TabView` + `.page` 樣式、語意化系統色彩（支援深淺色模式與 Dynamic Type）
/// - 第 1 頁：Apple 標準 Welcome Screen 功能總覽
/// - 第 2 頁：86×54mm 自動透視正位與正反面 3D 翻轉互動展示
/// - 第 3 頁：系統相簿與相機權限引導及本機端隱私承諾
struct OnboardingView: View {

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0

    // Page 2 互動展示狀態
    @State private var isFlippedToBack = false
    @State private var isPerspectiveCorrected = true

    // Page 3 權限狀態
    @State private var photoAuthStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var cameraAuthStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    private let totalPages = 3

    private var features: [OnboardingFeature] {
        [
            OnboardingFeature(
                icon: "viewfinder.rectangular",
                iconColor: .blue,
                title: L10n.tr("AI 自動正位", "AI自動補正"),
                description: L10n.tr("自動偵測拍立得四角並還原 86×54mm 比例", "チェキ四隅を検出し86×54mm比率に自動補正")
            ),
            OnboardingFeature(
                icon: "rectangle.portrait.rotate",
                iconColor: .purple,
                title: L10n.tr("正反雙面典藏", "両面デジタル保存"),
                description: L10n.tr("配對正面照片與背面簽名留言，支援 3D 翻轉", "表面写真と裏面メッセージをペア保存・3D反転")
            ),
            OnboardingFeature(
                icon: "text.viewfinder",
                iconColor: .orange,
                title: L10n.tr("手寫日期辨識", "手書き日付OCR"),
                description: L10n.tr("自動辨識手寫日期並寫入相片時間軸", "手書き日付を読み取りEXIF日時へ自動反映")
            ),
            OnboardingFeature(
                icon: "person.2.crop.square.stack.fill",
                iconColor: .green,
                title: L10n.tr("團體與成員分類", "グループ・推し分類"),
                description: L10n.tr("依團體、成員與 #標籤整理專屬相冊", "グループ・メンバー・#タグで整理")
            )
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    welcomeOverviewPage
                        .tag(0)

                    interactiveDemoPage
                        .tag(1)

                    permissionsPage
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                bottomActionSection
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if currentPage < totalPages - 1 {
                        Button(L10n.tr("略過", "スキップ")) {
                            completeOnboarding()
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear {
                refreshPermissionStatuses()
            }
        }
        .applyAppAppearanceAndLocale()
    }

    // MARK: - Page 1: Apple HIG Welcome Overview

    private var welcomeOverviewPage: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 64))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                        .padding(.top, 16)

                    Text(L10n.tr("歡迎使用 ChekiLens", "ChekiLens へようこそ"))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text(L10n.tr("專為偶像拍立得打造的數位典藏工具", "アイドルチェキ専用デジタルアーカイブ"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 22) {
                    ForEach(features) { feature in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: feature.icon)
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(feature.iconColor)
                                .frame(width: 40, height: 40)
                                .background(
                                    feature.iconColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text(feature.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(20)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Page 2: Interactive 3D Flip & Auto-Straightening Demo

    private var interactiveDemoPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(L10n.tr("正反面翻轉與透視正位", "両面反転と自動補正"))
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top, 12)

                    Text(L10n.tr("點擊拍立得體驗 3D 翻轉與正位預覽", "タップで3D反転と自動補正をプレビュー"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // 3D 拍立得預覽卡
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .frame(height: 320)

                    ZStack {
                        if !isFlippedToBack {
                            demoFrontCard
                        } else {
                            demoBackCard
                                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                        }
                    }
                    .rotation3DEffect(
                        .degrees(isFlippedToBack ? 180 : 0),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.6
                    )
                    .rotationEffect(.degrees(isPerspectiveCorrected ? 0 : -7))
                    .scaleEffect(isPerspectiveCorrected ? 1.0 : 0.94)
                    .animation(.spring(response: 0.5, dampingFraction: 0.78), value: isFlippedToBack)
                    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isPerspectiveCorrected)
                    .onTapGesture {
                        isFlippedToBack.toggle()
                    }
                }
                .padding(.horizontal, 20)

                // 互動控制按鈕列
                HStack(spacing: 12) {
                    Button {
                        isFlippedToBack.toggle()
                    } label: {
                        Label(
                            isFlippedToBack ? L10n.tr("正面", "表面") : L10n.tr("背面", "裏面"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button {
                        isPerspectiveCorrected.toggle()
                    } label: {
                        Label(
                            isPerspectiveCorrected ? L10n.tr("已正位", "補正済") : L10n.tr("歪斜原圖", "元画像"),
                            systemImage: isPerspectiveCorrected ? "checkmark.rectangle.portrait.fill" : "crop.rotate"
                        )
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(isPerspectiveCorrected ? .blue : .secondary)
                    .controlSize(.regular)
                }
                .padding(.horizontal, 20)

                // 說明列表
                VStack(alignment: .leading, spacing: 12) {
                    Label(L10n.tr("自動透視校正並裁切背景", "自動台形補正・背景トリミング"), systemImage: "crop")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label(L10n.tr("正反面同秒寫入系統相簿", "表裏を同じ秒数で写真アプリへ保存"), systemImage: "clock.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var demoFrontCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color.blue.opacity(0.75), Color.indigo.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("Hina Kawata")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("2026.10.02")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(12)
            }
            .frame(width: 148, height: 196)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.top, 12)
            .padding(.horizontal, 12)

            HStack {
                Text("日向坂46 · 河田陽菜")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.black.opacity(0.75))
                Spacer()
                Image(systemName: "hand.tap")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 14)
            .frame(width: 172, height: 48)
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 6)
        .overlay {
            if isPerspectiveCorrected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.blue.opacity(0.6), lineWidth: 1.5)
            }
        }
    }

    private var demoBackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("背面備忘", "裏面メモ"), systemImage: "pencil.and.outline")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                Spacer()
                Text("BACK")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("辨識日期", "認識日付"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("2026.10.02")
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("備忘錄", "メモ"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("「今日も来てくれてありがとう！ツアー楽しみにしててね！」")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text(L10n.tr("#全國巡演", "#全国ツアー"))
                Text(L10n.tr("#神對應", "#神対応"))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.blue)
        }
        .padding(14)
        .frame(width: 172, height: 256)
        .background(
            Color(.tertiarySystemBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.45), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 6)
    }

    // MARK: - Page 3: Permissions & Privacy

    private var permissionsPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                        .padding(.top, 16)

                    Text(L10n.tr("權限與隱私", "権限とプライバシー"))
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(L10n.tr("所有辨識與資料皆於本機離線完成，不上傳雲端", "すべての処理は端末内で完結し、外部へ送信されません"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                VStack(spacing: 12) {
                    permissionRow(
                        icon: "photo.on.rectangle.angled",
                        iconColor: .blue,
                        title: L10n.tr("相簿權限", "写真アクセス"),
                        subtitle: L10n.tr("匯入照片並將正反面同步回系統相簿", "写真の読み込みと写真アプリへの同期に使用"),
                        isAuthorized: photoAuthStatus == .authorized || photoAuthStatus == .limited,
                        buttonTitle: photoPermissionButtonTitle,
                        action: requestPhotoPermission
                    )

                    permissionRow(
                        icon: "camera.fill",
                        iconColor: .purple,
                        title: L10n.tr("相機權限", "カメラアクセス"),
                        subtitle: L10n.tr("提供即時邊框預覽與防反光拍攝", "枠プレビューと反射防止撮影に使用"),
                        isAuthorized: cameraAuthStatus == .authorized,
                        buttonTitle: cameraPermissionButtonTitle,
                        action: requestCameraPermission
                    )
                }
                .padding(.horizontal, 20)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("100% 裝置端安全運算", "100% オンデバイス処理"))
                            .font(.subheadline.weight(.semibold))
                        Text(L10n.tr("免註冊帳號，離線安全典藏", "アカウント登録不要・オフラインで安全に保存"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private func permissionRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isAuthorized: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(width: 40, height: 40)
                .background(
                    iconColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if isAuthorized {
                Label(L10n.tr("已允許", "許可済"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    // MARK: - Bottom Action Section

    private var bottomActionSection: some View {
        VStack(spacing: 12) {
            Button {
                if currentPage < totalPages - 1 {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentPage += 1
                    }
                } else {
                    completeOnboarding()
                }
            } label: {
                Text(currentPage < totalPages - 1 ? L10n.tr("繼續", "次へ") : L10n.tr("開始使用", "はじめる"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Actions & Helpers

    private var photoPermissionButtonTitle: String {
        switch photoAuthStatus {
        case .notDetermined:
            return L10n.tr("允許", "許可")
        case .denied, .restricted:
            return L10n.tr("已拒絕", "拒否")
        default:
            return L10n.tr("已允許", "許可済")
        }
    }

    private var cameraPermissionButtonTitle: String {
        switch cameraAuthStatus {
        case .notDetermined:
            return L10n.tr("允許", "許可")
        case .denied, .restricted:
            return L10n.tr("已拒絕", "拒否")
        default:
            return L10n.tr("已允許", "許可済")
        }
    }

    private func refreshPermissionStatuses() {
        photoAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    private func requestPhotoPermission() {
        Task {
            _ = await PhotoLibraryManager.shared.requestAuthorization()
            await MainActor.run {
                photoAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            }
        }
    }

    private func requestCameraPermission() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                cameraAuthStatus = granted ? .authorized : .denied
            }
        }
    }

    private func completeOnboarding() {
        withAnimation(.easeInOut(duration: 0.25)) {
            hasCompletedOnboarding = true
        }
    }
}

#Preview("Light Mode") {
    OnboardingView()
}

#Preview("Dark Mode") {
    OnboardingView()
        .preferredColorScheme(.dark)
}
