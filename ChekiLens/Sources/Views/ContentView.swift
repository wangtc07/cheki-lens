import SwiftUI
import SwiftData

/// App 根視圖 — 根據 onboarding 狀態決定顯示哪個畫面
struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            // 主畫面：TabView (iOS 官方底部分頁導覽)
            TabView {
                LibraryView()
                    .tabItem {
                        Label("典藏", systemImage: "photo.stack")
                    }
                SettingsView()
                    .tabItem {
                        Label("設定", systemImage: "gearshape")
                    }
            }
        } else {
            OnboardingView()
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: ChekiItem.self, configurations: config)
    ContentView()
        .modelContainer(container)
}
