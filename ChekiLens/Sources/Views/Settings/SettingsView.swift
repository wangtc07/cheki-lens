import SwiftUI
import SwiftData
import StoreKit

// MARK: - 設定選項列舉定義 (Task 4.7)

/// 正反面寫入 iOS 系統相簿時的時間軸排序策略
enum BacksideTimelineStrategy: String, CaseIterable, Identifiable {
    case sameSecond = "sameSecond"
    case plusOneSecond = "plusOneSecond"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sameSecond:
            return L10n.tr("同一秒", "同じ秒")
        case .plusOneSecond:
            return L10n.tr("背面 +1 秒", "裏面 +1 秒")
        }
    }

    var shortLabel: String {
        displayName
    }
}

/// 手寫日期缺少年份（如僅寫 9/17）時的預設年份補全策略
enum OCRMissingYearStrategy: String, CaseIterable, Identifiable {
    case importYear = "importYear"
    case exifYear = "exifYear"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .importYear:
            return L10n.tr("匯入當年", "取り込み年")
        case .exifYear:
            return L10n.tr("EXIF 拍攝年", "EXIF 撮影年")
        }
    }
}

/// 照片儲存格式模式
enum PhotoStorageMode: String, CaseIterable, Identifiable {
    case keepOriginal = "keepOriginal"
    case convertFormat = "convertFormat"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepOriginal:
            return L10n.tr("原圖格式", "元のフォーマット")
        case .convertFormat:
            return L10n.tr("指定格式", "指定フォーマット")
        }
    }
}

/// 輸出與典藏影像格式
enum PreferredExportImageFormat: String, CaseIterable, Identifiable {
    case original = "original"
    case heic = "heic"
    case jpeg = "jpeg"
    case png = "png"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            return L10n.tr("原圖", "オリジナル")
        case .heic:
            return "HEIC"
        case .jpeg:
            return "JPEG"
        case .png:
            return "PNG"
        }
    }
}

/// 反光對策模式
enum AntiReflectionMode: String, CaseIterable, Identifiable {
    case modeA = "modeA"
    case modeB = "modeB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modeA:
            return L10n.tr("單張抑制", "単枚抑制")
        case .modeB:
            return L10n.tr("雙角度合成 · Pro", "2角度合成 · Pro")
        }
    }

    var shortLabel: String {
        switch self {
        case .modeA:
            return L10n.tr("單張", "単枚")
        case .modeB:
            return L10n.tr("雙角度 · Pro", "2角度 · Pro")
        }
    }
}

/// App 外觀模式
enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case dark = "dark"
    case light = "light"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return L10n.tr("跟隨系統", "システム")
        case .dark:
            return L10n.tr("深色", "ダーク")
        case .light:
            return L10n.tr("淺色", "ライト")
        }
    }

    var resolvedColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }
}

