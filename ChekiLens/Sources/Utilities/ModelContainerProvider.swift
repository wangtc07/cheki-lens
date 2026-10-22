import SwiftUI
import SwiftData
import CoreGraphics
import ImageIO
import OSLog

// MARK: - ModelContainerProvider

/// 統一管理 ModelContainer 生命週期的服務層
///
/// 提供：
/// 1. `live`：持久化容器（自動依據 Pro 資格與使用者偏好動態啟用 CloudKit 雲端同步或純本機模式）
/// 2. `createContainer(enableCloudKit:storeURL:)`：按需創建指定同步模式之容器
/// 3. `migrateData(from:to:)`：跨 Store 資料合併與遷移引擎
/// 4. `preview`：記憶體容器（SwiftUI Preview / XCTest 使用）
public enum ModelContainerProvider {

    /// 統一 Schema 定義
    public static let sharedSchema = Schema([
        ChekiItem.self,
        IdolGroup.self,
        IdolMember.self,
        ChekiMemo.self
    ])

    // MARK: Live Container

    /// 正式持久化 ModelContainer
    /// 依據 Pro 買斷狀態與 iCloud 同步開關決定是否連接 CloudKit
    @MainActor
    public static var live: ModelContainer = {
        let enableCloudKit = shouldEnableCloudKitSync()
        return createContainerWithFallback(enableCloudKit: enableCloudKit)
    }()

    /// 判定當前是否應啟用 CloudKit 雲端同步
    public static func shouldEnableCloudKitSync() -> Bool {
        let isPro = UserDefaults.standard.bool(forKey: "isProLifetimeUnlocked")
        let isSyncEnabled = UserDefaults.standard.object(forKey: "isICloudSyncEnabled") as? Bool ?? true
        return isPro && isSyncEnabled
    }

    /// 建立 ModelConfiguration
    public static func makeConfiguration(
        enableCloudKit: Bool,
        isStoredInMemoryOnly: Bool = false,
        storeURL: URL? = nil
    ) -> ModelConfiguration {
        if let storeURL {
            return ModelConfiguration(
                schema: sharedSchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: enableCloudKit ? .automatic : .none
            )
        } else {
            return ModelConfiguration(
                schema: sharedSchema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                allowsSave: true,
                groupContainer: .none,
                cloudKitDatabase: enableCloudKit ? .automatic : .none
            )
        }
    }

    /// 建立指定同步模式之 ModelContainer
    @MainActor
    public static func createContainer(
        enableCloudKit: Bool,
        storeURL: URL? = nil
    ) throws -> ModelContainer {
        let config = makeConfiguration(enableCloudKit: enableCloudKit, isStoredInMemoryOnly: false, storeURL: storeURL)
        return try ModelContainer(for: sharedSchema, configurations: [config])
    }

    /// 嘗試建立容器，若 CloudKit 初始化遭遇網路/環境錯誤則優雅降級為純本機 Store
    @MainActor
    public static func createContainerWithFallback(
        enableCloudKit: Bool,
        storeURL: URL? = nil
    ) -> ModelContainer {
        if enableCloudKit {
            do {
                return try createContainer(enableCloudKit: true, storeURL: storeURL)
            } catch {
                let logger = Logger(subsystem: "com.chekilens.app", category: "ModelContainerProvider")
                logger.error("⚠️ CloudKit 容器初始化失敗，降級為純本機 Store: \(error.localizedDescription)")
            }
        }

        do {
            return try createContainer(enableCloudKit: false, storeURL: storeURL)
        } catch {
            fatalError("❌ 本機 ModelContainer 初始化失敗：\(error.localizedDescription)")
        }
    }

