import SwiftUI
import SwiftData
import PhotosUI

// MARK: - LibraryView (Task 4.2 Gallery + Task 4.4 PhotosPicker)
/// 首頁相片庫視圖
/// - 使用 NavigationSplitView / NavigationStack (iOS 官方)
/// - 使用 PhotosPicker (iOS 16+ 官方系統選圖 UI)
/// - 使用 LazyVGrid 顯示已儲存的拍立得
struct LibraryView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChekiItem.capturedAt, order: .reverse) private var chekiItems: [ChekiItem]

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var processingItems: [PhotosPickerItem] = []
    @State private var isProcessing = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    // 明確宣告 init，避免 Swift 6 因 @Query private var 導致合成 initializer 變成 private
    init() {}

    var body: some View {
        NavigationStack {
            Group {
                if chekiItems.isEmpty {
                    emptyStateView
                } else {
                    gridView
                }
            }
            .navigationTitle("典藏")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // PhotosPicker (系統原生選圖介面，無需自刻)
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 50,
                        matching: .images,
                        preferredItemEncoding: .automatic
                    ) {
                        Label("匯入", systemImage: "plus")
                    }
                    .onChange(of: selectedPhotos) { _, newItems in
                        guard !newItems.isEmpty else { return }
                        processingItems = newItems
                        selectedPhotos = []
                        Task { await processImportedPhotos(processingItems) }
                    }
                }
            }
            .overlay {
                if isProcessing {
                    processingOverlay
                }
            }
        }
    }

    // MARK: - Sub Views

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("尚無拍立得", systemImage: "photo.stack")
        } description: {
            Text("點擊右上角的「+」，從您的相簿匯入拍立得照片。")
        } actions: {
            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: 50,
                matching: .images
            ) {
                Text("選擇照片")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 2) {
                ForEach(chekiItems) { item in
                    NavigationLink(value: item) {
                        ChekiThumbnailView(item: item)
                    }
                }
            }
        }
        .navigationDestination(for: ChekiItem.self) { item in
            ChekiDetailView(item: item)
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("AI 分析中...")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - Processing Logic

    @MainActor
    private func processImportedPhotos(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        defer { isProcessing = false }

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else { continue }

            // 建立 ChekiItem 並存入 SwiftData
            let newItem = ChekiItem()
            newItem.frontImageData = data
            newItem.capturedAt = Date()
            newItem.processingState = .unprocessed

            modelContext.insert(newItem)

            // 丟給 VisionManager 處理 (AI 裁切)
            await processWithVision(newItem, image: uiImage)
        }

        try? modelContext.save()
    }

    private func processWithVision(_ item: ChekiItem, image: UIImage) async {
        guard let cgImage = image.cgImage else { return }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

        do {
            let manager = VisionManager()
            let detection = try await manager.detectQuad(in: cgImage, imageSize: imageSize)
            let cropResult = try await manager.perspectiveCorrect(
                image: cgImage,
                corners: detection.corners,
                detection: detection,
                format: .auto
            )
            await MainActor.run {
                item.frontImageData = UIImage(cgImage: cropResult.cgImage).jpegData(compressionQuality: 0.92)
                item.processingState = .completed
            }
        } catch {
            await MainActor.run {
                item.processingState = .error
            }
        }
    }
}

// MARK: - Thumbnail Cell
private struct ChekiThumbnailView: View {
    let item: ChekiItem

    var body: some View {
        GeometryReader { geo in
            Group {
                if let data = item.frontImageData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item.processingState == .error {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .padding(6)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview {
    LibraryView()
        .modelContainer(try! ModelContainer(for: ChekiItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
}
