import SwiftUI

/// App 根視圖 — 根據 onboarding 狀態決定顯示哪個畫面
struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            // 主畫面：TabView (iOS 官方底部分頁導覽)
            TabView {
                Tab("典藏", systemImage: "photo.stack") {
                    LibraryView()
                }
                Tab("設定", systemImage: "gearshape") {
                    SettingsView()
                }
            }
        } else {
            OnboardingView()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: ChekiItem.self, inMemory: true)
}
