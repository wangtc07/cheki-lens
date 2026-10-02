import Foundation
import CoreGraphics
import Vision

extension VisionManager {
    
    /// 透過背面文字 (OCR) 反推拍立得四個角的座標
    /// 尋找 "Don't put in mouth" (上) 與 "instax" (下)
    func detectBacksideCorners(in image: CGImage, imageSize: CGSize) async throws -> DetectionResult? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // 這些字都是大寫/英數混合，關閉語言校正可以避免誤判
        
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        
        guard let observations = request.results else { return nil }
        
        var topRect: CGRect?
        var bottomRect: CGRect?
        
        for obs in observations {
            let text = obs.topCandidates(1).first?.string.lowercased() ?? ""
            if text.contains("mouth") || text.contains("don't") || text.contains("put") {
                topRect = obs.boundingBox
            }
            if text.contains("instax") || text.contains("fujifilm") {
                bottomRect = obs.boundingBox
            }
        }
        
        // 必須至少找到一個關鍵字才能反推
        guard topRect != nil || bottomRect != nil else { return nil }
        
        // 取得找到的文字框中心點與高度，用來當作幾何反推的基準
        // Vision 回傳的 boundingBox 是歸一化座標 (0~1)，原點在左下角
        
        var cx: CGFloat = 0.5
        var tY: CGFloat = 0.95 // 預設頂部位置
        var bY: CGFloat = 0.05 // 預設底部位置
        var widthRatio: CGFloat = 0.6
        
        if let t = topRect {
            cx = t.midX
            tY = t.midY + (t.height * 2.0) // 往上推
            widthRatio = t.width * 1.5 // 粗略推算寬度
        }
        
        if let b = bottomRect {
            cx = cx == 0.5 ? b.midX : (cx + b.midX) / 2.0
            bY = b.midY - (b.height * 2.0) // 往下推
            if topRect == nil {
                widthRatio = b.width * 2.5
            }
        }
        
        // 將歸一化座標轉回圖片真實座標 (Vision 的原點在左下角，這裡先轉回左上角系統)
        let actualTY = (1.0 - tY) * imageSize.height
        let actualBY = (1.0 - bY) * imageSize.height
        let actualCX = cx * imageSize.width
        let halfWidth = (widthRatio * imageSize.width) / 2.0
        
        let tl = CGPoint(x: actualCX - halfWidth, y: actualTY)
        let tr = CGPoint(x: actualCX + halfWidth, y: actualTY)
        let br = CGPoint(x: actualCX + halfWidth, y: actualBY)
        let bl = CGPoint(x: actualCX - halfWidth, y: actualBY)
        
        return DetectionResult(corners: [tl, tr, br, bl], method: .visionNative, confidence: 0.9, imageSize: imageSize)
    }
}
