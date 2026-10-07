import Foundation
import SwiftData

// MARK: - ChekiItem

/// 代表一張拍立得（チェキ）掃描卡片的核心資料實體
///
/// 設計原則：
/// - 正反面以 `frontImageData` / `backImageData` 儲存 JPEG 壓縮後的二進位資料
/// - `capturedAt` 預設為匯入時間；若 OCR 成功解析手寫日期則由 `ocrDate` 覆寫
/// - `aspectRatio` 與 `filmFormat` 決定透視校正時的比例鎖定
/// - `borderInsetRatio` 範圍 -0.03 ~ +0.03（負值＝向內裁切，正值＝向外保留白邊）
@Model
final class ChekiItem {

    // MARK: Identity

    /// 唯一識別 UUID（供 Photos Album 寫入時作為附帶 metadata）
    var id: UUID

    // MARK: Image Data

    /// 正面照片（透視裁切後之拍立得影像）壓縮後 JPEG 二進位，nil 表示尚未掃描
    @Attribute(.externalStorage)
    var frontImageData: Data?

    /// 背面照片（透視裁切後之手寫日期/簽名面）壓縮後 JPEG 二進位，nil 表示僅有正面
    @Attribute(.externalStorage)
    var backImageData: Data?

    /// 正面原始未裁切照片（供事後重新手動調整四個頂點與透視裁切使用）
    @Attribute(.externalStorage)
    var originalFrontImageData: Data?

    /// 背面原始未裁切照片（供事後重新手動調整背面四個頂點與透視裁切使用）
    @Attribute(.externalStorage)
    var originalBackImageData: Data?

    // MARK: Timestamp

    /// 數位翻拍的實際時間（匯入時由系統取得）
    var capturedAt: Date

    /// OCR 從底部白邊手寫日期解析出的真實拍攝日期（nil 表示尚未辨識或辨識失敗）
    var ocrDate: Date?

    /// 是否已以 ocrDate 回寫系統相簿的 creationDate
    var isDateWrittenToAlbum: Bool

    // MARK: Film Format & Geometry

    /// 相紙規格（影響透視校正時的比例鎖定）
    var filmFormat: FilmFormat

    /// 實際偵測到的影像長寬比（短邊 / 長邊），作為自動識別參考
    var detectedAspectRatio: Double

    /// 邊界偏移率 -0.03 ~ +0.03
    /// - 負值：向內裁切（去除白邊陰影）
    /// - 正值：向外保留（確保完整保留相紙邊緣）
    var borderInsetRatio: Double

    // MARK: Vision Metadata

    /// 正面 Vision 透視校正時所偵測或手動調整的四角錨點（JSON 編碼的 [CGPoint] x4）
    /// 格式：`[[x1,y1],[x2,y2],[x3,y3],[x4,y4]]`（已正規化至 0.0~1.0，順序：TL, TR, BR, BL）
    var perspectivePointsJSON: String?

    /// 背面 Vision 透視校正時所偵測或手動調整的四角錨點（JSON 編碼的 [CGPoint] x4，已正規化至 0.0~1.0）
    var backPerspectivePointsJSON: String?

    /// Vision 使用了哪一層偵測策略
    var detectionMethod: DetectionMethod

    // MARK: State

    /// 處理狀態持久化字串（供 SwiftData Predicate 查詢，如 #Predicate { $0.processingStateRaw == target }）
    var processingStateRaw: String

    /// 處理狀態（掃描流程）
    @Transient
    var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .unprocessed }
        set { processingStateRaw = newValue.rawValue }
    }

    /// 是否已同步至 iOS 系統相簿
    var isSyncedToPhotoLibrary: Bool

    // MARK: Relations

    /// 所屬偶像成員（可為 nil，表示尚未分類）
    var idolMember: IdolMember?

    /// 附屬的備忘錄（若無則為 nil，懶加載）
    @Relationship(deleteRule: .cascade, inverse: \ChekiMemo.chekiItem)
    var memo: ChekiMemo?

    // MARK: Init

    init(
        id: UUID = UUID(),
        frontImageData: Data? = nil,
        backImageData: Data? = nil,
        originalFrontImageData: Data? = nil,
        originalBackImageData: Data? = nil,
        capturedAt: Date = Date(),
        ocrDate: Date? = nil,
        isDateWrittenToAlbum: Bool = false,
        filmFormat: FilmFormat = .mini,
        detectedAspectRatio: Double = FilmFormat.mini.aspectRatio,
        borderInsetRatio: Double = 0.0,
        perspectivePointsJSON: String? = nil,
        backPerspectivePointsJSON: String? = nil,
        detectionMethod: DetectionMethod = .pending,
        processingState: ProcessingState = .unprocessed,
        isSyncedToPhotoLibrary: Bool = false,
        idolMember: IdolMember? = nil,
        memo: ChekiMemo? = nil
    ) {
        self.id = id
        self.frontImageData = frontImageData
        self.backImageData = backImageData
        self.originalFrontImageData = originalFrontImageData
        self.originalBackImageData = originalBackImageData
        self.capturedAt = capturedAt
        self.ocrDate = ocrDate
        self.isDateWrittenToAlbum = isDateWrittenToAlbum
        self.filmFormat = filmFormat
        self.detectedAspectRatio = detectedAspectRatio
        self.borderInsetRatio = borderInsetRatio
        self.perspectivePointsJSON = perspectivePointsJSON
        self.backPerspectivePointsJSON = backPerspectivePointsJSON
        self.detectionMethod = detectionMethod
        self.processingStateRaw = processingState.rawValue
        self.isSyncedToPhotoLibrary = isSyncedToPhotoLibrary
        self.idolMember = idolMember
        self.memo = memo
    }

}

