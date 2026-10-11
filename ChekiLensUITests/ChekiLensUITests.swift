//
//  ChekiLensUITests.swift
//  ChekiLensUITests
//
//  以 XCUIElement.frame 斷言 chrome 尺寸與對齊，並把畫面截圖寫到 /tmp/cheki_ui。
//

import XCTest

extension XCTestCase {
    @MainActor
    func launchLibraryApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-hasCompletedOnboarding", "YES",
            "-appLanguageMode", "zh-Hant",
            "-appAppearanceMode", "light"
        ]
        app.launch()
        return app
    }

    @MainActor
    func saveAuditScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let dir = URL(fileURLWithPath: "/tmp/cheki_ui", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func assertCircleFramesMatch(
        _ first: XCUIElement,
        _ second: XCUIElement,
        expectedSide: CGFloat,
        tolerance: CGFloat = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let a = first.frame
        let b = second.frame
        XCTAssertEqual(a.width, a.height, accuracy: tolerance, "應為正圓 \(a)", file: file, line: line)
        XCTAssertEqual(b.width, b.height, accuracy: tolerance, "應為正圓 \(b)", file: file, line: line)
        XCTAssertEqual(a.width, expectedSide, accuracy: tolerance, "直徑應為 \(expectedSide)，實際 \(a.width)", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: tolerance, "兩顆圓鈕直徑應相同 \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: tolerance, "兩顆圓鈕應同一水平線 \(a) vs \(b)", file: file, line: line)
    }
}

final class ChekiLensUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Task 6.6.1：玻璃收成共用實作後，全部頁右上圓鈕仍維持 36 pt，且彼此對齊。
    @MainActor
    func testLibraryChromeCirclesShareFrame() throws {
        let app = launchLibraryApp()
        let camera = app.buttons["chrome.library.camera"]
        let filter = app.buttons["chrome.library.filter"]
        XCTAssertTrue(camera.waitForExistence(timeout: 12), "找不到相機圓鈕。畫面：\(app.debugDescription)")
        XCTAssertTrue(filter.waitForExistence(timeout: 4), "找不到篩選圓鈕")

        assertCircleFramesMatch(camera, filter, expectedSide: 36)
        saveAuditScreenshot(app, name: "task_6_6_1_library")
    }

    /// Task 6.6.2：日文下「完了」為圖示；inline 標題的「キャンセル」改為 xmark 後，標題留在導覽列中央。
    @MainActor
    func testJapaneseToolbarIconsKeepInlineTitleCentered() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-hasCompletedOnboarding", "YES",
            "-appLanguageMode", "ja",
            "-appAppearanceMode", "light",
            "-AppleLanguages", "(ja)"
        ]
        app.launch()

        let filter = app.buttons["chrome.library.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 12))
        filter.tap()

        let settingsButton = app.buttons["設定"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 4), "選單裡找不到設定。\(app.debugDescription)")
        settingsButton.tap()

        let confirm = app.buttons["chrome.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(confirm.frame.width, 52, "完成應為圖示鈕，實際寬度 \(confirm.frame.width)")
        XCTAssertEqual(confirm.label, "完了")
        saveAuditScreenshot(app, name: "task_6_6_2_settings_ja")
        confirm.tap()

        filter.tap()
        let createButton = app.buttons["グループ / メンバー"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 4), "選單裡找不到新增成員。\(app.debugDescription)")
        createButton.tap()

        let close = app.buttons["chrome.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        XCTAssertLessThanOrEqual(close.frame.width, 52, "取消應為圖示鈕，實際寬度 \(close.frame.width)")
        XCTAssertEqual(close.label, "キャンセル")

        let nav = app.navigationBars["グループ / メンバー"]
        let title = nav.staticTexts["グループ / メンバー"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        XCTAssertEqual(
            title.frame.midX,
            nav.frame.midX,
            accuracy: 12,
            "標題應置中。title \(title.frame) nav \(nav.frame)"
        )
        saveAuditScreenshot(app, name: "task_6_6_2_create_ja")
    }

    /// Task 6.6.3：從系統相簿讀入一張照片後，預覽頁的關閉、裁切、旋轉圓鈕與日期膠囊同為 44 pt 且底部對齊。
    @MainActor
    func testPairingPreviewChromeIsUniform44() throws {
        let app = launchLibraryApp()
        let importer = app.buttons["chrome.library.import"]
        XCTAssertTrue(importer.waitForExistence(timeout: 12))
        importer.tap()

        let cancelPicker = app.buttons["取消"]
        let cancelPickerEn = app.buttons["Cancel"]
        let pickerVisible = cancelPicker.waitForExistence(timeout: 6) || cancelPickerEn.waitForExistence(timeout: 2)
        XCTAssertTrue(pickerVisible, "沒有打開系統相簿選擇器。\(app.debugDescription)")

        let pickerPhoto = app.images.matching(
            NSPredicate(format: "identifier == 'PXGGridLayout-Info'")
        ).element(boundBy: 0)
        XCTAssertTrue(pickerPhoto.waitForExistence(timeout: 6), "相簿選擇器沒有可點的照片")
        pickerPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let done = app.buttons["完了"]
        XCTAssertTrue(done.waitForExistence(timeout: 4), "選取照片後沒有出現完成")
        done.tap()

        let close = app.buttons["chrome.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "沒有進入批次工作台。\(app.debugDescription)")
        let readyToArchive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '歸檔'")).firstMatch
        XCTAssertTrue(readyToArchive.waitForExistence(timeout: 40), "照片尚未完成偵測")

        let workbenchPhoto = app.images["chrome.workbench.photo"]
        XCTAssertTrue(workbenchPhoto.waitForExistence(timeout: 4))
        workbenchPhoto.tap()

        let previewClose = app.buttons["chrome.preview.close"]
        XCTAssertTrue(previewClose.waitForExistence(timeout: 6), "沒有打開單張預覽。\(app.debugDescription)")
        let crop = app.buttons["chrome.preview.crop"]
        let rotate = app.buttons["chrome.preview.rotate"]
        let date = app.buttons["chrome.preview.date"]
        XCTAssertTrue(crop.waitForExistence(timeout: 2))
        XCTAssertTrue(rotate.waitForExistence(timeout: 2))
        XCTAssertTrue(date.waitForExistence(timeout: 2))

        XCTAssertEqual(previewClose.frame.width, 44, accuracy: 1, "關閉鈕 \(previewClose.frame)")
        XCTAssertEqual(previewClose.frame.height, 44, accuracy: 1, "關閉鈕 \(previewClose.frame)")
        assertCircleFramesMatch(crop, rotate, expectedSide: 44)
        XCTAssertEqual(date.frame.height, 44, accuracy: 1, "日期膠囊應與圓鈕同高 \(date.frame)")
        XCTAssertEqual(crop.frame.midY, date.frame.midY, accuracy: 1, "底部按鈕應同一水平線 crop \(crop.frame) date \(date.frame)")
        saveAuditScreenshot(app, name: "task_6_6_3_preview")

        crop.tap()
        let cropClose = app.buttons["chrome.crop.close"]
        let cropRotate = app.buttons["chrome.crop.rotate"]
        XCTAssertTrue(cropClose.waitForExistence(timeout: 6), "沒有進入裁切頁")
        XCTAssertTrue(cropRotate.waitForExistence(timeout: 2))
        XCTAssertEqual(cropClose.frame.width, 44, accuracy: 1, "裁切關閉鈕 \(cropClose.frame)")
        XCTAssertEqual(cropClose.frame.height, 44, accuracy: 1, "裁切關閉鈕 \(cropClose.frame)")
        XCTAssertEqual(cropRotate.frame.height, 44, accuracy: 1, "裁切底部鈕 \(cropRotate.frame)")
        saveAuditScreenshot(app, name: "task_6_6_3_crop")
    }

    /// Task 6.6.4：相機頂部閃光燈、九宮格、關閉鈕皆為 44 pt，且同一水平線。
    @MainActor
    func testCameraTopChromeIsUniform44() throws {
        let app = launchLibraryApp()
        let openCamera = app.buttons["chrome.library.camera"]
        XCTAssertTrue(openCamera.waitForExistence(timeout: 12))
        openCamera.tap()

        let flash = app.buttons["chrome.camera.flash"]
        let grid = app.buttons["chrome.camera.grid"]
        let close = app.buttons["chrome.camera.close"]
        XCTAssertTrue(flash.waitForExistence(timeout: 8), "沒有進入相機。\(app.debugDescription)")
        XCTAssertTrue(grid.waitForExistence(timeout: 2))
        XCTAssertTrue(close.waitForExistence(timeout: 2))

        assertCircleFramesMatch(flash, close, expectedSide: 44)
        XCTAssertEqual(grid.frame.width, 44, accuracy: 1, "九宮格 \(grid.frame)")
        XCTAssertEqual(grid.frame.height, 44, accuracy: 1, "九宮格 \(grid.frame)")
        XCTAssertEqual(flash.frame.minY, grid.frame.minY, accuracy: 1, "頂部按鈕應同一水平線")
        XCTAssertTrue(flash.label.contains("關閉") || flash.label.contains("オフ"), "閃光燈預設應為關閉，實際 \(flash.label)")
        saveAuditScreenshot(app, name: "task_6_6_4_flash_off")

        flash.tap()
        let flashed = app.buttons["chrome.camera.flash"]
        let active = NSPredicate(format: "label CONTAINS '自動' OR label CONTAINS '開啟' OR label CONTAINS 'オン'")
        let becameActive = XCTNSPredicateExpectation(predicate: active, object: flashed)
        XCTAssertEqual(XCTWaiter().wait(for: [becameActive], timeout: 3), .completed, "點擊後閃光燈應離開關閉，實際 \(flashed.label)")
        saveAuditScreenshot(app, name: "task_6_6_4_flash_on")
    }

    /// Task 6.6.5：選取列與單張檢視的返回、分享、刪除圓鈕皆為 44 pt，且左右同一水平線。
    @MainActor
    func testDetailAndSelectionChromeIsUniform44() throws {
        let app = launchLibraryApp()
        let filter = app.buttons["chrome.library.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 12))
        try ensureLibraryHasPhoto(app)

        let select = app.buttons["chrome.library.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 8), "典藏庫沒有可選取的照片。\(app.debugDescription)")
        select.tap()

        let selectionShare = app.buttons["chrome.library.selection.share"]
        let selectionDelete = app.buttons["chrome.library.selection.delete"]
        XCTAssertTrue(selectionShare.waitForExistence(timeout: 4), "選取列沒有分享鈕")
        XCTAssertTrue(selectionDelete.waitForExistence(timeout: 2))
        assertCircleFramesMatch(selectionShare, selectionDelete, expectedSide: 44)
        saveAuditScreenshot(app, name: "task_6_6_5_selection")

        select.tap()
        let photo = app.buttons["chrome.library.photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 6), "離開選取後找不到照片")
        photo.tap()

        let back = app.buttons["chrome.detail.back"]
        let more = app.buttons["chrome.detail.more"]
        let share = app.buttons["chrome.detail.share"]
        let delete = app.buttons["chrome.detail.delete"]
        XCTAssertTrue(back.waitForExistence(timeout: 6), "沒有進入單張檢視。\(app.debugDescription)")
        XCTAssertTrue(more.waitForExistence(timeout: 2))
        XCTAssertTrue(share.waitForExistence(timeout: 2))
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        assertCircleFramesMatch(back, more, expectedSide: 44)
        assertCircleFramesMatch(share, delete, expectedSide: 44)
        saveAuditScreenshot(app, name: "task_6_6_5_detail")
    }

    @MainActor
    private func ensureLibraryHasPhoto(_ app: XCUIApplication) throws {
        let select = app.buttons["chrome.library.select"]
        if select.waitForExistence(timeout: 3) { return }

        let importer = app.buttons["chrome.library.import"]
        XCTAssertTrue(importer.waitForExistence(timeout: 4))
        importer.tap()

        let cancelPicker = app.buttons["取消"]
        let cancelPickerEn = app.buttons["Cancel"]
        let pickerVisible = cancelPicker.waitForExistence(timeout: 6) || cancelPickerEn.waitForExistence(timeout: 2)
        XCTAssertTrue(pickerVisible, "沒有打開系統相簿選擇器")

        let pickerPhoto = app.images.matching(
            NSPredicate(format: "identifier == 'PXGGridLayout-Info'")
        ).element(boundBy: 0)
        XCTAssertTrue(pickerPhoto.waitForExistence(timeout: 6), "相簿選擇器沒有可點的照片")
        pickerPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let done = app.buttons["完了"]
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        done.tap()

        let readyToArchive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '歸檔'")).firstMatch
        XCTAssertTrue(readyToArchive.waitForExistence(timeout: 40), "照片尚未完成偵測")
        readyToArchive.tap()

        XCTAssertTrue(select.waitForExistence(timeout: 30), "歸檔後典藏庫仍沒有照片")
    }

    /// Task 6.6.7：全部頁雙指放開後才改欄數。預設 3 欄，放大後變少。
    @MainActor
    func testLibraryPinchCommitsColumnCountOnRelease() throws {
        let app = launchLibraryApp()
        let grid = app.descendants(matching: .any)["chrome.library.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 12), "找不到全部頁格狀。\(app.debugDescription)")
        XCTAssertEqual(grid.value as? String, "3", "預設應為 3 欄，實際 \(String(describing: grid.value))")
        saveAuditScreenshot(app, name: "task_6_6_7_before")

        grid.pinch(withScale: 2.4, velocity: 1.5)
        let fewer = NSPredicate(format: "value == '1' OR value == '2'")
        let committed = XCTNSPredicateExpectation(predicate: fewer, object: grid)
        XCTAssertEqual(
            XCTWaiter().wait(for: [committed], timeout: 4),
            .completed,
            "放開後欄數應減少，實際 \(String(describing: grid.value))"
        )
        saveAuditScreenshot(app, name: "task_6_6_7_after")
    }

    /// Task 6.6.8：相冊封面磚可雙指縮放，放開後欄數改變並寫入可讀取的欄數值。
    @MainActor
    func testAlbumCoverPinchCommitsColumnCount() throws {
        let app = launchLibraryApp()
        let albums = app.buttons["相冊"]
        XCTAssertTrue(albums.waitForExistence(timeout: 12))
        albums.tap()

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 6))
        more.tap()
        let gridMode = app.buttons["格狀"]
        if !gridMode.waitForExistence(timeout: 2) {
            let displayMenu = app.buttons["顯示"]
            XCTAssertTrue(displayMenu.waitForExistence(timeout: 2), "選單裡找不到顯示方式")
            displayMenu.tap()
        }
        XCTAssertTrue(app.buttons["格狀"].waitForExistence(timeout: 2))
        app.buttons["格狀"].tap()

        more.tap()
        let columnMenu = app.buttons["欄數"]
        if !columnMenu.waitForExistence(timeout: 2) {
            XCTAssertTrue(more.waitForExistence(timeout: 2))
            more.tap()
        }
        XCTAssertTrue(app.buttons["欄數"].waitForExistence(timeout: 2), "選單裡找不到欄數")
        app.buttons["欄數"].tap()
        let twoColumns = app.buttons["2 欄"]
        XCTAssertTrue(twoColumns.waitForExistence(timeout: 2))
        twoColumns.tap()

        let grid = app.descendants(matching: .any)["chrome.albums.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 6), "找不到相冊格狀。\(app.debugDescription)")
        let becameTwo = NSPredicate(format: "value == '2'")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: becameTwo, object: grid)], timeout: 3),
            .completed,
            "選單應把欄數設為 2，實際 \(String(describing: grid.value))"
        )
        saveAuditScreenshot(app, name: "task_6_6_8_before")

        grid.pinch(withScale: 2.4, velocity: 1.5)
        let becameOne = NSPredicate(format: "value == '1'")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: becameOne, object: grid)], timeout: 4),
            .completed,
            "放大放開後應為 1 欄，實際 \(String(describing: grid.value))"
        )
        saveAuditScreenshot(app, name: "task_6_6_8_after")
    }
}