// MARK: - SettingsView (Task 4.7: 07. 設定與 Pro 買斷)
/// 遵循 Apple iOS 18+ 原生「設定」Inset Grouped 視覺規範：
/// - 頂部 `ChekiLens Pro` 終身買斷尊爵橫幅卡片（NT$120 / ¥600 永久解鎖）
/// - 5 大圓角卡片群組 + 左側彩色圓角方塊 SF Symbol 圖示 + 右側原生控制項
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var allChekiItems: [ChekiItem]

    // MARK: Pro 買斷狀態與每日免費額度 (與 Phase 5 StoreKitManager 雙向綁定)
    @AppStorage("isProLifetimeUnlocked") private var isProLifetimeUnlocked: Bool = false
    @AppStorage("dailyFreeQuotaUsedCount") private var dailyFreeQuotaUsedCount: Int = 0

    // MARK: 第 1 組：相簿雙向同步與時間軸策略
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = true
    @AppStorage("createGroupMemberAlbumsInPhotos") private var createGroupMemberAlbums: Bool = true
    @AppStorage("overwriteExifDateWithOCR") private var overwriteExifDateWithOCR: Bool = true
    @AppStorage("backsideTimelineStrategy") private var backsideTimelineStrategyRaw: String = BacksideTimelineStrategy.sameSecond.rawValue

    // MARK: 第 2 組：匯入與 OCR 手寫日期辨識偏好
    @AppStorage("autoRecognizeOCRDateOnImport") private var autoRecognizeOCRDateOnImport: Bool = true
    @AppStorage("ocrMissingYearStrategy") private var ocrMissingYearStrategyRaw: String = OCRMissingYearStrategy.importYear.rawValue

    // MARK: 第 3 組：照片儲存格式偏好
    @AppStorage("photoStorageMode") private var photoStorageModeRaw: String = PhotoStorageMode.keepOriginal.rawValue
    @AppStorage("preferredExportImageFormat") private var preferredExportImageFormatRaw: String = PreferredExportImageFormat.original.rawValue

    // MARK: 第 4 組：相機與影像處理偏好
    @AppStorage("defaultFilmFormatRaw") private var defaultFilmFormatRaw: String = FilmFormat.auto.rawValue
    @AppStorage("defaultBorderInsetPercentage") private var defaultBorderInsetPercentage: Double = 0.0
    @AppStorage("antiReflectionMode") private var antiReflectionModeRaw: String = AntiReflectionMode.modeA.rawValue

    // MARK: 第 5 組：一般與關於
    @AppStorage("appLanguageMode") private var appLanguageModeRaw: String = AppLanguageMode.system.rawValue
    @AppStorage("appAppearanceMode") private var appAppearanceModeRaw: String = AppAppearanceMode.system.rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage("hasSeenBatchPairingCoachMark") private var hasSeenBatchPairingCoachMark: Bool = false
    @AppStorage("hasSeenDetailCoachMark") private var hasSeenDetailCoachMark: Bool = false

    @State private var showingProPurchaseSheet: Bool = false
    @State private var isRestoringPurchases: Bool = false
    @State private var isSyncingAlbumsToPhotos: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String? = nil

    private var appVersionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(shortVersion) · \(buildNumber)"
    }

    var body: some View {
        NavigationStack {
            List {
                // 0. 頂部：ChekiLens Pro 終身買斷尊爵橫幅卡片（解鎖後不顯示）
                if !isProLifetimeUnlocked {
                    Section {
                        proLifetimeBannerCard
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                }

                // 1. 第 1 組：相簿雙向同步與時間軸策略 (Photos Sync & Timeline)
                Section {
                    Toggle(isOn: $autoSyncToPhotos) {
                        SettingsRowLabel(
                            title: L10n.tr("同步至系統相簿", "写真アプリと同期"),
                            subtitle: isProLifetimeUnlocked
                                ? L10n.tr("Pro · 原地裁切", "Pro · 直接トリミング")
                                : L10n.tr("免費版 · 保留未裁切原圖", "無料版 · 元画像を保持"),
                            systemImage: "photo.on.rectangle.angled",
                            iconColor: .blue
                        )
                    }

                    Toggle(isOn: $createGroupMemberAlbums) {
                        SettingsRowLabel(
                            title: L10n.tr("團體 / 成員相簿階層", "グループ / メンバー階層"),
                            subtitle: nil,
                            systemImage: "folder.fill",
                            iconColor: .green
                        )
                    }
                    .disabled(!autoSyncToPhotos)

                    Toggle(isOn: $overwriteExifDateWithOCR) {
                        SettingsRowLabel(
                            title: L10n.tr("手寫日期覆寫時間軸", "手書き日付で日時を上書き"),
                            subtitle: nil,
                            systemImage: "clock.badge.checkmark.fill",
                            iconColor: .orange
                        )
                    }

                    Picker(selection: $backsideTimelineStrategyRaw) {
                        ForEach(BacksideTimelineStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: L10n.tr("正反面排序", "表裏の並び順"),
                            subtitle: nil,
                            systemImage: "arrow.left.arrow.right.square.fill",
                            iconColor: .indigo
                        )
                    }
                } header: {
                    Text(L10n.tr("系統相簿同步", "システムアルバム同期"))
                } footer: {
                    Text(
                        isProLifetimeUnlocked
                            ? L10n.tr("Pro 支援非破壞性原地修改系統相簿原圖並可隨時復原。", "Pro は写真アプリの元画像を非破壊で直接更新し、いつでも復元できます。")
                            : L10n.tr("免費版同步相簿分類與時間軸，系統相簿保留未裁切原圖。", "無料版はアルバムと日時のみ同期し、写真アプリには元画像を保持します。")
                    )
                }

                // 2. 第 2 組：匯入與 OCR 手寫日期辨識偏好 (Import & Recognition)
                Section {
                    Toggle(isOn: $autoRecognizeOCRDateOnImport) {
                        SettingsRowLabel(
                            title: L10n.tr("自動辨識手寫日期", "手書き日付を自動認識"),
                            subtitle: nil,
                            systemImage: "text.viewfinder",
                            iconColor: .purple
                        )
                    }

                    Picker(selection: $ocrMissingYearStrategyRaw) {
                        ForEach(OCRMissingYearStrategy.allCases) { rule in
                            Text(rule.displayName).tag(rule.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: L10n.tr("缺少年份補全", "年号なしの補完"),
                            subtitle: nil,
                            systemImage: "calendar.badge.clock",
                            iconColor: .teal
                        )
                    }
                    .disabled(!autoRecognizeOCRDateOnImport)
                } header: {
                    Text(L10n.tr("手寫日期辨識", "手書き日付認識"))
                }

                // 3. 第 3 組：照片儲存格式偏好 (Storage & Export Format)
                Section {
                    Picker(selection: $photoStorageModeRaw) {
                        ForEach(PhotoStorageMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "儲存模式",
                            subtitle: nil,
                            systemImage: "internaldrive.fill",
                            iconColor: .cyan
                        )
                    }
                    .onChange(of: photoStorageModeRaw) { _, newMode in
                        if newMode == PhotoStorageMode.keepOriginal.rawValue {
                            preferredExportImageFormatRaw = PreferredExportImageFormat.original.rawValue
                        } else if preferredExportImageFormatRaw == PreferredExportImageFormat.original.rawValue {
                            preferredExportImageFormatRaw = PreferredExportImageFormat.heic.rawValue
                        }
                    }

                    Picker(selection: $preferredExportImageFormatRaw) {
                        ForEach(PreferredExportImageFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: L10n.tr("輸出格式", "出力フォーマット"),
                            subtitle: nil,
                            systemImage: "doc.zipper",
                            iconColor: .blue
                        )
                    }
                    .onChange(of: preferredExportImageFormatRaw) { _, newFormat in
                        if newFormat == PreferredExportImageFormat.original.rawValue {
                            photoStorageModeRaw = PhotoStorageMode.keepOriginal.rawValue
                        } else {
                            photoStorageModeRaw = PhotoStorageMode.convertFormat.rawValue
                        }
                    }
                } header: {
                    Text(L10n.tr("儲存與輸出", "保存と出力"))
                }

                // 4. 第 4 組：相機與影像處理偏好 (Scan & Image Processing)
                Section {
                    Picker(selection: $defaultFilmFormatRaw) {
                        ForEach(FilmFormat.allCases, id: \.rawValue) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: L10n.tr("預設相紙", "デフォルト用紙"),
                            subtitle: nil,
                            systemImage: "aspectratio.fill",
                            iconColor: .indigo
                        )
                    }

                    // 自動邊界微調滑桿與快速預設
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SettingsRowLabel(
                                title: L10n.tr("邊界微調", "余白微調整"),
                                subtitle: nil,
                                systemImage: "crop",
                                iconColor: .orange
                            )
                            Spacer()
                            Text(String(format: "%+.1f%%", defaultBorderInsetPercentage))
                                .font(.subheadline.monospacedDigit().weight(.bold))
                                .foregroundStyle(abs(defaultBorderInsetPercentage) > 0.05 ? .blue : .secondary)
                        }

                        Slider(value: $defaultBorderInsetPercentage, in: -3.0...3.0, step: 0.5)
                            .tint(.blue)

                        HStack(spacing: 8) {
                            borderPresetButton(title: "-2%", targetValue: -2.0)
                            borderPresetButton(title: "0%", targetValue: 0.0)
                            borderPresetButton(title: "+2%", targetValue: 2.0)
                        }
                    }
                    .padding(.vertical, 4)

                    Picker(selection: $antiReflectionModeRaw) {
                        ForEach(AntiReflectionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: L10n.tr("去反光模式", "反射抑制モード"),
                            subtitle: nil,
                            systemImage: "sun.max.fill",
                            iconColor: .pink
                        )
                    }
                    .onChange(of: antiReflectionModeRaw) { _, newValue in
                        if newValue == AntiReflectionMode.modeB.rawValue && !isProLifetimeUnlocked {
                            showingProPurchaseSheet = true
                        }
                    }
                } header: {
                    Text(L10n.tr("掃描與影像", "スキャンと画像"))
                } footer: {
                    Text(L10n.tr("負值內縮去黑邊，正值外擴保留白邊。", "負の値で黒縁を除去、正の値で白枠を保持します。"))
                }

                // 5. 第 5 組：一般與關於 (General & About)
                Section {
                    Picker(selection: $appLanguageModeRaw) {
                        ForEach(AppLanguageMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "語言",
                            subtitle: nil,
                            systemImage: "globe",
                            iconColor: .teal
                        )
                    }

                    Picker(selection: $appAppearanceModeRaw) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: L10n.tr("外觀", "外観"),
                            subtitle: nil,
                            systemImage: "circle.lefthalf.filled",
                            iconColor: .gray
                        )
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        hasSeenBatchPairingCoachMark = false
                        hasSeenDetailCoachMark = false
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            hasCompletedOnboarding = false
                        }
                    } label: {
                        HStack {
                            SettingsRowLabel(
                                title: L10n.tr("顯示歡迎與操作提示", "ガイドとヒントを再表示"),
                                subtitle: nil,
                                systemImage: "sparkles",
                                iconColor: .blue
                            )
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await restorePurchases()
                        }
                    } label: {
                        HStack {
                            SettingsRowLabel(
                                title: L10n.tr("恢復購買", "購入を復元"),
                                subtitle: nil,
                                systemImage: "arrow.clockwise.circle.fill",
                                iconColor: .green
                            )
                            Spacer()
                            if isRestoringPurchases {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRestoringPurchases)

                    HStack {
                        SettingsRowLabel(
                            title: "版本",
                            subtitle: nil,
                            systemImage: "info.circle.fill",
                            iconColor: .secondary
                        )
                        Spacer()
                        Text(appVersionString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    #if DEBUG
                    if isProLifetimeUnlocked {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            StoreKitManager.shared.setProUnlocked(false)
                            isProLifetimeUnlocked = false
                        } label: {
                            HStack {
                                SettingsRowLabel(
                                    title: L10n.tr("切換回免費版 · 測試", "無料版に戻す · テスト"),
                                    subtitle: nil,
                                    systemImage: "hammer.fill",
                                    iconColor: .purple
                                )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    #endif
                } header: {
                    Text(L10n.tr("一般", "一般"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingProPurchaseSheet) {
                ProLifetimePaywallSheet(
                    isProUnlocked: $isProLifetimeUnlocked,
                    onRestorePurchases: {
                        await restorePurchases()
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .applyAppAppearanceAndLocale()
            }
            .alert(
                alertTitle,
                isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {
                    alertMessage = nil
                }
            } message: {
                Text(alertMessage ?? "")
            }
            .task {
                await StoreKitManager.shared.initializeStore()
            }
            .onChange(of: autoSyncToPhotos) { _, isEnabled in
                guard isEnabled else { return }
                Task {
                    await syncAllItemsToPhotosLibrary(onlyAlbumAndDateIfAlreadySynced: false)
                }
            }
            .onChange(of: createGroupMemberAlbums) { _, _ in
                guard autoSyncToPhotos else { return }
                Task {
                    await syncAllItemsToPhotosLibrary(onlyAlbumAndDateIfAlreadySynced: true)
                }
            }
            .onChange(of: overwriteExifDateWithOCR) { _, _ in
                guard autoSyncToPhotos else { return }
                Task {
                    await syncAllItemsToPhotosLibrary(onlyAlbumAndDateIfAlreadySynced: true)
                }
            }
            .onChange(of: backsideTimelineStrategyRaw) { _, _ in
                guard autoSyncToPhotos else { return }
                Task {
                    await syncAllItemsToPhotosLibrary(onlyAlbumAndDateIfAlreadySynced: true)
                }
            }
        }
        .applyAppAppearanceAndLocale()
    }

    @MainActor
    private func syncAllItemsToPhotosLibrary(onlyAlbumAndDateIfAlreadySynced: Bool) async {
        guard !allChekiItems.isEmpty, !isSyncingAlbumsToPhotos else { return }
        isSyncingAlbumsToPhotos = true
        defer { isSyncingAlbumsToPhotos = false }
        await PhotoLibraryManager.shared.syncItemsToSystemPhotoLibrary(
            allChekiItems,
            modelContext: modelContext,
            onlyAlbumAndDateIfAlreadySynced: onlyAlbumAndDateIfAlreadySynced
        )
    }

    // MARK: - Pro 終身買斷尊爵橫幅卡片 (對齊 docs/ui/screen_07_settings.html，僅於未解鎖時顯示)

    private var proLifetimeBannerCard: some View {
        let usedQuota = min(StoreKitManager.dailyFreeLimit, max(0, dailyFreeQuotaUsedCount))
        let dailyLimit = StoreKitManager.dailyFreeLimit

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(red: 0.65, green: 0.71, blue: 0.99))
                Text("PRO LIFETIME")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(Color(red: 0.65, green: 0.71, blue: 0.99))
                Spacer()
                Text(L10n.tr("今日免費 \(usedQuota)/\(dailyLimit)", "本日無料 \(usedQuota)/\(dailyLimit)"))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }

            Text(L10n.tr("ChekiLens Pro 終身買斷", "ChekiLens Pro 買い切り"))
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)

            Text(L10n.tr("原畫質無損輸出 · 雙角度去反光 · 移除浮水印", "高画質ロスレス出力 · 2角度反射除去 · 透かしなし"))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.84))
                .lineSpacing(2)

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showingProPurchaseSheet = true
            } label: {
                Text(StoreKitManager.shared.bannerUnlockButtonTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(red: 0.12, green: 0.11, blue: 0.29))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.118, green: 0.106, blue: 0.294), // #1e1b4b
                    Color(red: 0.192, green: 0.180, blue: 0.506), // #312e81
                    Color(red: 0.310, green: 0.275, blue: 0.898)  // #4f46e5
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private func borderPresetButton(title: String, targetValue: Double) -> some View {
        let isSelected = abs(defaultBorderInsetPercentage - targetValue) < 0.05
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            defaultBorderInsetPercentage = targetValue
        } label: {
            Text(LocalizedStringKey(title))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .blue : .secondary)
        .controlSize(.small)
    }

    @MainActor
    private func restorePurchases() async {
        isRestoringPurchases = true
        defer { isRestoringPurchases = false }

        let restored = await StoreKitManager.shared.restorePurchases()
        isProLifetimeUnlocked = StoreKitManager.shared.isProUnlocked

        if restored || isProLifetimeUnlocked {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            alertTitle = L10n.tr("已恢復購買", "購入を復元しました")
            alertMessage = L10n.tr("ChekiLens Pro 已啟用。", "ChekiLens Pro が有効になりました。")
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            alertTitle = L10n.tr("查無購買紀錄", "購入履歴なし")
            alertMessage = L10n.tr("此 Apple ID 尚無購買紀錄。", "この Apple ID の購入履歴は見つかりませんでした。")
        }
    }
}

