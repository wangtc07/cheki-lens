import Foundation
import CoreGraphics
import Vision

extension VisionManager {
    
    /// 透過背面專用雙重錨點定型 (Task 2.8.4: BacksideDetector)
    /// 精確定位深色/黑色拍立得背面四角外框
    func detectBacksideCorners(in image: CGImage, imageSize: CGSize) async throws -> DetectionResult? {
        guard let res = try await BacksideDetector.detect(in: image, imageSize: imageSize) else {
            return nil
        }
        return DetectionResult(
            corners: res.corners,
            method: .visionNative,
            confidence: res.confidence,
            imageSize: imageSize
        )
    }
}
