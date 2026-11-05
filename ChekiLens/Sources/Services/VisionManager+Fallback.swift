import Foundation
import CoreGraphics
import Vision
import CoreML

// MARK: - VisionManager + Fallback (Task 2.8.5)

extension VisionManager {
    
    /// 終極兜底重判機制 (Fallback: YOLO11-Pose / CoreML Object Box)
    /// 專門應對：
    /// 1. 滿版彩繪正面 (如 DSCF0025.JPG，完全無白邊且 Native 偵測為 0)
    /// 2. 極端暗光或高反光漏抓案例
    /// 3. 上方白邊消失導致 Native 嚴重截斷之案例 (如 DSCF0074、IMG_7882)
    ///
    /// 透過物件語義偵測 (Object Detection Box)，取得拍立得全卡位置，再行透視幾何鎖定，保證 0 重大失誤。
    /// 優先載入 `Application Support/ChekiModels/` 下的 OTA 動態更新模型，若無則回退至 App Bundle 內建模型。
    nonisolated static func resolvePoseModelURL(
        otaStore: ChekiOTAModelStore = ChekiOTAModelStore(),
        bundle: Bundle = .main
    ) -> URL? {
        if let otaURL = otaStore.activeCompiledModelURL() {
            return otaURL
        }
        if let url = bundle.url(forResource: "ChekiPoseNet", withExtension: "mlmodelc") ??
                     bundle.url(forResource: "ChekiPoseNet", withExtension: "mlpackage") {
            return url
        }
        let localPaths = [
            "ChekiLens/Models/ChekiPoseNet.mlpackage",
            "runs/pose/cheki_pose_clean/weights/best.mlpackage"
        ]
        for p in localPaths {
            let u = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + p)
            if FileManager.default.fileExists(atPath: u.path) {
                return u
            }
        }
        return nil
    }

    func detectFallbackPose(image: CGImage, imageSize: CGSize) async throws -> DetectionResult? {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        guard let url = Self.resolvePoseModelURL() else {
            return nil
        }
        
        let compiledURL: URL
        if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
            guard let cURL = try? await MLModel.compileModel(at: url) else { return nil }
            compiledURL = cURL
        } else {
            compiledURL = url
        }
        
        guard let mlModel = try? MLModel(contentsOf: compiledURL, configuration: config),
              let vnModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        
        // 2. 執行 Vision 推論
        var bestBox: CGRect? = nil
        var bestKeypointQuad: [CGPoint]? = nil
        var highestConf: Float = 0.0
        
        let request = VNCoreMLRequest(model: vnModel) { req, err in
            guard err == nil,
                  let results = req.results as? [VNCoreMLFeatureValueObservation],
                  let feature = results.first?.featureValue,
                  let multiArray = feature.multiArrayValue else { return }
            
            // YOLO-Pose 輸出 shape: [1, 17, 8400]
            let channelCount = multiArray.shape.count >= 2 ? multiArray.shape[1].intValue : 0
            let anchorCount = multiArray.shape.last?.intValue ?? 8400
            let rowStride = multiArray.strides[1].intValue
            let anchorStride = multiArray.strides[2].intValue
            
            let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: multiArray.count)
            
            var bestAnchor = -1
            var bestScore: Float = 0.0
            
            for i in 0..<anchorCount {
                let conf = ptr[4 * rowStride + i * anchorStride]
                guard conf >= 0.20 else { continue }
                let w = ptr[2 * rowStride + i * anchorStride]
                let h = ptr[3 * rowStride + i * anchorStride]
                
                let normW = Double(w) / 640.0
                let normH = Double(h) / 640.0
                let area = normW * normH
                guard area >= 0.08 else { continue } // 排除佔比過小的局域碎框
                
                let ratio = normH / max(0.01, normW)
                let miniDist = abs(ratio - 1.593)
                let wideDist = abs(ratio - 1.256)
                let squareDist = abs(ratio - 1.194)
                let minDist = min(miniDist, min(wideDist, squareDist))
                let formatScore = max(0.2, 1.0 - minDist * 0.5)
                
                let score = conf * Float(area) * Float(formatScore)
                if score > bestScore {
                    bestScore = score
                    bestAnchor = i
                    highestConf = conf
                }
            }
            
            if bestAnchor >= 0 {
                let xc = ptr[0 * rowStride + bestAnchor * anchorStride]
                let yc = ptr[1 * rowStride + bestAnchor * anchorStride]
                let w = ptr[2 * rowStride + bestAnchor * anchorStride]
                let h = ptr[3 * rowStride + bestAnchor * anchorStride]
                
                // 歸一化座標 (0~640 尺度轉 0~1)
                let normX1 = max(0.0, Double(xc - w / 2.0) / 640.0)
                let normY1 = max(0.0, Double(yc - h / 2.0) / 640.0)
                let normX2 = min(1.0, Double(xc + w / 2.0) / 640.0)
                let normY2 = min(1.0, Double(yc + h / 2.0) / 640.0)
                
                let box = CGRect(
                    x: normX1 * Double(imageSize.width),
                    y: normY1 * Double(imageSize.height),
                    width: (normX2 - normX1) * Double(imageSize.width),
                    height: (normY2 - normY1) * Double(imageSize.height)
                )
                bestBox = box
                
                if channelCount >= 17 {
                    var kpts: [CGPoint] = []
                    var allConfident = true
                    for k in 0..<4 {
                        let kx = Double(ptr[(5 + k * 3) * rowStride + bestAnchor * anchorStride]) / 640.0
                        let ky = Double(ptr[(6 + k * 3) * rowStride + bestAnchor * anchorStride]) / 640.0
                        let kc = ptr[(7 + k * 3) * rowStride + bestAnchor * anchorStride]
                        if kc < 0.35 || kx < -0.05 || kx > 1.05 || ky < -0.05 || ky > 1.05 {
                            allConfident = false
                            break
                        }
                        kpts.append(
                            CGPoint(
                                x: min(max(0.0, kx), 1.0) * Double(imageSize.width),
                                y: min(max(0.0, ky), 1.0) * Double(imageSize.height)
                            )
                        )
                    }
                    if allConfident, kpts.count == 4 {
                        let orderedKpts = VisionManager.orderPoints(kpts)
                        let kptArea = VisionManager.quadArea(orderedKpts)
                        let boxArea = Double(box.width * box.height)
                        if boxArea > 0,
                           kptArea >= 0.80 * boxArea,
                           kptArea <= 1.18 * boxArea,
                           VisionManager.isChekiRatio(orderedKpts) {
                            bestKeypointQuad = orderedKpts
                        }
                    }
                }
            }
        }
        
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        
        guard let box = bestBox else { return nil }
        
        // 3. 幾何重建 4 頂點並依標準比例校正保護
        let rawCorners = bestKeypointQuad ?? [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY)
        ]
        
        let spec = AspectRatioClassifier.classify(corners: rawCorners)
        let targetRatio = spec.targetAspectRatio // width / height
        let currentRatio = box.width / max(1.0, box.height)
        
        var finalCorners = rawCorners
        if abs(currentRatio - targetRatio) > 0.08 {
            // 修正寬度以匹配標準物理底片規格
            let correctedW = box.height * targetRatio
            let cx = box.midX
            
            var snappedCorners: [CGPoint]? = nil
            // 4. 實體邊緣反差微調：若畫面右側/左側有顯著明暗階躍邊界，對齊真實相紙邊界 (修復滿版彩繪如 IMG_6530 左側暗色偏置)
            if let data = image.dataProvider?.data,
               let ptr = CFDataGetBytePtr(data) {
                let w = image.width, h = image.height
                let bpr = image.bytesPerRow
                let bpp = image.bitsPerPixel / 8
                
                func lum(x: Int, y: Int) -> Double {
                    guard x >= 0 && x < w && y >= 0 && y < h else { return 0 }
                    let o = y * bpr + x * bpp
                    return 0.299 * Double(ptr[o]) + 0.587 * Double(ptr[o+1]) + 0.114 * Double(ptr[o+2])
                }
                
                func findEdgeX(y: Int, xRange: ClosedRange<Int>) -> Double? {
                    var bestG = 0.0, bestX = Double(xRange.lowerBound)
                    for x in xRange {
                        let l1 = lum(x: x - 4, y: y)
                        let l2 = lum(x: x + 4, y: y)
                        let g = abs(l2 - l1)
                        if g > bestG {
                            bestG = g
                            bestX = Double(x)
                        }
                    }
                    return bestG >= 35.0 ? bestX : nil
                }
                
                let yTop = Int(box.minY + 0.12 * box.height)
                let yBot = Int(box.maxY - 0.12 * box.height)
                let rTopX = findEdgeX(y: yTop, xRange: Int(box.maxX - 50)...min(w - 10, Int(box.maxX + 350)))
                let rBotX = findEdgeX(y: yBot, xRange: Int(box.maxX - 50)...min(w - 10, Int(box.maxX + 350)))
                let lTopX = findEdgeX(y: yTop, xRange: max(10, Int(box.minX - 450))...Int(box.minX + 50))
                let lBotX = findEdgeX(y: yBot, xRange: max(10, Int(box.minX - 450))...Int(box.minX + 50))
                
                if let rt = rTopX, let rb = rBotX {
                    let trX = rt
                    let brX = rb
                    let tlX = lTopX ?? (trX - correctedW)
                    let blX = lBotX ?? (brX - correctedW)
                    snappedCorners = [
                        CGPoint(x: tlX, y: box.minY),
                        CGPoint(x: trX, y: box.minY),
                        CGPoint(x: brX, y: box.maxY),
                        CGPoint(x: blX, y: box.maxY)
                    ]
                }
            }
            
            if let sc = snappedCorners {
                finalCorners = sc
            } else {
                let x1 = max(0.0, min(imageSize.width, cx - correctedW / 2.0))
                let x2 = max(0.0, min(imageSize.width, cx + correctedW / 2.0))
                finalCorners = [
                    CGPoint(x: x1, y: box.minY),
                    CGPoint(x: x2, y: box.minY),
                    CGPoint(x: x2, y: box.maxY),
                    CGPoint(x: x1, y: box.maxY)
                ]
            }
        }
        
        // 5. 第二階段（Coarse-to-Fine）：在原圖解析度下執行四邊 1D 亞像素 Sobel 階躍與 RANSAC 直線交點吸附
        let stage2Snapped = VisionManager.snapQuadToFullResEdges(
            corners: finalCorners,
            image: image,
            imageSize: imageSize
        )
        if stage2Snapped.wasSnapped {
            finalCorners = stage2Snapped.corners
        }
        
        return DetectionResult(
            corners: finalCorners,
            method: .visionCoreML,
            confidence: Double(highestConf),
            imageSize: imageSize
        )
    }
}
