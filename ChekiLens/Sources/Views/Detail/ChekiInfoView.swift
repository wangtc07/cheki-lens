import SwiftUI

// MARK: - ChekiInfoView (Task 4.6)
/// 拍立得資訊與備忘面板
/// 使用 iOS 標準 Inset Grouped List 樣式
struct ChekiInfoView: View {
    let item: ChekiItem
    @Environment(\.modelContext) private var modelContext
    @State private var memoText = ""

    var body: some View {
        List {
            // 縮圖預覽
            if let data = item.frontImageData ?? item.frontImageData,
               let uiImage = UIImage(data: data) {
                Section {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                }
            }

            // 日期資訊
            Section("拍攝資訊") {
                LabeledContent("日期", value: item.creationDate.formatted(date: .long, time: .omitted))
                LabeledContent("時間", value: item.creationDate.formatted(date: .omitted, time: .shortened))
                LabeledContent("規格", value: item.filmFormat.displayName)
                LabeledContent("處理狀態", value: item.processingState.displayName)
            }

            // 備忘錄
            Section("備忘") {
                TextField("新增備忘...", text: $memoText, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("資訊")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            memoText = item.memo?.noteText ?? ""
        }
    }
}
