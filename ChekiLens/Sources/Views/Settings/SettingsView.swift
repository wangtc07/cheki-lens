import SwiftUI

// MARK: - SettingsView (Task 4.7)
/// 設定頁面 — 使用 iOS 官方 Inset Grouped List
struct SettingsView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        NavigationStack {
            List {
                Section("關於") {
                    LabeledContent("版本") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("重新顯示導引頁面") {
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
        }
    }
}

#Preview {
    SettingsView()
}
