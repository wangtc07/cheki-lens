import SwiftUI
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
            return "正反面同一秒（緊密相鄰）"
        case .plusOneSecond:
            return "背面延後 1 秒（正面固定在左）"
        }
    }

    var shortLabel: String {
        switch self {
        case .sameSecond:
            return "同一秒"
        case .plusOneSecond:
            return "背面 +1 秒"
        }
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
            return "相片匯入當年度"
        case .exifYear:
            return "原圖 EXIF 拍攝年度"
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
            return "保留原圖格式（不轉換）"
        case .convertFormat:
            return "轉換為指定格式"
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
            return "原圖格式 (不轉換)"
        case .heic:
            return "HEIC (節省空間)"
        case .jpeg:
            return "JPEG (最佳相容性)"
        case .png:
            return "無失真 PNG (典藏專用)"
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
            return "Mode A（單張智慧抑制）"
        case .modeB:
            return "Mode B（雙角度合成 · Pro）"
        }
    }

    var shortLabel: String {
        switch self {
        case .modeA:
            return "Mode A (單張)"
        case .modeB:
            return "Mode B (Pro)"
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
            return "跟隨系統"
        case .dark:
            return "深色模式"
        case .light:
            return "淺色模式"
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

    // MARK: Pro 買斷狀態與每日免費額度 (與 Phase 5 StoreKitManager 雙向綁定)
    @AppStorage("isProLifetimeUnlocked") private var isProLifetimeUnlocked: Bool = false
    @AppStorage("dailyFreeQuotaUsedCount") private var dailyFreeQuotaUsedCount: Int = 0

    // MARK: 第 1 組：相簿雙向同步與時間軸策略
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = false
    @AppStorage("createGroupMemberAlbumsInPhotos") private var createGroupMemberAlbums: Bool = true
    @AppStorage("overwriteExifDateWithOCR") private var overwriteExifDateWithOCR: Bool = true
    @AppStorage("backsideTimelineStrategy") private var backsideTimelineStrategyRaw: String = BacksideTimelineStrategy.sameSecond.rawValue
    @AppStorage("confirmDeleteFromPhotosLibrary") private var confirmDeleteFromPhotosLibrary: Bool = true

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
    @AppStorage("appAppearanceMode") private var appAppearanceModeRaw: String = AppAppearanceMode.system.rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage("hasSeenBatchPairingCoachMark") private var hasSeenBatchPairingCoachMark: Bool = false
    @AppStorage("hasSeenDetailCoachMark") private var hasSeenDetailCoachMark: Bool = false

    @State private var showingProPurchaseSheet: Bool = false
    @State private var isRestoringPurchases: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String? = nil

    private var appVersionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(shortVersion) (\(buildNumber))"
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
                            title: "同步至 iOS 系統相簿",
                            subtitle: isProLifetimeUnlocked
                                ? "Pro：直接於系統相簿非破壞性原地裁切原圖"
                                : "免費版：同步相簿與時間軸（原生相簿保留未裁切原圖）",
                            systemImage: "photo.on.rectangle.angled",
                            iconColor: .blue
                        )
                    }

                    Toggle(isOn: $createGroupMemberAlbums) {
                        SettingsRowLabel(
                            title: "團體 / 成員專屬相簿階層",
                            subtitle: "自動建立 ChekiLens › 團體 › 成員 相簿",
                            systemImage: "folder.fill",
                            iconColor: .green
                        )
                    }
                    .disabled(!autoSyncToPhotos)

                    Toggle(isOn: $overwriteExifDateWithOCR) {
                        SettingsRowLabel(
                            title: "手寫日期覆寫 EXIF 時間軸",
                            subtitle: "以拍立得手寫日期作為相簿照片拍攝時間",
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
                            title: "正反面時間軸排序",
                            subtitle: nil,
                            systemImage: "arrow.left.arrow.right.square.fill",
                            iconColor: .indigo
                        )
                    }

                    Toggle(isOn: $confirmDeleteFromPhotosLibrary) {
                        SettingsRowLabel(
                            title: "刪除時詢問自系統相簿移除",
                            subtitle: nil,
                            systemImage: "trash.fill",
                            iconColor: .red
                        )
                    }
                } header: {
                    Text("iOS 相簿雙向同步與時間軸")
                } footer: {
                    Text(
                        isProLifetimeUnlocked
                            ? "Pro 版已啟用：系統相簿採用非破壞性原地修改（In-place Edit），不新增重複照片並保留原始未裁切底圖供隨時復原。"
                            : "免費版：原生相簿不裁切（保留未裁切原圖），但可同步相簿分類與拍攝時間軸；裁切後照片僅在 App 內（加上浮水印）查看，分享或輸出時亦加上浮水印。"
                    )
                }

                // 2. 第 2 組：匯入與 OCR 手寫日期辨識偏好 (Import & Recognition)
                Section {
                    Toggle(isOn: $autoRecognizeOCRDateOnImport) {
                        SettingsRowLabel(
                            title: "匯入時自動辨識手寫日期",
                            subtitle: "批次匯入與拍攝後於背景自動執行 OCR 日期提取",
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
                            title: "無年份手寫日期補全規則",
                            subtitle: "當手寫日期僅標註月/日（如 9/17）時",
                            systemImage: "calendar.badge.clock",
                            iconColor: .teal
                        )
                    }
                    .disabled(!autoRecognizeOCRDateOnImport)
                } header: {
                    Text("匯入與手寫日期 OCR 辨識")
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
                            title: "輸出影像格式",
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
                    Text("照片儲存與輸出格式")
                } footer: {
                    Text("選擇「保留原圖格式」將維持原始相片封裝；選擇 HEIC 可節省約 45% 儲存空間，無失真 PNG 則適合長期數位典藏。")
                }

                // 4. 第 4 組：相機與影像處理偏好 (Scan & Image Processing)
                Section {
                    Picker(selection: $defaultFilmFormatRaw) {
                        ForEach(FilmFormat.allCases, id: \.rawValue) { format in
                            Text(format.displayName).tag(format.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "預設相紙規格",
                            subtitle: nil,
                            systemImage: "aspectratio.fill",
                            iconColor: .indigo
                        )
                    }

                    // 自動邊界微調 (Inset / Outset) 滑桿與快速預設
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SettingsRowLabel(
                                title: "自動邊界微調 (Inset / Outset)",
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
                            borderPresetButton(title: "-2% 去陰影", targetValue: -2.0)
                            borderPresetButton(title: "0% 標準外框", targetValue: 0.0)
                            borderPresetButton(title: "+2% 完整留白", targetValue: 2.0)
                        }
                    }
                    .padding(.vertical, 4)

                    Picker(selection: $antiReflectionModeRaw) {
                        ForEach(AntiReflectionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "反光對策模式",
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
                    Text("掃描與影像處理")
                } footer: {
                    Text("在自動判斷拍立得邊界時（包含批次匯入背景預裁切、相機拍攝正位、以及手動編輯器的「自動吸附」），會自動依此比例向內收縮（負值去除桌面黑邊陰影）或向外擴張（正值保留完整相紙白邊）。")
                }

                // 5. 第 5 組：一般與關於 (General & About)
                Section {
                    Picker(selection: $appAppearanceModeRaw) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "外觀模式",
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
                                title: "重新顯示歡迎導引與操作提示",
                                subtitle: "重置首次配對提示與 3D 翻轉導引",
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
                                title: "恢復購買項目 (Restore Purchases)",
                                subtitle: "從 Apple ID 同步 ChekiLens Pro 終身買斷資格",
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
                                    title: "切換回免費版（開發測試）",
                                    subtitle: "重新顯示頂部 Pro 卡片與測試免費版浮水印",
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
                    } else if dailyFreeQuotaUsedCount > 0 {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            StoreKitManager.shared.resetDailyFreeQuota()
                            dailyFreeQuotaUsedCount = 0
                        } label: {
                            HStack {
                                SettingsRowLabel(
                                    title: "重置今日免費 1 張額度（開發測試）",
                                    subtitle: "目前使用進度 \(min(StoreKitManager.dailyFreeLimit, dailyFreeQuotaUsedCount))/\(StoreKitManager.dailyFreeLimit)（點擊重置為 0/1）",
                                    systemImage: "arrow.counterclockwise.circle.fill",
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
                    Text("一般與關於")
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
        }
        .preferredColorScheme(
            (AppAppearanceMode(rawValue: appAppearanceModeRaw) ?? .system).resolvedColorScheme
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
                Text("今日免費無浮水印 \(usedQuota)/\(dailyLimit)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }

            Text("ChekiLens Pro 終身買斷")
                .font(.title3.weight(.heavy))
                .foregroundStyle(.white)

            Text("原畫質無損輸出 · 雙角度去反光合成 · 完全移除浮水印")
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
            Text(title)
                .font(.caption.weight(.semibold))
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
            alertTitle = "恢復購買成功"
            alertMessage = "已成功恢復您的 ChekiLens Pro 終身買斷授權！"
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            alertTitle = "恢復購買項目"
            alertMessage = "目前此 Apple ID 尚未查找到 ChekiLens Pro 購買紀錄。若於開發環境測試，可點擊頂部卡片進入預覽解鎖。"
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
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
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

    private let features: [(icon: String, color: Color, title: String, desc: String)] = [
        ("4k.tv.fill", .indigo, "原畫質無損輸出 · 原生相簿原地裁切", "免費版於系統相簿保留未裁切原圖；升級 Pro 可直接在 iOS 原生相簿非破壞性原地裁切（不新增重複照片、保留原圖可復原）並無損輸出"),
        ("sun.max.trianglebadge.exclamationmark.fill", .pink, "雙角度去反光合成", "透過 Mode B 兩張微傾角度自動消除塑膠保護套強光反射"),
        ("sparkles.rectangle.stack.fill", .orange, "完全移除浮水印 · 終身買斷", "移除 App 內裁切檢視與分享輸出時的 ChekiLens 浮水印，一次付費永久解鎖")
    ]

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

                        Text("ChekiLens Pro 終身買斷")
                            .font(.title2.weight(.heavy))

                        Text("一次買斷 \(priceLabel) · 永久解鎖全功能")
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
                                    Text(isProUnlocked ? "已解鎖 Pro 終身版（點擊切換測試狀態）" : "\(priceLabel) 立即永久解鎖")
                                        .fontWeight(.bold)
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
                            Text("恢復購買項目 (Restore Purchases)")
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
            purchaseStatusNote = "交易等待家長或帳號核准中，核准後將自動解鎖 Pro。"

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
