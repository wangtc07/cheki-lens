import SwiftUI

// MARK: - SettingsView (Task 4.7)
/// 設定頁面 — 使用 iOS 官方 Inset Grouped List，包含自動判斷拍立得邊界時的「邊界微調 (Inset / Outset)」全域設定
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("defaultBorderInsetPercentage") private var defaultBorderInsetPercentage: Double = 0.0
    @AppStorage("autoSyncToPhotosLibrary") private var autoSyncToPhotos: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("自動邊界微調 (Inset / Outset)", systemImage: "crop")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(String(format: "%+.1f%%", defaultBorderInsetPercentage))
                                .font(.subheadline.monospacedDigit().weight(.bold))
                                .foregroundStyle(abs(defaultBorderInsetPercentage) > 0.05 ? .blue : .secondary)
                        }

                        Slider(value: $defaultBorderInsetPercentage, in: -3.0...3.0, step: 0.5)
                            .tint(.blue)

                        HStack(spacing: 8) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                defaultBorderInsetPercentage = -2.0
                            } label: {
                                Text("-2% 去陰影")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(abs(defaultBorderInsetPercentage - (-2.0)) < 0.05 ? .blue : .secondary)
                            .controlSize(.small)

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                defaultBorderInsetPercentage = 0.0
                            } label: {
                                Text("0% 標準外框")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(abs(defaultBorderInsetPercentage) < 0.05 ? .blue : .secondary)
                            .controlSize(.small)

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                defaultBorderInsetPercentage = 2.0
                            } label: {
                                Text("+2% 完整留白")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(abs(defaultBorderInsetPercentage - 2.0) < 0.05 ? .blue : .secondary)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("自動邊界偵測與裁切")
                } footer: {
                    Text("在自動判斷拍立得邊界時（包含批次匯入背景預裁切、相機拍攝正位、以及手動編輯器的「自動吸附」），會自動依此比例向內收縮（負值去除桌面黑邊陰影）或向外擴張（正值保留完整相紙白邊）。")
                }

                Section("相簿同步") {
                    Toggle(isOn: $autoSyncToPhotos) {
                        Label("歸檔時自動同步至 iOS 系統相簿", systemImage: "photo.on.rectangle.angled")
                    }
                }

                Section("關於") {
                    LabeledContent("版本") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("重新顯示導引頁面") {
                        dismiss()
                        hasCompletedOnboarding = false
                    }
                }

                Section("Pro 功能") {
                    Label("ChekiLens Pro", systemImage: "crown")
                        .badge("即將推出")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}

