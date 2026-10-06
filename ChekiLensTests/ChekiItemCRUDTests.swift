import XCTest
import SwiftData
@testable import ChekiLens

// MARK: - ChekiItemCRUDTests

/// 驗證 ChekiItem 的完整 CRUD、正反雙面綁定與級聯刪除行為
@MainActor
final class ChekiItemCRUDTests: XCTestCase {

    // MARK: Setup

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        // 使用記憶體容器，確保每個測試互相隔離
        container = try ModelContainerProvider.preview(withSampleData: false)
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    // MARK: - Create Tests

    func test_createChekiItem_defaultValues() throws {
        // Arrange & Act
        let item = ChekiItem()
        context.insert(item)
        try context.save()

        // Assert
        let fetched = try context.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(fetched.count, 1, "應只有一張 ChekiItem")
        let saved = try XCTUnwrap(fetched.first)
        XCTAssertEqual(saved.filmFormat, .mini, "預設應為 Mini 規格")
        XCTAssertEqual(saved.processingState, .unprocessed, "預設狀態為 unprocessed")
        XCTAssertFalse(saved.hasBothSides, "預設無背面資料")
        XCTAssertNil(saved.ocrDate, "預設無 OCR 日期")
        XCTAssertEqual(saved.borderInsetRatio, 0.0, accuracy: 0.001, "預設邊界偏移為 0")
    }

    func test_createChekiItem_withAllFields() throws {
        // Arrange
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let ocrDate  = Date(timeIntervalSince1970: 1_699_900_000)
        let frontData = Data([0xFF, 0xD8, 0xFF])  // 假 JPEG header
        let backData  = Data([0x89, 0x50, 0x4E])  // 假 PNG header

        // Act
        let item = ChekiItem(
            frontImageData: frontData,
            backImageData: backData,
            capturedAt: testDate,
            ocrDate: ocrDate,
            filmFormat: .square,
            borderInsetRatio: -0.02,
            detectionMethod: .visionNative,
            processingState: .completed
        )
        context.insert(item)
        try context.save()

        // Assert
        let fetched = try context.fetch(FetchDescriptor<ChekiItem>())
        let saved = try XCTUnwrap(fetched.first)
        XCTAssertEqual(saved.frontImageData, frontData)
        XCTAssertEqual(saved.backImageData, backData)
        XCTAssertEqual(saved.capturedAt, testDate)
        XCTAssertEqual(saved.ocrDate, ocrDate)
        XCTAssertEqual(saved.filmFormat, .square)
        XCTAssertEqual(saved.borderInsetRatio, -0.02, accuracy: 0.001)
        XCTAssertEqual(saved.detectionMethod, .visionNative)
        XCTAssertEqual(saved.processingState, .completed)
        XCTAssertTrue(saved.hasBothSides, "正反面均有資料應為 true")
    }

    // MARK: - Read / Fetch Tests

    func test_fetchChekiItems_sortByDisplayDate() throws {
        // Arrange：插入 3 張不同日期的 ChekiItem
        let dates = [
            Date(timeIntervalSince1970: 1_600_000_000),
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_650_000_000)
        ]
        for date in dates {
            let item = ChekiItem(capturedAt: date)
            context.insert(item)
        }
        try context.save()

        // Act：按 capturedAt 升冪取得
        let descriptor = FetchDescriptor<ChekiItem>(
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
        let fetched = try context.fetch(descriptor)

        // Assert
        XCTAssertEqual(fetched.count, 3)
        XCTAssertLessThan(fetched[0].capturedAt, fetched[1].capturedAt)
        XCTAssertLessThan(fetched[1].capturedAt, fetched[2].capturedAt)
    }

