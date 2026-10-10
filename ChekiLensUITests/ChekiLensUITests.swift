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
}