// MARK: - Computed Helpers

extension ChekiItem {

    /// 對外展示用日期：優先使用 OCR 手寫日期，否則用翻拍時間
    var displayDate: Date {
        ocrDate ?? capturedAt
    }

    /// 是否具有背面資料
    var hasBothSides: Bool {
        backImageData != nil
    }

    /// 將像素座標四角點 [TL, TR, BR, BL] 轉為正規化 (0.0~1.0) JSON 字串
    static func encodeNormalizedCorners(_ pixelCorners: [CGPoint], imageSize: CGSize) -> String? {
        guard pixelCorners.count == 4, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let normalized: [[Double]] = pixelCorners.map { pt in
            [
                max(0.0, min(1.0, Double(pt.x / imageSize.width))),
                max(0.0, min(1.0, Double(pt.y / imageSize.height)))
            ]
        }
        guard let data = try? JSONEncoder().encode(normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 將已正規化 (0.0~1.0) 的四角點 [TL, TR, BR, BL] 轉為 JSON 字串
    static func encodeNormalizedCorners(_ normalizedCorners: [CGPoint]) -> String? {
        guard normalizedCorners.count == 4 else { return nil }
        let pairs: [[Double]] = normalizedCorners.map { pt in
            [
                max(0.0, min(1.0, Double(pt.x))),
                max(0.0, min(1.0, Double(pt.y)))
            ]
        }
        guard let data = try? JSONEncoder().encode(pairs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 從 JSON 字串解碼出正規化 (0.0~1.0) 四角點 [TL, TR, BR, BL]
    static func decodeNormalizedCorners(from json: String?) -> [CGPoint]? {
        guard let json,
              let data = json.data(using: .utf8),
              let pairs = try? JSONDecoder().decode([[Double]].self, from: data),
              pairs.count == 4 else { return nil }
        return pairs.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
    }
}

// MARK: - FilmFormat

/// 拍立得相紙規格（比例鎖定）
enum FilmFormat: String, Codable, CaseIterable, Sendable {
    /// Instax Mini：86mm × 54mm，比例 ≈ 1.593（長邊/短邊）
    case mini   = "mini"
    /// Instax Square：86mm × 72mm，比例 ≈ 1.194
    case square = "square"
    /// Instax Wide：108mm × 86mm，比例 ≈ 1.256
    case wide   = "wide"
    /// 自動識別（Vision 偵測後自動落入對應規格）
    case auto   = "auto"

    /// 長邊 / 短邊比例（用於 CIPerspectiveCorrection 比例鎖定）
    var aspectRatio: Double {
        switch self {
        case .mini:   return 86.0 / 54.0   // ≈ 1.593
        case .square: return 86.0 / 72.0   // ≈ 1.194
        case .wide:   return 108.0 / 86.0  // ≈ 1.256
        case .auto:   return 0.0           // 由 Vision 動態取得
        }
    }

    /// 物理尺寸（mm）：(長邊, 短邊)
    var physicalSizeMM: (width: Double, height: Double) {
        switch self {
        case .mini:   return (86, 54)
        case .square: return (86, 72)
        case .wide:   return (108, 86)
        case .auto:   return (0, 0)
        }
    }

    var displayName: String {
        switch self {
        case .mini:   return "Instax Mini"
        case .square: return "Instax Square"
        case .wide:   return "Instax Wide"
        case .auto:   return "自動識別"
        }
    }
}

// MARK: - DetectionMethod

/// Vision 矩形偵測策略層級
enum DetectionMethod: String, Codable, CaseIterable, Sendable {
    /// 尚未執行偵測
    case pending          = "pending"
    /// 第一層：Apple Vision 原生 `VNDetectRectanglesRequest`
    case visionNative     = "vision_native"
    /// 第二層 Fallback：Hough 直線邊緣交叉偵測
    case houghEdge        = "hough_edge"
    /// 第三層 Fallback：白色邊框 RGB Mask 輪廓
    case whiteBorderMask  = "white_border_mask"
    /// 手動調整（使用者手動拖曳四角錨點）
    case manualAdjusted   = "manual_adjusted"
    /// 偵測失敗，需要人工處理
    case failed           = "failed"
}

// MARK: - ProcessingState

/// 掃描流程狀態機
enum ProcessingState: String, Codable, CaseIterable, Sendable {
    /// 尚未開始處理
    case unprocessed   = "unprocessed"
    /// 正在偵測邊框
    case detecting     = "detecting"
    /// 等待使用者確認微調
    case awaitingReview = "awaiting_review"
    /// 透視校正完成，等待 OCR
    case corrected     = "corrected"
    /// OCR 日期辨識中
    case recognizingDate = "recognizing_date"
    /// 全部完成
    case completed     = "completed"
    /// 發生錯誤
    case error         = "error"

    var displayName: String {
        switch self {
        case .unprocessed:    return "未處理"
        case .detecting:      return "偵測中"
        case .awaitingReview: return "等待確認"
        case .corrected:      return "校正完成"
        case .recognizingDate:return "OCR 辨識中"
        case .completed:      return "完成"
        case .error:          return "錯誤"
        }
    }
}