    func test_fetchChekiItems_filterByProcessingState() throws {
        // Arrange
        let completed = ChekiItem(processingState: .completed)
        let pending   = ChekiItem(processingState: .unprocessed)
        let detecting = ChekiItem(processingState: .detecting)
        for item in [completed, pending, detecting] { context.insert(item) }
        try context.save()

        // Act
        let targetStateRaw = ProcessingState.completed.rawValue
        let descriptor = FetchDescriptor<ChekiItem>(
            predicate: #Predicate { $0.processingStateRaw == targetStateRaw }
        )
        let fetched = try context.fetch(descriptor)

        // Assert
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.processingState, .completed)
    }

    // MARK: - Update Tests

    func test_updateChekiItem_processingState() throws {
        // Arrange
        let item = ChekiItem(processingState: .unprocessed)
        context.insert(item)
        try context.save()

        // Act
        item.processingState = .completed
        item.ocrDate = Date()
        try context.save()

        // Assert
        let fetched = try context.fetch(FetchDescriptor<ChekiItem>())
        let saved = try XCTUnwrap(fetched.first)
        XCTAssertEqual(saved.processingState, .completed)
        XCTAssertNotNil(saved.ocrDate)
    }

    func test_updateChekiItem_displayDatePriority() throws {
        // Arrange：ocrDate 存在時，displayDate 應回傳 ocrDate
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let ocrDate    = Date(timeIntervalSince1970: 1_699_000_000) // 比 capturedAt 更早
        let item = ChekiItem(capturedAt: capturedAt, ocrDate: ocrDate)
        context.insert(item)
        try context.save()

        // Assert
        XCTAssertEqual(item.displayDate, ocrDate, "有 ocrDate 時應優先回傳 ocrDate")

        // Act：移除 ocrDate
        item.ocrDate = nil
        XCTAssertEqual(item.displayDate, capturedAt, "無 ocrDate 時應回傳 capturedAt")
    }

    // MARK: - Delete Tests

    func test_deleteChekiItem() throws {
        // Arrange
        let item = ChekiItem()
        context.insert(item)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChekiItem>()).count, 1)

        // Act
        context.delete(item)
        try context.save()

        // Assert
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChekiItem>()).count, 0)
    }

    // MARK: - Dual Side Binding Tests

    func test_dualSideBiding_backImageIndependent() throws {
        // 驗證正反面圖片可獨立更新
        let frontData = Data([0x01, 0x02])
        let backData  = Data([0x03, 0x04])

        let item = ChekiItem(frontImageData: frontData)
        context.insert(item)
        try context.save()
        XCTAssertFalse(item.hasBothSides)

        // 新增背面
        item.backImageData = backData
        try context.save()
        XCTAssertTrue(item.hasBothSides)

        // 移除背面
        item.backImageData = nil
        try context.save()
        XCTAssertFalse(item.hasBothSides)
        XCTAssertEqual(item.frontImageData, frontData, "正面不應受背面操作影響")
    }

    // MARK: - Cascade Delete Tests

    func test_cascadeDelete_memberDeletesChekiItems() throws {
        // Arrange
        let group  = IdolGroup(name: "TestGroup", sortOrder: 0)
        let member = IdolMember(stageName: "TestMember", group: group)
        let item1  = ChekiItem(idolMember: member)
        let item2  = ChekiItem(idolMember: member)
        member.chekiItems = [item1, item2]
        group.members = [member]

        context.insert(group)
        context.insert(member)
        context.insert(item1)
        context.insert(item2)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<ChekiItem>()).count, 2)

        // Act：刪除成員 → 應級聯刪除 chekiItems
        context.delete(member)
        try context.save()

        // Assert
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChekiItem>()).count, 0,
                       "刪除成員後其 ChekiItem 應被級聯刪除")
        XCTAssertEqual(try context.fetch(FetchDescriptor<IdolGroup>()).count, 1,
                       "刪除成員不應影響所屬團體")
    }

    func test_cascadeDelete_groupDeletesMembersAndChekiItems() throws {
        // Arrange
        let group  = IdolGroup(name: "TestGroup")
        let member = IdolMember(stageName: "TestMember", group: group)
        let item   = ChekiItem(idolMember: member)
        member.chekiItems = [item]
        group.members = [member]

        context.insert(group)
        context.insert(member)
        context.insert(item)
        try context.save()

        // Act：刪除團體 → 應級聯刪除 members + 所有 chekiItems
        context.delete(group)
        try context.save()

        // Assert
        XCTAssertEqual(try context.fetch(FetchDescriptor<IdolGroup>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IdolMember>()).count, 0,
                       "刪除團體後成員應被級聯刪除")
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChekiItem>()).count, 0,
                       "刪除團體後所有 ChekiItem 應被級聯刪除")
    }

    func test_cascadeDelete_chekiItemDeletesMemo() throws {
        // Arrange
        let item = ChekiItem(processingState: .completed)
        let memo = ChekiMemo(
            eventName: "握手会",
            noteText: "テストメモ",
            hashtags: ["#test"],
            chekiItem: item
        )
        item.memo = memo
        context.insert(item)
        context.insert(memo)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<ChekiMemo>()).count, 1)

        // Act：刪除 ChekiItem → memo 應被級聯刪除
        context.delete(item)
        try context.save()

        // Assert
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChekiMemo>()).count, 0,
                       "刪除 ChekiItem 後 ChekiMemo 應被級聯刪除")
    }
}

// MARK: - ChekiMemoTests

@MainActor
final class ChekiMemoTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainerProvider.preview(withSampleData: false)
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func test_memo_isEmpty() throws {
        let empty = ChekiMemo()
        XCTAssertTrue(empty.isEmpty, "空建構應為 isEmpty == true")

        let withEvent = ChekiMemo(eventName: "握手会")
        XCTAssertFalse(withEvent.isEmpty)
    }

    func test_memo_hashtagsFormatted() throws {
        let memo = ChekiMemo(hashtags: ["#日向坂46", "#推し"])
        XCTAssertEqual(memo.hashtagsFormatted, "#日向坂46 #推し")
    }

    func test_memo_updateMethod() throws {
        let memo = ChekiMemo(eventName: "初期")
        let originalUpdatedAt = memo.updatedAt

        // 稍微延遲確保 updatedAt 差異
        Thread.sleep(forTimeInterval: 0.01)
        memo.update(eventName: "更新後", noteText: "新文字")

        XCTAssertEqual(memo.eventName, "更新後")
        XCTAssertEqual(memo.noteText, "新文字")
        XCTAssertGreaterThan(memo.updatedAt, originalUpdatedAt,
                             "update() 後 updatedAt 應被刷新")
    }
}

