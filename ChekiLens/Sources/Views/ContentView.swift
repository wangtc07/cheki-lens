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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appAppearanceMode") private var appAppearanceModeRaw: String = AppAppearanceMode.system.rawValue
    @AppStorage("appLanguageMode") private var appLanguageModeRaw: String = AppLanguageMode.system.rawValue
    @State private var selectedTab: MainLibraryTab = .allPhotos
    private var chromeState = NavigationChromeState.shared

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                ZStack {
                    TabView(selection: $selectedTab) {
                        Tab("全部", systemImage: "photo.on.rectangle.angled", value: MainLibraryTab.allPhotos) {
                            LibraryView()
                                .toolbar(chromeState.shouldHideMainTabBar ? .hidden : .visible, for: .tabBar)
                        }

                        Tab("相冊", systemImage: "rectangle.stack.fill", value: MainLibraryTab.albums) {
                            AlbumsRootView()
                                .toolbar(chromeState.shouldHideMainTabBar ? .hidden : .visible, for: .tabBar)
                        }

                        Tab("搜尋", systemImage: "magnifyingglass", value: MainLibraryTab.search, role: .search) {
                            LibrarySearchView()
                                .toolbar(chromeState.shouldHideMainTabBar ? .hidden : .visible, for: .tabBar)
                        }
                    }
                    .toolbar(chromeState.shouldHideMainTabBar ? .hidden : .visible, for: .tabBar)

                    if let route = chromeState.activeDetailRoute {
                        ChekiDetailView(
                            itemID: route.itemID,
                            scopedItemIDs: route.scopedItemIDs,
                            sourceScopeID: route.sourceScopeID
                        )
                        .id(route.itemID)
                        .zIndex(100)
                    }
                }
            } else {
                OnboardingView()
            }
        }
        .id(appLanguageModeRaw)
        .applyAppAppearanceAndLocale()
        .task {
            guard hasCompletedOnboarding else { return }
            _ = await PhotoLibraryManager.shared.syncAllExternalEditsFromSystemPhotoLibrary(modelContext: modelContext)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasCompletedOnboarding else { return }
            Task {
                _ = await PhotoLibraryManager.shared.syncAllExternalEditsFromSystemPhotoLibrary(modelContext: modelContext)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(try! ModelContainerProvider.preview(withSampleData: true))
}
