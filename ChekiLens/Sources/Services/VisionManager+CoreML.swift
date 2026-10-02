import Foundation
import CoreImage
import Vision
import CoreML

extension VisionManager {
    
    /// 階段 2.5: 使用我們專屬訓練的 CoreML 模型進行四角預測
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? {
        
        // 1. 載入我們剛煉好的 ChekiCornerNet 模型
        let config = MLModelConfiguration()
        config.computeUnits = .all // 啟用 Apple Silicon 神經網路引擎 (ANE)
        
        // Xcode 會自動幫 .mlpackage 生成同名的 Swift 類別
        guard let coreMLModel = try? ChekiCornerNet(configuration: config).model,
              let visionModel = try? VNCoreMLModel(for: coreMLModel) else {
            print("⚠️ 無法載入 ChekiCornerNet CoreML 模型")
            return nil
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            // 2. 建立 Vision 請求
            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                // 3. 解析模型輸出的 Tensor (我們在 PyTorch 裡面定義的輸出長度為 8)
                // 輸出的是 VNCoreMLFeatureValueObservation，裡面包含 multiArrayValue
                guard let results = request.results as? [VNCoreMLFeatureValueObservation],
                      let featureValue = results.first?.featureValue,
                      let multiArray = featureValue.multiArrayValue else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // 確保輸出了 8 個座標點數值 (x1, y1, x2, y2, x3, y3, x4, y4)
                guard multiArray.count >= 8 else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // 模型輸出的是 0.0 ~ 1.0 的正規化座標，我們需要將它乘回原本圖片的真實寬高
                let x1 = multiArray[0].doubleValue * imageSize.width
                let y1 = multiArray[1].doubleValue * imageSize.height
                let x2 = multiArray[2].doubleValue * imageSize.width
                let y2 = multiArray[3].doubleValue * imageSize.height
                let x3 = multiArray[4].doubleValue * imageSize.width
                let y3 = multiArray[5].doubleValue * imageSize.height
                let x4 = multiArray[6].doubleValue * imageSize.width
                let y4 = multiArray[7].doubleValue * imageSize.height
                
                let points = [
                    CGPoint(x: x1, y: y1),
                    CGPoint(x: x2, y: y2),
                    CGPoint(x: x3, y: y3),
                    CGPoint(x: x4, y: y4)
                ]
                
                // 使用我們原本寫好的排序演算法，確保點的順序是 (左上, 右上, 右下, 左下)
                let orderedPoints = self.orderPoints(points)
                
                continuation.resume(returning: DetectionResult(corners: orderedPoints, method: .visionCoreML))
            }
            
            // 讓 Apple Vision 框架自動幫我們把輸入圖片縮放裁切成模型需要的 256x256
            request.imageCropAndScaleOption = .scaleFill
            
            // 4. 執行請求
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
