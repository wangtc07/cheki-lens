import SwiftUI
import SwiftData

/// 主畫面底部分頁列舉（仿照 Apple 原生相簿：左側「全部 / 相冊」切換，右側「搜尋」按鈕）
enum MainLibraryTab: Hashable {
    case allPhotos
    case albums
    case search
}

/// App 根視圖 — 根據 onboarding 狀態決定顯示導引或主畫面
struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appAppearanceMode") private var appAppearanceModeRaw: String = AppAppearanceMode.system.rawValue
    @AppStorage("appLanguageMode") private var appLanguageModeRaw: String = AppLanguageMode.system.rawValue
    @State private var selectedTab: MainLibraryTab = .allPhotos

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                TabView(selection: $selectedTab) {
                    Tab("全部", systemImage: "photo.on.rectangle.angled", value: MainLibraryTab.allPhotos) {
                        LibraryView()
                    }

                    Tab("相冊", systemImage: "rectangle.stack.fill", value: MainLibraryTab.albums) {
                        AlbumsRootView()
                    }

                    Tab("搜尋", systemImage: "magnifyingglass", value: MainLibraryTab.search, role: .search) {
                        LibrarySearchView()
                    }
                }
            } else {
                OnboardingView()
            }
        }
        .id(appLanguageModeRaw)
        .applyAppAppearanceAndLocale()
    }
}

#Preview {
    ContentView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}