// MARK: - iOS 原生「設定」風格左側彩色圓角圖示列 (SettingsRowLabel)

private struct SettingsRowLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let iconColor: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(iconColor.gradient)
                    .frame(width: 28, height: 28)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - ChekiLens Pro 終身買斷權益與解鎖面板 (StoreKit 2 買斷入口)

private struct ProLifetimePaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isProUnlocked: Bool
    let onRestorePurchases: () async -> Void

    @State private var isPurchasing: Bool = false
    @State private var purchaseStatusNote: String? = nil

    private var features: [(icon: String, color: Color, title: String, desc: String)] {
        [
            (
                "4k.tv.fill",
                .indigo,
                L10n.tr("系統相簿原地裁切", "写真アプリで直接トリミング"),
                L10n.tr("非破壞性修改系統相簿原圖，不產生重複照片", "重複を作らず元画像を非破壊で直接トリミング")
            ),
            (
                "sun.max.trianglebadge.exclamationmark.fill",
                .pink,
                L10n.tr("雙角度去反光", "2角度反射除去"),
                L10n.tr("兩張微傾角度自動消除保護套強光", "2枚の角度からスリーブの反射を自動除去")
            ),
            (
                "sparkles.rectangle.stack.fill",
                .orange,
                L10n.tr("移除浮水印", "透かし除去"),
                L10n.tr("一次買斷永久解鎖所有功能", "買い切りで全機能を永久アンロック")
            )
        ]
    }

    var body: some View {
        let priceLabel = StoreKitManager.shared.displayPrice

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 頂部徽章與標題
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.19, green: 0.18, blue: 0.51),
                                            Color(red: 0.31, green: 0.28, blue: 0.90)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 64, height: 64)
                            Image(systemName: "crown.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.yellow)
                        }
                        .padding(.top, 8)

                        Text(L10n.tr("ChekiLens Pro 終身買斷", "ChekiLens Pro 買い切り"))
                            .font(.title2.weight(.heavy))

                        Text(L10n.tr("一次買斷 \(priceLabel) · 永久解鎖", "買い切り \(priceLabel) · 永久アンロック"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    // 三大核心權益列表
                    VStack(spacing: 14) {
                        ForEach(features, id: \.title) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.bold))
                                    Text(item.desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)

                    if let note = purchaseStatusNote {
                        Text(note)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }

                    // 購買與恢復按鈕
                    VStack(spacing: 10) {
                        Button {
                            Task {
                                await performPurchase()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isPurchasing {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: isProUnlocked ? "checkmark.seal.fill" : "lock.open.fill")
                                    if isProUnlocked {
                                        Text(L10n.tr("已解鎖 Pro", "Pro アンロック済み"))
                                            .fontWeight(.bold)
                                    } else {
                                        Text(L10n.tr("\(priceLabel) 永久解鎖", "\(priceLabel) で永久アンロック"))
                                            .fontWeight(.bold)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .background(
                                LinearGradient(
                                    colors: isProUnlocked
                                        ? [Color.green, Color.teal]
                                        : [Color(red: 0.19, green: 0.18, blue: 0.51), Color(red: 0.31, green: 0.28, blue: 0.90)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPurchasing)

                        Button {
                            Task {
                                await onRestorePurchases()
                                if isProUnlocked {
                                    dismiss()
                                }
                            }
                        } label: {
                            Text(L10n.tr("恢復購買", "購入を復元"))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @MainActor
    private func performPurchase() async {
        isPurchasing = true
        purchaseStatusNote = nil
        defer { isPurchasing = false }

        // 若目前已解鎖且在開發測試中點擊，支援切換回免費版以測試浮水印與原生相簿未裁切行為
        if isProUnlocked && StoreKitManager.shared.proProduct == nil {
            StoreKitManager.shared.setProUnlocked(false)
            isProUnlocked = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        let outcome = await StoreKitManager.shared.purchaseProLifetime()
        isProUnlocked = StoreKitManager.shared.isProUnlocked

        switch outcome {
        case .purchased, .restored:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()

        case .simulatedToggle(let unlocked):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if unlocked {
                dismiss()
            }

        case .pending:
            purchaseStatusNote = L10n.tr("等待核准中", "承認待ちです")

        case .userCancelled:
            break

        case .failed(let message):
            purchaseStatusNote = message
        }
    }
}

#Preview("07. 設定與 Pro 買斷 (iOS 18 HIG)") {
    SettingsView()
}
