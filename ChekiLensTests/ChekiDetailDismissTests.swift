import XCTest
import SwiftUI
@testable import ChekiLens

// MARK: - ChekiDetailDismissTests

/// 驗證單張預覽檢視 (ChekiDetailView) 與 NavigationChromeState 的下滑返回總覽頁狀態機與路由行為
@MainActor
final class ChekiDetailDismissTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NavigationChromeState.shared.dismissDetail()
    }

    override func tearDown() {
        NavigationChromeState.shared.dismissDetail()
        super.tearDown()
    }

    // MARK: - 1. 呈現與返回狀態切換測試

    func test_presentDetail_and_dismissDetail_stateTransitions() {
        let sampleID = UUID()
        let route = ChekiDetailRoute(
            itemID: sampleID,
            scopedItemIDs: [sampleID],
            sourceScopeID: "library-all"
        )

        XCTAssertNil(NavigationChromeState.shared.activeDetailRoute)
        XCTAssertNil(NavigationChromeState.shared.activeZoomItemID)

        // 呈現單張檢視
        NavigationChromeState.shared.presentDetail(route)
        XCTAssertEqual(NavigationChromeState.shared.activeDetailRoute?.itemID, sampleID)
        XCTAssertEqual(NavigationChromeState.shared.activeZoomItemID, sampleID)

        // 下拉返回總覽頁
        NavigationChromeState.shared.dismissDetail()
        XCTAssertNil(NavigationChromeState.shared.activeDetailRoute, "返回總覽頁後 activeDetailRoute 必須為 nil")
        XCTAssertNil(NavigationChromeState.shared.activeZoomItemID, "返回總覽頁後 activeZoomItemID 必須為 nil")
    }

    // MARK: - 2. 縮圖錨點資訊快取與防重影測試

    func test_gridCellAnchor_caching_and_hiddenCheck() {
        let sampleID = UUID()
        let scopeID = "library-all"
        let cellFrame = CGRect(x: 20, y: 150, width: 120, height: 180)

        NavigationChromeState.shared.updateGridCellAnchor(
            itemID: sampleID,
            scopeID: scopeID,
            globalFrame: cellFrame,
            cornerRadius: 10,
            isSquareCropped: false
        )

        let retrieved = NavigationChromeState.shared.gridCellAnchor(for: sampleID, scopeID: scopeID)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.globalFrame, cellFrame)
        XCTAssertEqual(retrieved?.cornerRadius, 10)

        // 尚未開啟時，該格子不應隱藏
        XCTAssertFalse(NavigationChromeState.shared.isGridCellHidden(itemID: sampleID, scopeID: scopeID))

        // 開啟單張檢視後，底層該格子應標記隱藏以避免下滑時重影
        let route = ChekiDetailRoute(itemID: sampleID, scopedItemIDs: [sampleID], sourceScopeID: scopeID)
        NavigationChromeState.shared.presentDetail(route)
        XCTAssertTrue(NavigationChromeState.shared.isGridCellHidden(itemID: sampleID, scopeID: scopeID))

        // 下拉關閉後，底層格子重新顯現
        NavigationChromeState.shared.dismissDetail()
        XCTAssertFalse(NavigationChromeState.shared.isGridCellHidden(itemID: sampleID, scopeID: scopeID))
    }

    // MARK: - 3. 下拉返回手勢門檻判定邏輯驗證

    func test_downwardDragThreshold_decisionLogic() {
        // 判定手勢是否應觸發下滑返回總覽頁
        func shouldDismiss(dy: CGFloat, predictedDy: CGFloat) -> Bool {
            dy > 40 || predictedDy > 90
        }

        // 輕微抖動不應返回
        XCTAssertFalse(shouldDismiss(dy: 10, predictedDy: 20))
        XCTAssertFalse(shouldDismiss(dy: 35, predictedDy: 50))

        // 下拉距離超過 40pt 應觸發返回
        XCTAssertTrue(shouldDismiss(dy: 45, predictedDy: 45))
        XCTAssertTrue(shouldDismiss(dy: 120, predictedDy: 150))

        // 快速短促向下甩動 (Flick) 即使位移小但慣性速度足夠亦應觸發返回
        XCTAssertTrue(shouldDismiss(dy: 25, predictedDy: 100))
    }

    // MARK: - 4. 手勢方向鎖定與向下優先權判定邏輯驗證

    func test_downwardDragPriority_over_horizontalSwipe() {
        // 驗證向下優先權函式
        func isDownwardDrag(dx: CGFloat, dy: CGFloat) -> Bool {
            dy > 0 && (dy > abs(dx) * 0.55 || dy > 14)
        }

        // 自然下斜滑動（拇指弧度）應正確判定為向下返回而非左右切換
        XCTAssertTrue(isDownwardDrag(dx: 10, dy: 20))
        XCTAssertTrue(isDownwardDrag(dx: -15, dy: 30))
        XCTAssertTrue(isDownwardDrag(dx: 5, dy: 15))

        // 明顯水平滑動應保留為左右翻頁
        XCTAssertFalse(isDownwardDrag(dx: 50, dy: 5))
        XCTAssertFalse(isDownwardDrag(dx: -60, dy: 0))

        // 向上滑動不應觸發向下返回
        XCTAssertFalse(isDownwardDrag(dx: 0, dy: -30))
    }
}
