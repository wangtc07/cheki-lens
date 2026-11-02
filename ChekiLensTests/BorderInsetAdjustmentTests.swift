import XCTest
import SwiftUI
@testable import ChekiLens

// MARK: - BorderInsetAdjustmentTests

/// 驗證單張獨立邊界微調 (Border Inset Adjustment)、數學縮放還原與個別設定優先權
@MainActor
final class BorderInsetAdjustmentTests: XCTestCase {

    private func makeTestPhoto(id: UUID = UUID(), seq: Int = 1, borderInset: Double? = nil) -> StagingChekiPhoto {
        let size = CGSize(width: 10, height: 10)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let data = img.jpegData(compressionQuality: 0.8) ?? Data()
        return StagingChekiPhoto(
            id: id,
            sequenceNumber: seq,
            title: "Photo #\(seq)",
            imageData: data,
            uiImage: img,
            detectedSide: .likelyFront,
            detectionNote: "Test",
            borderInsetPercentage: borderInset
        )
    }

    // MARK: - 1. StagingChekiPhoto 個別邊界設定測試

    func test_stagingPhoto_borderInsetPercentage_storageAndEquality() {
        let photo1 = makeTestPhoto(seq: 1, borderInset: -1.5)

        var photo2 = photo1
        XCTAssertEqual(photo1, photo2)

        // 修改個別邊界微調程度
        photo2.borderInsetPercentage = 2.0
        XCTAssertNotEqual(photo1, photo2, "邊界微調程度不同時，Equatable 必須判斷為不相等")
    }

    // MARK: - 2. 邊界微調縮放幾何計算與可逆性 (Roundtrip) 測試

    func test_borderInsetMath_scalingAndInversion() {
        let baseCorners: [CGPoint] = [
            CGPoint(x: 0.10, y: 0.10),
            CGPoint(x: 0.90, y: 0.10),
            CGPoint(x: 0.90, y: 0.90),
            CGPoint(x: 0.10, y: 0.90)
        ]

        // 擴大 +2.0%
        let expanded = BatchPairingViewCornersMath.cornersWithInset(baseCorners: baseCorners, percentage: 2.0)
        XCTAssertEqual(expanded.count, 4)
        // 左上頂點 (0.1, 0.1) 應遠離中心 (0.5, 0.5)：0.5 + (0.1 - 0.5) * 1.02 = 0.5 - 0.408 = 0.092
        XCTAssertEqual(expanded[0].x, 0.092, accuracy: 0.0001)
        XCTAssertEqual(expanded[0].y, 0.092, accuracy: 0.0001)

        // 縮小 -1.5%
        let shrunk = BatchPairingViewCornersMath.cornersWithInset(baseCorners: baseCorners, percentage: -1.5)
        // 0.5 + (0.1 - 0.5) * 0.985 = 0.5 - 0.394 = 0.106
        XCTAssertEqual(shrunk[0].x, 0.106, accuracy: 0.0001)
        XCTAssertEqual(shrunk[0].y, 0.106, accuracy: 0.0001)

        // 0% 保持不變
        let zeroInset = BatchPairingViewCornersMath.cornersWithInset(baseCorners: baseCorners, percentage: 0.0)
        for i in 0..<4 {
            XCTAssertEqual(zeroInset[i].x, baseCorners[i].x, accuracy: 0.0001)
            XCTAssertEqual(zeroInset[i].y, baseCorners[i].y, accuracy: 0.0001)
        }

        // 測試反向還原 (Roundtrip Inversion)
        let targetPercentage = 1.8
        let modified = BatchPairingViewCornersMath.cornersWithInset(baseCorners: baseCorners, percentage: targetPercentage)
        let restored = BatchPairingViewCornersMath.baseCornersFromCurrent(corners: modified, percentage: targetPercentage)
        for i in 0..<4 {
            XCTAssertEqual(restored[i].x, baseCorners[i].x, accuracy: 0.0001)
            XCTAssertEqual(restored[i].y, baseCorners[i].y, accuracy: 0.0001)
        }
    }

    // MARK: - 3. ChekiItem 個別 borderInsetRatio 持久化測試

    func test_chekiItem_borderInsetRatio_persistence() {
        let item = ChekiItem(
            borderInsetRatio: -0.015 // -1.5%
        )
        XCTAssertEqual(item.borderInsetRatio, -0.015, accuracy: 0.0001)

        // 單獨調整為 +2.5%
        item.borderInsetRatio = 0.025
        XCTAssertEqual(item.borderInsetRatio, 0.025, accuracy: 0.0001)
    }
}

// MARK: - Helper for Unit Testing Math

enum BatchPairingViewCornersMath {
    static func baseCornersFromCurrent(corners: [CGPoint], percentage: Double) -> [CGPoint] {
        let ratio = percentage / 100.0
        guard abs(ratio) > 1e-5 else { return corners }
        let cx = corners.map { $0.x }.reduce(0, +) / CGFloat(corners.count)
        let cy = corners.map { $0.y }.reduce(0, +) / CGFloat(corners.count)
        let invScale = 1.0 / CGFloat(1.0 + ratio)
        return corners.map { pt in
            CGPoint(
                x: cx + (pt.x - cx) * invScale,
                y: cy + (pt.y - cy) * invScale
            )
        }
    }

    static func cornersWithInset(baseCorners: [CGPoint], percentage: Double) -> [CGPoint] {
        let ratio = percentage / 100.0
        guard abs(ratio) > 1e-5 else { return baseCorners }
        let cx = baseCorners.map { $0.x }.reduce(0, +) / CGFloat(baseCorners.count)
        let cy = baseCorners.map { $0.y }.reduce(0, +) / CGFloat(baseCorners.count)
        let scale = CGFloat(1.0 + ratio)
        return baseCorners.map { pt in
            CGPoint(
                x: cx + (pt.x - cx) * scale,
                y: cy + (pt.y - cy) * scale
            )
        }
    }
}
