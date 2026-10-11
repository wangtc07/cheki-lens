import XCTest
@testable import ChekiLens

final class GridPinchZoomTests: XCTestCase {
    func testZoomInDropsColumnsOnlyPastThresholds() {
        XCTAssertEqual(GridPinchZoom.columnCount(after: 1.10, from: 3), 3)
        XCTAssertEqual(GridPinchZoom.columnCount(after: 1.16, from: 3), 2)
        XCTAssertEqual(GridPinchZoom.columnCount(after: 1.59, from: 3), 1)
        XCTAssertEqual(GridPinchZoom.columnCount(after: 1.59, from: 2, counts: GridPinchZoom.albumColumnCounts), 1)
        XCTAssertEqual(GridPinchZoom.columnCount(after: 0.85, from: 2, counts: GridPinchZoom.albumColumnCounts), 3)
        XCTAssertEqual(GridPinchZoom.columnCount(after: 1.1, from: 2, counts: GridPinchZoom.albumColumnCounts), 2)
    }

    func testZoomOutAddsColumnsOnlyPastThresholds() {
        XCTAssertEqual(GridPinchZoom.columnCount(after: 0.90, from: 3), 3)
        XCTAssertEqual(GridPinchZoom.columnCount(after: 0.85, from: 3), 5)
        XCTAssertEqual(GridPinchZoom.columnCount(after: 0.61, from: 2), 5)
        XCTAssertEqual(GridPinchZoom.columnCount(after: 0.4, from: 5), 5)
    }

    func testDampedScaleFollowsFingerWithoutReachingTheRawMagnification() {
        XCTAssertEqual(GridPinchZoom.dampedScale(magnification: 1), 1, accuracy: 0.001)
        XCTAssertEqual(GridPinchZoom.dampedScale(magnification: 2), 1.32, accuracy: 0.001)
        XCTAssertEqual(GridPinchZoom.dampedScale(magnification: 0.5), 0.84, accuracy: 0.001)
    }
}
