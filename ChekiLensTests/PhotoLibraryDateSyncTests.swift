import XCTest
import SwiftData
import Photos
@testable import ChekiLens

@MainActor
final class PhotoLibraryDateSyncTests: XCTestCase {

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

    func test_lockJudgedDate_setsBothCapturedAtAndOCRDate_andLocks() throws {
        let initialDate = Date(timeIntervalSince1970: 1_700_000_000)
        let item = ChekiItem(capturedAt: initialDate)
        context.insert(item)
        try context.save()

        XCTAssertEqual(item.displayDate, initialDate)
        XCTAssertNil(item.ocrDate)
        XCTAssertFalse(item.isJudgedDateManuallySet)
        XCTAssertEqual(item.appOriginalCaptureDate, initialDate)

        // 使用者在 ChekiInfoView 修改日期
        let newDate = Date(timeIntervalSince1970: 1_720_000_000)
        item.lockJudgedDate(newDate)
        try context.save()

        XCTAssertEqual(item.displayDate, newDate)
        XCTAssertEqual(item.capturedAt, newDate)
        XCTAssertEqual(item.ocrDate, newDate)
        XCTAssertTrue(item.isJudgedDateManuallySet)
        XCTAssertEqual(item.appOriginalCaptureDate, initialDate, "修改拍攝日期不得破壞原始快門或匯入時間 (appOriginalCaptureDate)")

        // 背景自動 OCR 嘗試覆寫時應被鎖定防禦
        let ocrAttempt = Date(timeIntervalSince1970: 1_730_000_000)
        item.applyAutomaticJudgedDate(ocrAttempt, preservingTimeFrom: item.appOriginalCaptureDate)
        XCTAssertEqual(item.displayDate, newDate, "手動指定並鎖定後，背景自動 OCR 不得再覆寫日期")
    }

    func test_pairedSystemAlbumDates_withManualJudgedDate() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let manualDate = Date(timeIntervalSince1970: 1_715_000_000)

        let item = ChekiItem(capturedAt: originalDate)
        item.lockJudgedDate(manualDate)

        // sameSecond 策略
        let (frontSame, backSame) = item.pairedSystemAlbumDates(timelineStrategy: "sameSecond")
        XCTAssertEqual(frontSame, manualDate)
        XCTAssertEqual(backSame, manualDate)

        // plusOneSecond 策略
        let (frontPlus, backPlus) = item.pairedSystemAlbumDates(timelineStrategy: "plusOneSecond")
        XCTAssertEqual(frontPlus, manualDate)
        XCTAssertEqual(backPlus, manualDate.addingTimeInterval(1.0))
    }

    func test_syncItemDateToPhotoLibraryIfNeeded_skipsWhenNoCustomOrOCRDate() async throws {
        let item = ChekiItem()
        context.insert(item)
        try context.save()

        // 未手動改日期且無 OCR 日期
        let didSync = await PhotoLibraryManager.shared.syncItemDateToPhotoLibraryIfNeeded(item, modelContext: context)
        XCTAssertFalse(didSync, "無手動或 OCR 日期變更之拍立得不應觸發相簿日期修正")
    }

    func test_syncItemDateToPhotoLibraryIfNeeded_skipsWhenDeleted() async throws {
        let item = ChekiItem()
        item.lockJudgedDate(Date())
        item.softDelete()
        context.insert(item)
        try context.save()

        let didSync = await PhotoLibraryManager.shared.syncItemDateToPhotoLibraryIfNeeded(item, modelContext: context)
        XCTAssertFalse(didSync, "已移入垃圾桶（最近刪除）的拍立得不應同步至相簿")
    }
}