// MARK: - IdolGroupTests

@MainActor
final class IdolGroupTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainerProvider.preview(withSampleData: false)
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func test_group_totalChekiCount() throws {
        // Arrange
        let group   = IdolGroup(name: "Group")
        let member1 = IdolMember(stageName: "A", group: group)
        let member2 = IdolMember(stageName: "B", group: group)
        let items1  = [ChekiItem(), ChekiItem()]
        let items2  = [ChekiItem()]
        member1.chekiItems = items1
        member2.chekiItems = items2
        group.members = [member1, member2]

        // Assert
        XCTAssertEqual(group.totalChekiCount, 3, "總張數應為所有成員的加總")
    }

    func test_group_sortedMembers() throws {
        // Arrange
        let group   = IdolGroup(name: "Group")
        let memberA = IdolMember(stageName: "Zeta", sortOrder: 2, group: group)
        let memberB = IdolMember(stageName: "Alpha", sortOrder: 0, group: group)
        let memberC = IdolMember(stageName: "Beta",  sortOrder: 1, group: group)
        group.members = [memberA, memberB, memberC]

        // Assert
        let sorted = group.sortedMembers
        XCTAssertEqual(sorted.map(\.stageName), ["Alpha", "Beta", "Zeta"])
    }
}

// MARK: - PreviewDataTests

@MainActor
final class PreviewDataTests: XCTestCase {

    func test_previewData_populatesCorrectly() throws {
        // Arrange
        let container = try ModelContainerProvider.preview(withSampleData: true)
        let context = container.mainContext

        // Assert：應有 3 個團體（日向坂46、乃木坂46、櫻坂46）
        let groups = try context.fetch(FetchDescriptor<IdolGroup>())
        XCTAssertEqual(groups.count, 3, "PreviewData 應生成 3 個偶像團體")

        // 應有 6 位成員
        let members = try context.fetch(FetchDescriptor<IdolMember>())
        XCTAssertEqual(members.count, 6, "PreviewData 應生成 6 位偶像成員")

        // 應有 13 張拍立得（12 張已歸類 + 1 張未分類）
        let items = try context.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(items.count, 13, "PreviewData 應生成 13 張測試拍立得")
        XCTAssertEqual(items.filter { $0.idolMember == nil }.count, 1, "應包含 1 張未分類拍立得供篩選測試")
        XCTAssertGreaterThan(items.filter(\.hasBothSides).count, 5, "應包含多張正反雙面拍立得")

        // 應有多條含 #標籤 的備忘錄
        let memos = try context.fetch(FetchDescriptor<ChekiMemo>())
        XCTAssertGreaterThanOrEqual(memos.count, 10, "PreviewData 應生成豐富的活動與對話備忘")

        // 測試 seedIfEmpty 冪等性（重複呼叫不會重複塞入資料）
        PreviewData.seedIfEmpty(into: context)
        let itemsAfterReseed = try context.fetch(FetchDescriptor<ChekiItem>())
        XCTAssertEqual(itemsAfterReseed.count, 13, "seedIfEmpty 在已有資料時不應重複新增")
    }

    func test_libraryView_matchesSearch() throws {
        let container = try ModelContainerProvider.preview(withSampleData: true)
        let context = container.mainContext
        let items = try context.fetch(FetchDescriptor<ChekiItem>())

        // 搜尋團體名稱
        let hinataItems = items.filter { LibraryView.matchesSearch(item: $0, query: "日向坂46") }
        XCTAssertEqual(hinataItems.count, 7, "日向坂46 應有 7 張拍立得")

        // 搜尋成員姓名
        let hinaItems = items.filter { LibraryView.matchesSearch(item: $0, query: "河田陽菜") }
        XCTAssertEqual(hinaItems.count, 3, "河田陽菜 應有 3 張拍立得")

        // 搜尋 #標籤
        let hashtagItems = items.filter { LibraryView.matchesSearch(item: $0, query: "#神對應") }
        XCTAssertGreaterThanOrEqual(hashtagItems.count, 2, "搜尋 #神對應 應能命中對應備忘錄的拍立得")

        // 搜尋未分類
        let uncategorized = items.filter { LibraryView.matchesSearch(item: $0, query: "未分類") }
        XCTAssertEqual(uncategorized.count, 1, "搜尋「未分類」應命中 1 張未歸類拍立得")
    }
}

