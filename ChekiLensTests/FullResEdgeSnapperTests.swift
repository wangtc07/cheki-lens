import XCTest
import CoreGraphics
@testable import ChekiLens

final class FullResEdgeSnapperTests: XCTestCase {

    /// 建立模擬高解析度拍立得測試影像（支援模糊邊緣過渡帶、傾斜四角與局部塗鴉遮擋）
    private func makeSyntheticChekiImage(
        width: Int = 1200,
        height: Int = 1600,
        trueQuad: [CGPoint],
        backgroundGray: UInt8 = 125,
        cardWhite: UInt8 = 244,
        addCrossBorderGraffiti: Bool = false
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "FullResEdgeSnapperTests", code: 1)
        }

        // CoreGraphics 預設座標原點在左下角，翻轉至左上角原點以利與像素座標一致
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        // 1. 填滿中亮度桌面背景（例如木紋或灰墊，亮度 ~125 > 85）
        let bgNorm = CGFloat(backgroundGray) / 255.0
        ctx.setFillColor(red: bgNorm, green: max(0, bgNorm - 0.03), blue: max(0, bgNorm - 0.06), alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 2. 模擬鏡頭 PSF 邊緣過渡帶（向外擴張 2px 的半透明過渡層）
        let cx = trueQuad.reduce(0.0) { $0 + $1.x } / 4.0
        let cy = trueQuad.reduce(0.0) { $0 + $1.y } / 4.0
        let outerRampQuad = trueQuad.map { pt -> CGPoint in
            let vx = pt.x - cx
            let vy = pt.y - cy
            let len = max(1.0, hypot(vx, vy))
            return CGPoint(x: pt.x + (vx / len) * 2.5, y: pt.y + (vy / len) * 2.5)
        }

        let midNorm = (bgNorm + CGFloat(cardWhite) / 255.0) * 0.5
        ctx.beginPath()
        ctx.move(to: outerRampQuad[0])
        for i in 1..<4 { ctx.addLine(to: outerRampQuad[i]) }
        ctx.closePath()
        ctx.setFillColor(red: midNorm, green: midNorm, blue: midNorm, alpha: 1.0)
        ctx.fillPath()

        // 3. 繪製真實拍立得純白相紙本體
        let cardNorm = CGFloat(cardWhite) / 255.0
        ctx.beginPath()
        ctx.move(to: trueQuad[0])
        for i in 1..<4 { ctx.addLine(to: trueQuad[i]) }
        ctx.closePath()
        ctx.setFillColor(red: cardNorm, green: cardNorm, blue: cardNorm, alpha: 1.0)
        ctx.fillPath()

        // 4. 若開啟跨邊塗鴉測試，在頂邊與右邊中段畫上深色麥克筆跨邊筆觸（測試 RANSAC 抗離群點能力）
        if addCrossBorderGraffiti {
            ctx.setFillColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1.0)
            let topMid = CGPoint(
                x: (trueQuad[0].x + trueQuad[1].x) * 0.5,
                y: (trueQuad[0].y + trueQuad[1].y) * 0.5
            )
            ctx.fill(CGRect(x: topMid.x - 28, y: topMid.y - 25, width: 56, height: 50))

            let rightMid = CGPoint(
                x: (trueQuad[1].x + trueQuad[2].x) * 0.5,
                y: (trueQuad[1].y + trueQuad[2].y) * 0.5
            )
            ctx.fill(CGRect(x: rightMid.x - 25, y: rightMid.y - 28, width: 50, height: 56))
        }

        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "FullResEdgeSnapperTests", code: 2)
        }
        return cgImage
    }

    func testEliminatesOutwardBackgroundGapOnMediumContrastDesk() throws {
        let trueQuad = [
            CGPoint(x: 200.0, y: 180.0),
            CGPoint(x: 1000.0, y: 180.0),
            CGPoint(x: 1000.0, y: 1454.0),
            CGPoint(x: 200.0, y: 1454.0)
        ]
        let imageSize = CGSize(width: 1200, height: 1600)
        let cgImage = try makeSyntheticChekiImage(
            width: 1200,
            height: 1600,
            trueQuad: trueQuad,
            backgroundGray: 128,
            cardWhite: 245
        )

        // 模擬第一階段 640px 模型預測往外偏移 12~16px（裁切後會露出桌面背景縫隙）
        let coarseQuad = [
            CGPoint(x: 186.0, y: 166.0),
            CGPoint(x: 1015.0, y: 165.0),
            CGPoint(x: 1014.0, y: 1468.0),
            CGPoint(x: 185.0, y: 1469.0)
        ]

        let result = VisionManager.snapQuadToFullResEdges(
            corners: coarseQuad,
            image: cgImage,
            imageSize: imageSize
        )

        XCTAssertEqual(result.snappedEdgeCount, 4, "四條邊皆應成功在原圖吸附")
        XCTAssertTrue(result.wasSnapped)

        // 驗證吸附後的頂點完全消除背景外露（落入相紙純白邊界內側 0~3.5px 處）
        for i in 0..<4 {
            let err = hypot(result.corners[i].x - trueQuad[i].x, result.corners[i].y - trueQuad[i].y)
            XCTAssertLessThan(err, 4.0, "頂點 \(i) 誤差應小於 4px，實際為 \(err)")
        }
        XCTAssertGreaterThanOrEqual(result.corners[0].x, trueQuad[0].x - 0.5)
        XCTAssertGreaterThanOrEqual(result.corners[0].y, trueQuad[0].y - 0.5)
        XCTAssertLessThanOrEqual(result.corners[2].x, trueQuad[2].x + 0.5)
        XCTAssertLessThanOrEqual(result.corners[2].y, trueQuad[2].y + 0.5)
    }

    func testRansacRejectsCrossBorderGraffitiAndPreservesPerspectiveTrapezoid() throws {
        // 模擬自然透視傾斜的拍立得梯形
        let trueQuad = [
            CGPoint(x: 215.0, y: 190.0),
            CGPoint(x: 985.0, y: 212.0),
            CGPoint(x: 1010.0, y: 1450.0),
            CGPoint(x: 190.0, y: 1432.0)
        ]
        let imageSize = CGSize(width: 1200, height: 1600)
        let cgImage = try makeSyntheticChekiImage(
            width: 1200,
            height: 1600,
            trueQuad: trueQuad,
            backgroundGray: 115,
            cardWhite: 242,
            addCrossBorderGraffiti: true
        )

        // 第一階段粗框存在非對稱偏移
        let coarseQuad = [
            CGPoint(x: 202.0, y: 176.0),
            CGPoint(x: 998.0, y: 200.0),
            CGPoint(x: 1024.0, y: 1463.0),
            CGPoint(x: 177.0, y: 1445.0)
        ]

        let result = VisionManager.snapQuadToFullResEdges(
            corners: coarseQuad,
            image: cgImage,
            imageSize: imageSize
        )

        XCTAssertEqual(result.snappedEdgeCount, 4)
        for i in 0..<4 {
            let err = hypot(result.corners[i].x - trueQuad[i].x, result.corners[i].y - trueQuad[i].y)
            XCTAssertLessThan(err, 4.5, "即使有跨邊麥克筆塗鴉，頂點 \(i) 仍應精準貼合真實傾斜邊界，實際誤差 \(err)")
        }
    }

    func testFallbackPreservesCoarseCornersWhenWhiteOnWhiteHasNoEdgeContrast() throws {
        let trueQuad = [
            CGPoint(x: 200.0, y: 180.0),
            CGPoint(x: 1000.0, y: 180.0),
            CGPoint(x: 1000.0, y: 1454.0),
            CGPoint(x: 200.0, y: 1454.0)
        ]
        let imageSize = CGSize(width: 1200, height: 1600)
        let cgImage = try makeSyntheticChekiImage(
            width: 1200,
            height: 1600,
            trueQuad: trueQuad,
            backgroundGray: 242,
            cardWhite: 245
        )

        let result = VisionManager.snapQuadToFullResEdges(
            corners: trueQuad,
            image: cgImage,
            imageSize: imageSize
        )

        XCTAssertEqual(result.snappedEdgeCount, 0)
        XCTAssertFalse(result.wasSnapped)
        XCTAssertEqual(result.corners, trueQuad)
    }
}
