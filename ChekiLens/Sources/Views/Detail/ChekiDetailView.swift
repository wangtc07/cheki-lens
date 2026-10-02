import SwiftUI
import SwiftData

// MARK: - ChekiDetailView (Task 4.5)
/// 拍立得單張全螢幕檢視
/// - 使用系統原生的全黑背景 + toolbar
/// - 正反面切換使用 TabView (PageTabViewStyle)
struct ChekiDetailView: View {
    let item: ChekiItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showingFront = true
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 正/反面 TabView 滑動切換
            TabView(selection: $showingFront) {
                chekiImageView(data: item.frontImageData ?? item.frontImageData)
                    .tag(true)

                chekiImageView(data: item.backImageData)
                    .tag(false)
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black.opacity(0.5), for: .navigationBar)
        .toolbar {
            // 頂部日期藥丸
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(item.capturedAt, style: .date)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text(item.capturedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomToolbar
        }
        .confirmationDialog("刪除此拍立得？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                modelContext.delete(item)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作無法復原。")
        }
    }

    // MARK: - Image Display

    private func chekiImageView(data: Data?) -> some View {
        Group {
            if let data = data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(showingFront ? "尚無正面照片" : "尚無背面照片")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            // 分享
            Button {
                shareItem()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }

            // 愛心
            Button {
                // 待實作：收藏功能
            } label: {
                Image(systemName: "heart")
                    .frame(maxWidth: .infinity)
            }

            // 資訊
            NavigationLink {
                ChekiInfoView(item: item)
            } label: {
                Image(systemName: "info.circle")
                    .frame(maxWidth: .infinity)
            }

            // 刪除
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.8))
    }

    // MARK: - Share
    private func shareItem() {
        guard let data = item.frontImageData ?? item.frontImageData,
              let uiImage = UIImage(data: data) else { return }

        let av = UIActivityViewController(activityItems: [uiImage], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let vc = scene.windows.first?.rootViewController {
            vc.present(av, animated: true)
        }
    }
}

#Preview {
    NavigationStack {
        ChekiDetailView(item: ChekiItem())
    }
    .modelContainer(try! ModelContainer(for: ChekiItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
}
