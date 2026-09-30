import SwiftUI
import SwiftData

// MARK: - ModelContainerProvider

/// 統一管理 ModelContainer 生命週期的服務層
///
/// 提供兩種容器：
/// 1. `live`：磁碟持久化容器（正式 App 使用）
/// 2. `preview`：記憶體容器（SwiftUI Preview / XCTest 使用）
enum ModelContainerProvider {

    // MARK: Live Container

    /// 正式持久化 ModelContainer（所有 @Model 實體均納入 Schema）
    static let live: ModelContainer = {
        let schema = Schema([
            ChekiItem.self,
            IdolGroup.self,
            IdolMember.self,
            ChekiMemo.self
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .none,   // 不跨 App Group 共享（暫不支援 Widget）
            cloudKitDatabase: .none  // 暫不啟用 CloudKit（Phase 1 MVP）
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("❌ ModelContainer (live) 初始化失敗：\(error.localizedDescription)")
        }
    }()

    // MARK: Preview / Test Container

    /// 記憶體版 ModelContainer（用於 SwiftUI Preview 與 XCTestCase）
    ///
    /// 呼叫後自動填入 `PreviewData.populate(into:)` 假資料
    @MainActor
    static func preview(withSampleData: Bool = true) throws -> ModelContainer {
        let schema = Schema([
            ChekiItem.self,
            IdolGroup.self,
            IdolMember.self,
            ChekiMemo.self
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [config])

        if withSampleData {
            PreviewData.populate(into: container.mainContext)
        }
        return container
    }
}

// MARK: - PreviewData

/// SwiftUI Preview / XCTest 用假資料生成器
///
/// 呼叫 `populate(into:)` 一次性插入標準測試資料集
enum PreviewData {

    // MARK: Public API

    /// 將完整假資料集插入指定 ModelContext
    @MainActor
    static func populate(into context: ModelContext) {
        let groups = makeSampleGroups()
        for group in groups { context.insert(group) }
        try? context.save()
    }

    // MARK: Sample Groups

    @MainActor
    static func makeSampleGroups() -> [IdolGroup] {
        // 日向坂46
        let hinatazaka = IdolGroup(
            name: "日向坂46",
            colorHex: "#62A8E5",
            sortOrder: 0
        )

        // 乃木坂46
        let nogizaka = IdolGroup(
            name: "乃木坂46",
            colorHex: "#C8102E",
            sortOrder: 1
        )

        // 成員
        let member1 = makeSampleMember(
            stageName: "河田陽菜",
            tags: ["#推し", "#ひなたん"],
            group: hinatazaka,
            chekiCount: 3
        )
        let member2 = makeSampleMember(
            stageName: "松田好花",
            tags: ["#好花", "#さくら"],
            group: hinatazaka,
            chekiCount: 2
        )
        let member3 = makeSampleMember(
            stageName: "齋藤飛鳥",
            tags: ["#あしゅ", "#最推"],
            group: nogizaka,
            chekiCount: 1
        )

        hinatazaka.members = [member1, member2]
        nogizaka.members = [member3]

        return [hinatazaka, nogizaka]
    }

    // MARK: Single Member Factory

    @MainActor
    static func makeSampleMember(
        stageName: String,
        tags: [String],
        group: IdolGroup,
        chekiCount: Int
    ) -> IdolMember {
        let member = IdolMember(
            stageName: stageName,
            tags: tags,
            group: group
        )

        let items = (0..<chekiCount).map { i -> ChekiItem in
            let item = makeSampleChekiItem(
                index: i,
                member: member
            )
            return item
        }
        member.chekiItems = items
        return member
    }

    // MARK: Single ChekiItem Factory

    @MainActor
    static func makeSampleChekiItem(
        index: Int,
        member: IdolMember
    ) -> ChekiItem {
        // 產生假的漸層顏色圖作為正面圖（64×102 像素灰階）
        let frontData = makePlaceholderImageData(
            width: 64, height: 102,
            baseGray: UInt8(80 + index * 30)
        )

        let daysAgo = TimeInterval(-(index + 1) * 86400 * 7)  // 每張差 7 天
        let capturedAt = Date(timeIntervalSinceNow: daysAgo)
        let ocrDate = Calendar.current.date(
            byAdding: .day,
            value: -1,
            to: capturedAt
        )

        let item = ChekiItem(
            frontImageData: frontData,
            backImageData: index % 2 == 0 ? frontData : nil,  // 偶數張才有背面
            capturedAt: capturedAt,
            ocrDate: ocrDate,
            isDateWrittenToAlbum: false,
            filmFormat: [FilmFormat.mini, .square, .wide][index % 3],
            detectedAspectRatio: FilmFormat.mini.aspectRatio,
            borderInsetRatio: 0.0,
            detectionMethod: .visionNative,
            processingState: index == 0 ? .completed : .unprocessed,
            isSyncedToPhotoLibrary: false,
            idolMember: member
        )

        // 第一張掛上備忘
        if index == 0 {
            let memo = ChekiMemo(
                eventName: "個人握手会 幕張メッセ",
                noteText: "めちゃくちゃ可愛かった！2ショット最高 ☆",
                hashtags: ["#日向坂46", "#握手会", "#チェキ"],
                chekiItem: item
            )
            item.memo = memo
        }

        return item
    }

    // MARK: Placeholder Image

    /// 產生指定灰階值的純色 JPEG（用於 Preview 假圖，不依賴 UIKit）
    private static func makePlaceholderImageData(
        width: Int,
        height: Int,
        baseGray: UInt8
    ) -> Data? {
        // 使用 CGBitmapContext 繪製純色 8-bit 灰階圖
        let bytesPerRow = width
        var pixels = [UInt8](repeating: baseGray, count: width * height)

        guard let cgContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let cgImage = cgContext.makeImage() else {
            return nil
        }

        // 轉換為 PNG Data（CGImage → Data，不依賴 UIKit UIImage）
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return mutableData as Data
    }
}

// MARK: - View Extension (Preview Helper)

extension View {

    /// 快速為 SwiftUI Preview 注入 in-memory ModelContainer + 假資料
    ///
    /// 用法：
    /// ```swift
    /// #Preview { MyView().withPreviewModelContainer() }
    /// ```
    @MainActor
    func withPreviewModelContainer() -> some View {
        let container = try! ModelContainerProvider.preview()
        return self.modelContainer(container)
    }
}
