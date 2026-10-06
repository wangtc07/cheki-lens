import Foundation
import CoreImage
import Vision
import CoreML

extension VisionManager {
    
    /// 透過剛訓練好的專屬 CoreML 模型 (ChekiCornerNet) 來預測四個角
    /// - Parameters:
    ///   - image: 原始輸入影像
    ///   - imageSize: 原始影像尺寸 (用來將 0~1 的座標還原成實際像素)
    /// - Returns: 偵測結果 (如果成功)
    func detectVisionCoreML(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? {
        
        // 1. 初始化 CoreML 模型
        // ChekiCornerNet 是 Xcode 自動從 .mlpackage 產生的 Swift Class
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all // 允許使用 Apple Neural Engine
        
        guard let mlModel = await MainActor.run(body: { try? ChekiCornerNet(configuration: configuration).model }),
              let vnModel = try? VNCoreMLModel(for: mlModel) else {
            print("[CoreML] 無法載入 ChekiCornerNet 模型")
            return nil
        }
        
        // 2. 建立 Vision 請求
        var predictedCorners: [CGPoint] = []
        
        let request = VNCoreMLRequest(model: vnModel) { request, error in
            guard error == nil else {
                print("[CoreML] 預測發生錯誤: \(String(describing: error))")
                return
            }
            
            // 由於我們的模型輸出是名為 "corners" 的連續數組 (Tensor)
            // Vision 會將它包裝成 VNCoreMLFeatureValueObservation
            guard let results = request.results as? [VNCoreMLFeatureValueObservation],
                  let multiArray = results.first?.featureValue.multiArrayValue,
                  multiArray.count >= 8 else {
                print("[CoreML] 模型輸出格式不符預期")
                return
            }
            
            // 3. 解析座標
            // 模型輸出為 [x1, y1, x2, y2, x3, y3, x4, y4]，數值為 0.0 ~ 1.0
            let tl = CGPoint(
                x: multiArray[0].doubleValue * imageSize.width,
                y: multiArray[1].doubleValue * imageSize.height
            )
            let tr = CGPoint(
                x: multiArray[2].doubleValue * imageSize.width,
                y: multiArray[3].doubleValue * imageSize.height
            )
            let br = CGPoint(
                x: multiArray[4].doubleValue * imageSize.width,
                y: multiArray[5].doubleValue * imageSize.height
            )
            let bl = CGPoint(
                x: multiArray[6].doubleValue * imageSize.width,
                y: multiArray[7].doubleValue * imageSize.height
            )
            
            predictedCorners = [tl, tr, br, bl]
        }
        
        // 重要：我們訓練模型時是直接將影像壓縮成 256x256 (不管比例)
        // 所以這裡必須設定 scaleFill，告訴 Vision 用相同的擠壓方式餵給模型
        request.imageCropAndScaleOption = VNImageCropAndScaleOption.scaleFill
        
        // 4. 執行預測
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        
        if predictedCorners.count == 4 {
            return DetectionResult(corners: predictedCorners, method: .visionCoreML, confidence: 1.0, imageSize: imageSize)
        }
        
        return nil
    }
}