    /// 跨 Container 資料遷移引擎（例如從獨立本機 Store 遷移複製至 CloudKit Store）
    @MainActor
    @discardableResult
    public static func migrateData(
        from sourceContainer: ModelContainer,
        to targetContainer: ModelContainer
    ) throws -> (groups: Int, members: Int, chekis: Int, memos: Int) {
        let sourceContext = sourceContainer.mainContext
        let targetContext = targetContainer.mainContext

        let sourceGroups = try sourceContext.fetch(FetchDescriptor<IdolGroup>())
        let existingTargetGroupIDs = Set((try targetContext.fetch(FetchDescriptor<IdolGroup>())).map(\.id))

        var migratedGroups = 0
        for group in sourceGroups where !existingTargetGroupIDs.contains(group.id) {
            let newGroup = IdolGroup(
                id: group.id,
                name: group.name,
                colorHex: group.colorHex,
                createdAt: group.createdAt,
                sortOrder: group.sortOrder,
                lastModifiedAt: group.lastModifiedAt
            )
            targetContext.insert(newGroup)
            migratedGroups += 1
        }

        let sourceMembers = try sourceContext.fetch(FetchDescriptor<IdolMember>())
        let existingTargetMemberIDs = Set((try targetContext.fetch(FetchDescriptor<IdolMember>())).map(\.id))

        var migratedMembers = 0
        for member in sourceMembers where !existingTargetMemberIDs.contains(member.id) {
            let newMember = IdolMember(
                id: member.id,
                stageName: member.stageName,
                realName: member.realName,
                avatarImageData: member.avatarImageData,
                tags: member.tags,
                createdAt: member.createdAt,
                sortOrder: member.sortOrder,
                lastModifiedAt: member.lastModifiedAt
            )
            targetContext.insert(newMember)
            migratedMembers += 1
        }

        let sourceItems = try sourceContext.fetch(FetchDescriptor<ChekiItem>())
        let existingTargetItems = try targetContext.fetch(FetchDescriptor<ChekiItem>())
        let targetItemsByID = Dictionary(uniqueKeysWithValues: existingTargetItems.map { ($0.id, $0) })

        var migratedChekis = 0
        for item in sourceItems {
            if let existing = targetItemsByID[item.id] {
                // 已存在項目：以 LWW (Last-Write-Wins) 規則合併衝突
                if existing.mergeLWW(with: item) {
                    migratedChekis += 1
                }
            } else {
                let newItem = ChekiItem(
                    id: item.id,
                    frontImageData: item.frontImageData,
                    backImageData: item.backImageData,
                    originalFrontImageData: item.originalFrontImageData,
                    originalBackImageData: item.originalBackImageData,
                    thumbnailData: item.thumbnailData,
                    capturedAt: item.capturedAt,
                    ocrDate: item.ocrDate,
                    originalCapturedAt: item.originalCapturedAt,
                    isJudgedDateManuallySet: item.isJudgedDateManuallySet,
                    isDateWrittenToAlbum: item.isDateWrittenToAlbum,
                    deletedAt: item.deletedAt,
                    lastModifiedAt: item.lastModifiedAt,
                    filmFormat: item.filmFormat,
                    detectedAspectRatio: item.detectedAspectRatio,
                    borderInsetRatio: item.borderInsetRatio,
                    perspectivePointsJSON: item.perspectivePointsJSON,
                    backPerspectivePointsJSON: item.backPerspectivePointsJSON,
                    detectionMethod: item.detectionMethod,
                    processingState: item.processingState,
                    isSyncedToPhotoLibrary: item.isSyncedToPhotoLibrary,
                    frontAssetIdentifier: item.frontAssetIdentifier,
                    backAssetIdentifier: item.backAssetIdentifier,
                    cloudIdentifier: item.cloudIdentifier,
                    backCloudIdentifier: item.backCloudIdentifier
                )
                targetContext.insert(newItem)
                migratedChekis += 1
            }
        }

        let sourceMemos = try sourceContext.fetch(FetchDescriptor<ChekiMemo>())
        let existingTargetMemos = try targetContext.fetch(FetchDescriptor<ChekiMemo>())
        let targetMemosByID = Dictionary(uniqueKeysWithValues: existingTargetMemos.map { ($0.id, $0) })

        var migratedMemos = 0
        for memo in sourceMemos {
            if let existing = targetMemosByID[memo.id] {
                // 已存在備忘：以 LWW 規則合併衝突
                if existing.mergeLWW(with: memo) {
                    migratedMemos += 1
                }
            } else {
                let newMemo = ChekiMemo(
                    id: memo.id,
                    eventName: memo.eventName,
                    noteText: memo.noteText,
                    hashtags: memo.hashtags,
                    createdAt: memo.createdAt,
                    updatedAt: memo.updatedAt,
                    lastModifiedAt: memo.lastModifiedAt
                )
                targetContext.insert(newMemo)
                migratedMemos += 1
            }
        }

        try targetContext.save()
        return (migratedGroups, migratedMembers, migratedChekis, migratedMemos)
    }

