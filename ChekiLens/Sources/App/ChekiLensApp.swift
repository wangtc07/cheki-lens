import SwiftUI
import SwiftData

/// ChekiLens 應用程式入口點
/// - iOS 17.0+（iOS 18+ 優先使用新功能）
/// - 採用 SwiftData + SwiftUI 零第三方依賴架構
@main
struct ChekiLensApp: App {

    /// 共用 ModelContainer，於 App 層注入整個視圖樹
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ChekiItem.self,
            IdolGroup.self,
            IdolMember.self,
            ChekiMemo.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("❌ 無法建立 ModelContainer：\(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
