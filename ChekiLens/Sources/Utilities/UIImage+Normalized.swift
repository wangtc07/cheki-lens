import UIKit

extension UIImage {
    /// 修正 EXIF 轉向問題，將圖片的像素資料永久轉正
    nonisolated var normalizedImage: UIImage {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 修正 EXIF 轉向並限制最大邊長（大幅加速 12MP 相機原圖在背景執行緒的轉正與 JPEG 編碼速度）
    nonisolated func normalizedImage(maxDimension: CGFloat) -> UIImage {
        let longSide = max(size.width, size.height)
        let ratio = longSide > maxDimension ? (maxDimension / longSide) : 1.0
        if imageOrientation == .up && ratio >= 0.999 {
            return self
        }
        let targetSize = CGSize(
            width: max(1, round(size.width * ratio)),
            height: max(1, round(size.height * ratio))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
