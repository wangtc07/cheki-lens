import SwiftUI

/// App 根視圖（佔位，待 Task 4.x 替換為真實首頁）
struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("ChekiLens")
                    .font(.largeTitle.bold())
                Text("開發中 — Phase 1 資料層建置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("ChekiLens")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
}
