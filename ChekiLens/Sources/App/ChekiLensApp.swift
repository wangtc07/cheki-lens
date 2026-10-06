import SwiftUI
import SwiftData

/// ChekiLens 應用程式入口點
/// - iOS 17.0+（iOS 18+ 優先使用新功能）
/// - 採用 SwiftData + SwiftUI 零第三方依賴架構
@main
struct ChekiLensApp: App {

    /// 共用 ModelContainer，於 App 層注入整個視圖樹（DEBUG 模式下若資料庫為空會自動載入範例測試資料）
    var sharedModelContainer: ModelContainer = ModelContainerProvider.live

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
