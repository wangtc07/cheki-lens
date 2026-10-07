import SwiftUI
import SwiftData
import CoreGraphics
import ImageIO

// MARK: - ModelContainerProvider

/// 統一管理 ModelContainer 生命週期的服務層
///
/// 提供兩種容器：
/// 1. `live`：磁碟持久化容器（正式 App 使用，DEBUG 模式下若為空會自動注入初始測試資料）
/// 2. `preview`：記憶體容器（SwiftUI Preview / XCTest 使用）
enum ModelContainerProvider {

    // MARK: Live Container

    /// 正式持久化 ModelContainer（所有 @Model 實體均納入 Schema）
    @MainActor
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
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            #if DEBUG
            PreviewData.seedIfEmpty(into: container.mainContext)
            #endif
            return container
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

/// SwiftUI Preview / Simulator / XCTest 用測試資料生成器
///
/// 呼叫 `populate(into:)` 一次性插入標準測試資料集（3 大團體、6 位成員、13 張正反面與不同規格拍立得、完整特典會備忘錄）
enum PreviewData {

    // MARK: Public API

    /// 若目前資料庫為空，自動寫入完整測試資料集
    @MainActor
    static func seedIfEmpty(into context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<ChekiItem>())) ?? 0
        let groupCount = (try? context.fetchCount(FetchDescriptor<IdolGroup>())) ?? 0
        guard count == 0 && groupCount == 0 else { return }
        populate(into: context)
    }

    /// 將完整測試資料集插入指定 ModelContext
    @MainActor
    static func populate(into context: ModelContext) {
        let groups = makeSampleGroups()
        for group in groups {
            context.insert(group)
        }

        // 追加 2 張「未分類」的拍立得（1 張單面、1 張經批次配對合成的正反雙面），測試未分類相冊與雙面篩選情境
        let uncategorizedFront1 = makePolaroidImageData(
            width: 270,
            height: 430,
            topRGB: (65, 88, 208),
            bottomRGB: (200, 80, 192),
            isBackside: false
        )
        let uncategorizedItem1 = ChekiItem(
            frontImageData: uncategorizedFront1,
            backImageData: nil,
            capturedAt: Date(timeIntervalSinceNow: -3600 * 18),
            ocrDate: nil,
            isDateWrittenToAlbum: false,
            filmFormat: .mini,
            detectedAspectRatio: FilmFormat.mini.aspectRatio,
            borderInsetRatio: 0.0,
            detectionMethod: .visionNative,
            processingState: .completed,
            isSyncedToPhotoLibrary: false,
            idolMember: nil
        )
        let uncategorizedMemo1 = ChekiMemo(
            eventName: "秋葉原 チェキチャ特典会",
            noteText: "剛翻拍還沒歸檔成員的測試拍立得",
            hashtags: ["#未分類", "#測試資料"],
            chekiItem: uncategorizedItem1
        )
        uncategorizedItem1.memo = uncategorizedMemo1
        context.insert(uncategorizedItem1)

        let uncategorizedFront2 = makePolaroidImageData(
            width: 270,
            height: 430,
            topRGB: (16, 185, 129),
            bottomRGB: (59, 130, 246),
            isBackside: false
        )
        let uncategorizedBack2 = makePolaroidImageData(
            width: 270,
            height: 430,
            topRGB: (59, 130, 246),
            bottomRGB: (16, 185, 129),
            isBackside: true
        )
        let uncategorizedItem2 = ChekiItem(
            frontImageData: uncategorizedFront2,
            backImageData: uncategorizedBack2,
            capturedAt: Date(timeIntervalSinceNow: -3600 * 6),
            ocrDate: Calendar.current.date(byAdding: .day, value: -2, to: Date()),
            isDateWrittenToAlbum: true,
            filmFormat: .mini,
            detectedAspectRatio: FilmFormat.mini.aspectRatio,
            borderInsetRatio: 0.0,
            detectionMethod: .visionNative,
            processingState: .completed,
            isSyncedToPhotoLibrary: true,
            idolMember: nil
        )
        let uncategorizedMemo2 = ChekiMemo(
            eventName: "渋谷 タワレコ リリイベ",
            noteText: "使用批次配對工作台自動合成正反雙面的測試卡片",
            hashtags: ["#未分類", "#雙面配對", "#批次匯入"],
            chekiItem: uncategorizedItem2
        )
        uncategorizedItem2.memo = uncategorizedMemo2
        context.insert(uncategorizedItem2)

        try? context.save()
    }

    // MARK: Sample Groups

    @MainActor
    static func makeSampleGroups() -> [IdolGroup] {
        // 1. 日向坂46
        let hinatazaka = IdolGroup(
            name: "日向坂46",
            colorHex: "#5B9BD5",
            sortOrder: 0
        )

        // 2. 乃木坂46
        let nogizaka = IdolGroup(
            name: "乃木坂46",
            colorHex: "#8E44AD",
            sortOrder: 1
        )

        // 3. 櫻坂46
        let sakurazaka = IdolGroup(
            name: "櫻坂46",
            colorHex: "#F06292",
            sortOrder: 2
        )

        // 4. =LOVE
        let equalLove = IdolGroup(
            name: "=LOVE",
            colorHex: "#EC4899",
            sortOrder: 3
        )

        // 日向坂46 成員 (共 7 張)
        let member1 = makeSampleMember(
            stageName: "河田陽菜",
            realName: "Kawata Hina",
            tags: ["#推し", "#ひなたん", "#2期生"],
            group: hinatazaka,
            sortOrder: 0,
            chekiCount: 3,
            paletteIndex: 0
        )
        let member2 = makeSampleMember(
            stageName: "松田好花",
            realName: "Matsuda Konoka",
            tags: ["#好花", "#だーこの"],
            group: hinatazaka,
            sortOrder: 1,
            chekiCount: 2,
            paletteIndex: 1
        )
        let member3 = makeSampleMember(
            stageName: "正源司陽子",
            realName: "Shogenji Yoko",
            tags: ["#しょげこ", "#4期生", "#センター"],
            group: hinatazaka,
            sortOrder: 2,
            chekiCount: 2,
            paletteIndex: 2
        )

        // 乃木坂46 成員 (共 6 張)
        let member4 = makeSampleMember(
            stageName: "遠藤さくら",
            realName: "Endo Sakura",
            tags: ["#さくちゃん", "#最推", "#4期生"],
            group: nogizaka,
            sortOrder: 0,
            chekiCount: 2,
            paletteIndex: 3
        )
        let member5 = makeSampleMember(
            stageName: "齋藤飛鳥",
            realName: "Saito Asuka",
            tags: ["#あしゅ", "#卒業コン"],
            group: nogizaka,
            sortOrder: 1,
            chekiCount: 2,
            paletteIndex: 4
        )
        let member6 = makeSampleMember(
            stageName: "賀喜遥香",
            realName: "Kaki Haruka",
            tags: ["#かっきー", "#4期生"],
            group: nogizaka,
            sortOrder: 2,
            chekiCount: 2,
            paletteIndex: 5
        )

        // 櫻坂46 成員 (共 3 張)
        let member7 = makeSampleMember(
            stageName: "森田ひかる",
            realName: "Morita Hikaru",
            tags: ["#るんちゃん", "#櫻坂46"],
            group: sakurazaka,
            sortOrder: 0,
            chekiCount: 2,
            paletteIndex: 6
        )
        let member8 = makeSampleMember(
            stageName: "山﨑天",
            realName: "Yamasaki Ten",
            tags: ["#てんちゃん", "#2期生"],
            group: sakurazaka,
            sortOrder: 1,
            chekiCount: 1,
            paletteIndex: 7
        )

        // =LOVE 成員 (共 2 張)
        let member9 = makeSampleMember(
            stageName: "佐々木舞香",
            realName: "Sasaki Maika",
            tags: ["#舞香ちゃん", "#イコラブ"],
            group: equalLove,
            sortOrder: 0,
            chekiCount: 2,
            paletteIndex: 8
        )

        hinatazaka.members = [member1, member2, member3]
        nogizaka.members = [member4, member5, member6]
        sakurazaka.members = [member7, member8]
        equalLove.members = [member9]

        return [hinatazaka, nogizaka, sakurazaka, equalLove]
    }

    // MARK: Single Member Factory

    @MainActor
    static func makeSampleMember(
        stageName: String,
        realName: String? = nil,
        tags: [String],
        group: IdolGroup,
        sortOrder: Int = 0,
        chekiCount: Int,
        paletteIndex: Int = 0
    ) -> IdolMember {
        let member = IdolMember(
            stageName: stageName,
            realName: realName,
            tags: tags,
            sortOrder: sortOrder,
            group: group
        )

        let items = (0..<chekiCount).map { i -> ChekiItem in
            makeSampleChekiItem(
                index: i,
                member: member,
                paletteIndex: paletteIndex + i
            )
        }
        member.chekiItems = items
        return member
    }

    // MARK: Single ChekiItem Factory

    @MainActor
    static func makeSampleChekiItem(
        index: Int,
        member: IdolMember,
        paletteIndex: Int = 0
    ) -> ChekiItem {
        let palettes: [((UInt8, UInt8, UInt8), (UInt8, UInt8, UInt8))] = [
            ((79, 70, 229), (219, 39, 119)),   // Indigo -> Pink
            ((14, 165, 233), (59, 130, 246)),  // Sky -> Blue
            ((245, 158, 11), (239, 68, 68)),   // Amber -> Red
            ((16, 185, 129), (5, 150, 105)),   // Emerald -> Teal
            ((168, 85, 247), (236, 72, 153)),  // Purple -> Rose
            ((244, 63, 94), (251, 146, 60))    // Rose -> Orange
        ]
        let chosenPalette = palettes[abs(paletteIndex) % palettes.count]

        let frontData = makePolaroidImageData(
            width: 270,
            height: 430,
            topRGB: chosenPalette.0,
            bottomRGB: chosenPalette.1,
            isBackside: false
        )
        let backData = (index % 2 == 0) ? makePolaroidImageData(
            width: 270,
            height: 430,
            topRGB: chosenPalette.1,
            bottomRGB: chosenPalette.0,
            isBackside: true
        ) : nil

        let daysAgo = TimeInterval(-(index + 1 + paletteIndex) * 86400 * 5)
        let capturedAt = Date(timeIntervalSinceNow: daysAgo)
        let ocrDate = Calendar.current.date(byAdding: .day, value: -1, to: capturedAt)

        let formats: [FilmFormat] = [.mini, .square, .wide]
        let chosenFormat = formats[index % formats.count]

        let item = ChekiItem(
            frontImageData: frontData,
            backImageData: backData,
            capturedAt: capturedAt,
            ocrDate: ocrDate,
            isDateWrittenToAlbum: index == 0,
            filmFormat: chosenFormat,
            detectedAspectRatio: chosenFormat.aspectRatio,
            borderInsetRatio: 0.0,
            detectionMethod: .visionNative,
            processingState: .completed,
            isSyncedToPhotoLibrary: index == 0,
            idolMember: member
        )

        let sampleEvents = [
            "幕張メッセ リアルミート＆グリート",
            "パシフィコ横浜 個別握手会",
            "有明アリーナ 生誕祭特別特典会",
            "東京ビッグサイト リアルサイン会"
        ]
        let sampleNotes = [
            "今天穿了超可愛的浴衣！聊了上週演唱會的感想，還畫了小愛心 ☆",
            "第一次抽到第一部，精神超好，約好了下次巡演見！",
            "生誕祭限定造型拍立得，背面寫了滿滿的感謝留言，太珍貴了！",
            "雙人比愛心成功！燈光很自然，邊框裁切也超正。"
        ]
        let sampleTags = [
            ["#推し", "#浴衣", "#ミートアンドグリート"],
            ["#生誕祭", "#神対応", "#チェキ"],
            ["#握手会", "#新衣装", "#直筆サイン"]
        ]

        let memo = ChekiMemo(
            eventName: sampleEvents[(index + paletteIndex) % sampleEvents.count],
            noteText: sampleNotes[(index + paletteIndex) % sampleNotes.count],
            hashtags: sampleTags[(index + paletteIndex) % sampleTags.count],
            chekiItem: item
        )
        item.memo = memo

        return item
    }

    // MARK: Realistic Polaroid Card Image Generator

    /// 使用 CoreGraphics 產生具備拍立得白邊相紙比例（上窄白邊、下寬下巴、中央漸層相片窗）的擬真測試圖
    private static func makePolaroidImageData(
        width: Int,
        height: Int,
        topRGB: (UInt8, UInt8, UInt8),
        bottomRGB: (UInt8, UInt8, UInt8),
        isBackside: Bool
    ) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // 1. 相紙基底色（正面溫暖白框 #FAF9F6，背面深灰膠帶感或淺背紙）
        if isBackside {
            context.setFillColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1.0)
        } else {
            context.setFillColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1.0)
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 2. 內部影像窗（模擬 Instax Mini 86x54mm 的上下左右邊距）
        let sideMargin = CGFloat(width) * 0.075
        let topMargin = CGFloat(height) * 0.065
        let bottomChin = CGFloat(height) * 0.22
        let photoRect = CGRect(
            x: sideMargin,
            y: bottomChin, // CoreGraphics 原點在左下，y = bottomChin 代表下方留寬下巴
            width: CGFloat(width) - sideMargin * 2,
            height: CGFloat(height) - topMargin - bottomChin
        )

        context.saveGState()
        context.addRect(photoRect)
        context.clip()

        let colors = [
            CGColor(
                red: CGFloat(topRGB.0) / 255.0,
                green: CGFloat(topRGB.1) / 255.0,
                blue: CGFloat(topRGB.2) / 255.0,
                alpha: isBackside ? 0.28 : 1.0
            ),
            CGColor(
                red: CGFloat(bottomRGB.0) / 255.0,
                green: CGFloat(bottomRGB.1) / 255.0,
                blue: CGFloat(bottomRGB.2) / 255.0,
                alpha: isBackside ? 0.18 : 1.0
            )
        ] as CFArray

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: photoRect.minX, y: photoRect.maxY),
                end: CGPoint(x: photoRect.maxX, y: photoRect.minY),
                options: []
            )
        }

        if !isBackside {
            // 繪製柔和散景光斑與人物剪影，使相冊封面與 Hero 大圖更具辨識度
            context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16)
            context.fillEllipse(in: CGRect(
                x: photoRect.minX + photoRect.width * 0.62,
                y: photoRect.minY + photoRect.height * 0.68,
                width: photoRect.width * 0.32,
                height: photoRect.width * 0.32
            ))
            context.fillEllipse(in: CGRect(
                x: photoRect.minX + photoRect.width * 0.10,
                y: photoRect.minY + photoRect.height * 0.52,
                width: photoRect.width * 0.22,
                height: photoRect.width * 0.22
            ))

            // 偶像半身輪廓裝飾
            context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.26)
            let headDiameter = photoRect.width * 0.34
            context.fillEllipse(in: CGRect(
                x: photoRect.midX - headDiameter / 2,
                y: photoRect.minY + photoRect.height * 0.42,
                width: headDiameter,
                height: headDiameter
            ))
            let shouldersWidth = photoRect.width * 0.68
            let shouldersHeight = photoRect.height * 0.44
            context.fillEllipse(in: CGRect(
                x: photoRect.midX - shouldersWidth / 2,
                y: photoRect.minY - shouldersHeight * 0.22,
                width: shouldersWidth,
                height: shouldersHeight
            ))
        }
        context.restoreGState()

        // 3. 在下方下巴模擬手寫簽名/日期色塊線條
        context.setFillColor(
            red: CGFloat(bottomRGB.0) / 255.0,
            green: CGFloat(bottomRGB.1) / 255.0,
            blue: CGFloat(bottomRGB.2) / 255.0,
            alpha: 0.65
        )
        let chinLineRect = CGRect(
            x: sideMargin * 1.4,
            y: bottomChin * 0.42,
            width: CGFloat(width) * 0.45,
            height: 6
        )
        context.fill(chinLineRect)

        guard let cgImage = context.makeImage() else { return nil }

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
    @MainActor
    func withPreviewModelContainer() -> some View {
        let container = try! ModelContainerProvider.preview()
        return self.modelContainer(container)
    }
}