    // MARK: Preview / Test Container

    /// 記憶體版 ModelContainer（用於 SwiftUI Preview 與 XCTestCase）
    ///
    /// 呼叫後自動填入 `PreviewData.populate(into:)` 假資料
    @MainActor
    public static func preview(withSampleData: Bool = true) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: sharedSchema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: sharedSchema, configurations: [config])

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

        let daysAgo = TimeInterval(-(index + 1 + paletteIndex) * 86400 * 5)
        let capturedAt = Date(timeIntervalSinceNow: daysAgo)
        let ocrDate = Calendar.current.date(byAdding: .day, value: -1, to: capturedAt)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy.MM.dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateString = dateFormatter.string(from: ocrDate ?? capturedAt)

        let backMessages = [
            "いつも応援ありがとう！♡\n今日も会えて嬉しかったよ☆\nまた来週のライブでね！",
            "チェキありがとう〜！\n浴衣ほめてくれて嬉しい♪\n絶対また愛に来てね♡",
            "生誕祭ありがとう！！\nこれからもずっと推してね☆\n大好きだよ〜♡",
            "初選抜お祝いありがとう！\nたくさん話せて楽しかった♪\n風邪ひかないでね！"
        ]
        let chosenBackMessage = backMessages[(index + paletteIndex) % backMessages.count]

        let frontData = makePolaroidImageData(
            width: 360,
            height: 572,
            topRGB: chosenPalette.0,
            bottomRGB: chosenPalette.1,
            isBackside: false,
            signatureText: "\(member.stageName) ♡",
            dateText: dateString
        )
        let backData = (index % 2 == 0) ? makePolaroidImageData(
            width: 360,
            height: 572,
            topRGB: chosenPalette.1,
            bottomRGB: chosenPalette.0,
            isBackside: true,
            signatureText: "\(member.stageName) 直筆裏書き",
            dateText: dateString,
            backMessage: chosenBackMessage
        ) : nil

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
            ["#推し", "#浴衣", "#ミートアンドグリート", "#最愛"],
            ["#生誕祭", "#神対応", "#チェキ"],
            ["#握手会", "#新衣装", "#直筆サイン", "#最愛"]
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

    /// 使用 UIGraphicsImageRenderer 產生具備拍立得白邊相紙比例、正面手寫日期簽名與背面手寫留言的擬真測試圖
    static func makePolaroidImageData(
        width: Int,
        height: Int,
        topRGB: (UInt8, UInt8, UInt8),
        bottomRGB: (UInt8, UInt8, UInt8),
        isBackside: Bool,
        signatureText: String = "Cheki ♡",
        dateText: String = "2026.09.24",
        backMessage: String = "いつも応援ありがとう！♡\nまた来週のライブで会おうね☆"
    ) -> Data? {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { rendererCtx in
            let context = rendererCtx.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            // 1. 相紙基底色
            if isBackside {
                context.setFillColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
            } else {
                context.setFillColor(red: 0.99, green: 0.99, blue: 0.98, alpha: 1.0)
            }
            context.fill(CGRect(origin: .zero, size: size))

            let sideMargin = CGFloat(width) * 0.075
            let topMargin = CGFloat(height) * 0.065
            let bottomChin = CGFloat(height) * 0.22
            let photoRect = CGRect(
                x: sideMargin,
                y: topMargin,
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
                    alpha: isBackside ? 0.16 : 1.0
                ),
                CGColor(
                    red: CGFloat(bottomRGB.0) / 255.0,
                    green: CGFloat(bottomRGB.1) / 255.0,
                    blue: CGFloat(bottomRGB.2) / 255.0,
                    alpha: isBackside ? 0.10 : 1.0
                )
            ] as CFArray

            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: photoRect.minX, y: photoRect.minY),
                    end: CGPoint(x: photoRect.maxX, y: photoRect.maxY),
                    options: []
                )
            }

            if !isBackside {
                // 正面：柔和散景光斑與人物半身輪廓
                context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18)
                context.fillEllipse(in: CGRect(
                    x: photoRect.minX + photoRect.width * 0.62,
                    y: photoRect.minY + photoRect.height * 0.12,
                    width: photoRect.width * 0.28,
                    height: photoRect.width * 0.28
                ))
                context.fillEllipse(in: CGRect(
                    x: photoRect.minX + photoRect.width * 0.10,
                    y: photoRect.minY + photoRect.height * 0.24,
                    width: photoRect.width * 0.20,
                    height: photoRect.width * 0.20
                ))

                context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.28)
                let headDiameter = photoRect.width * 0.34
                context.fillEllipse(in: CGRect(
                    x: photoRect.midX - headDiameter / 2,
                    y: photoRect.minY + photoRect.height * 0.24,
                    width: headDiameter,
                    height: headDiameter
                ))
                let shouldersWidth = photoRect.width * 0.68
                let shouldersHeight = photoRect.height * 0.46
                context.fillEllipse(in: CGRect(
                    x: photoRect.midX - shouldersWidth / 2,
                    y: photoRect.minY + photoRect.height * 0.60,
                    width: shouldersWidth,
                    height: shouldersHeight
                ))
            } else {
                // 背面：頂部警告字樣 + 中央手寫感謝留言 + 底部 FUJIFILM instax 標誌
                let warnAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: max(9, CGFloat(width) * 0.032), weight: .semibold),
                    .foregroundColor: UIColor.secondaryLabel
                ]
                NSAttributedString(string: "Don't put in mouth.", attributes: warnAttrs)
                    .draw(at: CGPoint(x: photoRect.minX + 16, y: photoRect.minY + 14))

                let msgParagraph = NSMutableParagraphStyle()
                msgParagraph.lineSpacing = 6
                let msgAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: max(13, CGFloat(width) * 0.048), weight: .semibold),
                    .foregroundColor: UIColor(red: 0.18, green: 0.16, blue: 0.28, alpha: 0.92),
                    .paragraphStyle: msgParagraph
                ]
                NSAttributedString(string: backMessage, attributes: msgAttrs)
                    .draw(in: CGRect(
                        x: photoRect.minX + 18,
                        y: photoRect.minY + photoRect.height * 0.26,
                        width: photoRect.width - 36,
                        height: photoRect.height * 0.55
                    ))

                let brandAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: max(10, CGFloat(width) * 0.036), weight: .bold),
                    .foregroundColor: UIColor.tertiaryLabel
                ]
                NSAttributedString(string: "FUJIFILM instax", attributes: brandAttrs)
                    .draw(at: CGPoint(x: photoRect.midX - CGFloat(width) * 0.18, y: photoRect.maxY - 28))
            }
            context.restoreGState()

            // 3. 下巴區域：左側偶像簽名、右側手寫日期
            let chinTopY = CGFloat(height) - bottomChin
            let sigAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(12, CGFloat(width) * 0.045), weight: .bold),
                .foregroundColor: UIColor(
                    red: CGFloat(topRGB.0) / 255.0 * 0.75,
                    green: CGFloat(topRGB.1) / 255.0 * 0.75,
                    blue: CGFloat(topRGB.2) / 255.0 * 0.75,
                    alpha: 0.92
                )
            ]
            NSAttributedString(string: signatureText, attributes: sigAttrs)
                .draw(at: CGPoint(x: sideMargin + 6, y: chinTopY + bottomChin * 0.24))

            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: max(11, CGFloat(width) * 0.040), weight: .semibold),
                .foregroundColor: UIColor(white: 0.25, alpha: 0.9)
            ]
            NSAttributedString(string: dateText, attributes: dateAttrs)
                .draw(at: CGPoint(x: sideMargin + 6, y: chinTopY + bottomChin * 0.56))
        }

        return image.pngData()
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
