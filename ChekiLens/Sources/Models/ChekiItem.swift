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

    /// 正面照片對應之 iOS 系統相簿 `PHAsset.localIdentifier`（直接修改原圖不新增重複照片，並支援復原原圖）
    var frontAssetIdentifier: String?

    /// 背面照片對應之 iOS 系統相簿 `PHAsset.localIdentifier`
    var backAssetIdentifier: String?

    /// 多成員歸檔 ID 清單 JSON（支援一張拍立得同時歸檔至多位成員，與 `idolMember` 主關聯保持相容）
    var assignedMemberIDsJSON: String?

    // MARK: Relations

    /// 所屬主偶像成員（可為 nil，表示尚未分類；當指派多位成員時為第一位成員）
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
        frontAssetIdentifier: String? = nil,
        backAssetIdentifier: String? = nil,
        idolMember: IdolMember? = nil,
        assignedMembers: [IdolMember]? = nil,
        memo: ChekiMemo? = nil
    ) {
        self.id = id
        self.frontImageData = frontImageData
        self.backImageData = backImageData
        self.originalFrontImageData = originalFrontImageData ?? frontImageData
        self.originalBackImageData = originalBackImageData ?? backImageData
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
        self.frontAssetIdentifier = frontAssetIdentifier
        self.backAssetIdentifier = backAssetIdentifier
        let resolvedMembers: [IdolMember] = {
            if let assignedMembers, !assignedMembers.isEmpty {
                return assignedMembers
            }
            if let idolMember {
                return [idolMember]
            }
            return []
        }()
        self.idolMember = resolvedMembers.first
        self.assignedMemberIDsJSON = Self.encodeMemberIDs(resolvedMembers.map(\.id))
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

    /// 已指派的所有成員 UUID 陣列（去重且保序，並包含主 `idolMember`）
    var assignedMemberIDs: [UUID] {
        var ids: [UUID] = []
        if let json = assignedMemberIDsJSON,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            for str in decoded {
                if let uuid = UUID(uuidString: str), !ids.contains(uuid) {
                    ids.append(uuid)
                }
            }
        }
        if let primary = idolMember, !primary.isDeleted, primary.modelContext != nil {
            if !ids.contains(primary.id) {
                ids.insert(primary.id, at: 0)
            }
        } else if idolMember == nil, assignedMemberIDsJSON == nil {
            return []
        }
        return ids
    }

    /// 是否為「未分類」（無任何指派成員）
    var isUncategorized: Bool {
        if let primary = idolMember, !primary.isDeleted, primary.modelContext != nil {
            return false
        }
        return assignedMemberIDs.isEmpty
    }

    /// 判斷此拍立得是否歸屬於指定成員（支援單一與多成員指派）
    func isAssigned(to member: IdolMember) -> Bool {
        guard !member.isDeleted, member.modelContext != nil else { return false }
        if idolMember?.id == member.id { return true }
        return assignedMemberIDs.contains(member.id)
    }

    /// 判斷此拍立得是否歸屬於指定成員 ID
    func isAssigned(toMemberID memberID: UUID) -> Bool {
        if idolMember?.id == memberID { return true }
        return assignedMemberIDs.contains(memberID)
    }

    /// 從傳入的全部成員清單解析出此拍立得目前已指派的成員陣列（保序）
    func assignedMembers(from allMembers: [IdolMember]) -> [IdolMember] {
        let validPool = allMembers.filter { !$0.isDeleted && $0.modelContext != nil }
        let byID = Dictionary(uniqueKeysWithValues: validPool.map { ($0.id, $0) })
        var result: [IdolMember] = []
        for id in assignedMemberIDs {
            if let member = byID[id], !result.contains(where: { $0.id == member.id }) {
                result.append(member)
            }
        }
        if let primary = idolMember,
           !primary.isDeleted,
           primary.modelContext != nil,
           !result.contains(where: { $0.id == primary.id }) {
            result.insert(primary, at: 0)
        }
        return result
    }

    /// 設定此拍立得的歸檔成員清單（可為多位成員，或空陣列代表「未分類」）
    func setAssignedMembers(_ members: [IdolMember]) {
        var unique: [IdolMember] = []
        for member in members where !member.isDeleted && member.modelContext != nil {
            if !unique.contains(where: { $0.id == member.id }) {
                unique.append(member)
            }
        }
        self.idolMember = unique.first
        self.assignedMemberIDsJSON = Self.encodeMemberIDs(unique.map(\.id))
    }

    /// 切換（勾選/取消勾選）某位成員的歸檔狀態（支援多選，不覆蓋其他已選成員）
    func toggleAssignedMember(_ member: IdolMember, allMembers: [IdolMember]) {
        var current = assignedMembers(from: allMembers)
        if let idx = current.firstIndex(where: { $0.id == member.id }) {
            current.remove(at: idx)
        } else {
            current.append(member)
        }
        setAssignedMembers(current)
    }

    /// 格式化顯示目前已指派的成員名稱摘要（例如：「河田陽菜、與田祐希」或「未分類」）
    func assignedMembersDisplayString(from allMembers: [IdolMember], includeGroupForSingle: Bool = false) -> String {
        let members = assignedMembers(from: allMembers)
        guard !members.isEmpty else {
            return L10n.tr("未分類", "未分類")
        }
        if members.count == 1 {
            return includeGroupForSingle ? members[0].albumTitle : members[0].stageName
        }
        return members.map(\.stageName).joined(separator: "、")
    }

    private static func encodeMemberIDs(_ ids: [UUID]) -> String? {
        guard !ids.isEmpty else { return nil }
        let strings = ids.map(\.uuidString)
        guard let data = try? JSONEncoder().encode(strings) else { return nil }
        return String(data: data, encoding: .utf8)
    }


    /// 指定面（正面或背面）是否保留有可復原的原始未裁切圖片
    func canRevertToOriginal(backside: Bool = false) -> Bool {
        if backside {
            guard let orig = originalBackImageData else { return false }
            return backPerspectivePointsJSON != nil || orig != backImageData
        } else {
            guard let orig = originalFrontImageData else { return false }
            return perspectivePointsJSON != nil || orig != frontImageData
        }
    }

    /// 將指定面（正面或背面）直接復原為原始未裁切圖片（不新增照片，保留原始圖片）
    func revertToOriginal(backside: Bool = false) {
        if backside {
            guard let orig = originalBackImageData else { return }
            backImageData = orig
            backPerspectivePointsJSON = nil
        } else {
            guard let orig = originalFrontImageData else { return }
            frontImageData = orig
            perspectivePointsJSON = nil
        }
    }

    /// 將像素座標四角點 [TL, TR, BR, BL] 轉為正規化 (-0.5~1.5，支援移出相片邊界外) JSON 字串
    static func encodeNormalizedCorners(_ pixelCorners: [CGPoint], imageSize: CGSize) -> String? {
        guard pixelCorners.count == 4, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let normalized: [[Double]] = pixelCorners.map { pt in
            [
                max(-0.5, min(1.5, Double(pt.x / imageSize.width))),
                max(-0.5, min(1.5, Double(pt.y / imageSize.height)))
            ]
        }
        guard let data = try? JSONEncoder().encode(normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 將已正規化 (-0.5~1.5，支援移出相片邊界外) 的四角點 [TL, TR, BR, BL] 轉為 JSON 字串
    static func encodeNormalizedCorners(_ normalizedCorners: [CGPoint]) -> String? {
        guard normalizedCorners.count == 4 else { return nil }
        let pairs: [[Double]] = normalizedCorners.map { pt in
            [
                max(-0.5, min(1.5, Double(pt.x))),
                max(-0.5, min(1.5, Double(pt.y)))
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

    /// 統一拍攝日期格式化：`yyyy年M月d日 EEEE`（例如繁中 `2025年11月3日 星期一` / 日文 `2025年11月3日 月曜日`）
    static func formatFullDateWithWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.formattingLocale
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }

    /// 將封面手寫辨識出的日期（年、月、日）合併至目標時間戳（保留原時、分、秒）
    static func mergeRecognizedDate(_ recognizedDate: Date, into baseTimestamp: Date) -> Date {
        let cal = Calendar.current
        let dateComps = cal.dateComponents([.year, .month, .day], from: recognizedDate)
        let timeComps = cal.dateComponents([.hour, .minute, .second], from: baseTimestamp)
        var merged = DateComponents()
        merged.year = dateComps.year
        merged.month = dateComps.month
        merged.day = dateComps.day
        merged.hour = timeComps.hour ?? 12
        merged.minute = timeComps.minute ?? 0
        merged.second = timeComps.second ?? 0
        return cal.date(from: merged) ?? recognizedDate
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

    /// 三種實體拍立得規格（資訊卡片中固定顯示與切換此三種）
    static let concreteFormats: [FilmFormat] = [.mini, .square, .wide]

    /// 若為 `.auto` 則正規化為三種具體規格之一（預設 `.mini`）
    var concreteFormat: FilmFormat {
        switch self {
        case .mini, .square, .wide:
            return self
        case .auto:
            return .mini
        }
    }

    /// 根據使用者偏好、Vision 透視規格或裁切尺寸，解析為三種具體規格之一（基本上為 `.mini`）
    static func resolvedConcreteFormat(
        preferred: FilmFormat = .auto,
        specName: String? = nil,
        outputSize: CGSize? = nil
    ) -> FilmFormat {
        if preferred != .auto {
            return preferred
        }
        if let specName {
            if specName.localizedCaseInsensitiveContains("Square") {
                return .square
            }
            if specName.localizedCaseInsensitiveContains("Wide") {
                return .wide
            }
            if specName.localizedCaseInsensitiveContains("Mini") {
                return .mini
            }
        }
        if let size = outputSize, size.width > 0, size.height > 0 {
            if size.width > size.height * 1.06 {
                return .wide
            }
            let ratio = max(size.width, size.height) / min(size.width, size.height)
            if ratio < 1.30 {
                return .square
            }
        }
        return .mini
    }

    /// 長邊 / 短邊比例（用於 CIPerspectiveCorrection 比例鎖定）
    var aspectRatio: Double {
        switch self {
        case .mini:   return 86.0 / 54.0   // ≈ 1.593
        case .square: return 86.0 / 72.0   // ≈ 1.194
        case .wide:   return 108.0 / 86.0  // ≈ 1.256
        case .auto:   return 86.0 / 54.0   // 預設落入 Instax Mini
        }
    }

    /// 物理尺寸（mm）：(長邊, 短邊)
    var physicalSizeMM: (width: Double, height: Double) {
        switch self {
        case .mini:   return (86, 54)
        case .square: return (86, 72)
        case .wide:   return (108, 86)
        case .auto:   return (86, 54)
        }
    }

    var displayName: String {
        switch self {
        case .mini:   return "Instax Mini"
        case .square: return "Instax Square"
        case .wide:   return "Instax Wide"
        case .auto:   return L10n.tr("自動識別", "自動判別")
        }
    }

    /// 具體規格顯示名稱（即使舊資料存為 `.auto` 也顯示為 `Instax Mini`）
    var concreteDisplayName: String {
        concreteFormat.displayName
    }

    /// 含毫米尺寸的完整顯示名稱
    var detailDisplayName: String {
        switch concreteFormat {
        case .mini:   return "Instax Mini (86×54mm)"
        case .square: return "Instax Square (86×72mm)"
        case .wide:   return "Instax Wide (86×108mm)"
        case .auto:   return "Instax Mini (86×54mm)"
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
        case .unprocessed:    return L10n.tr("未處理", "未処理")
        case .detecting:      return L10n.tr("偵測中", "検出中")
        case .awaitingReview: return L10n.tr("等待確認", "確認待ち")
        case .corrected:      return L10n.tr("校正完成", "補正完了")
        case .recognizingDate:return L10n.tr("OCR 辨識中", "OCR 認識中")
        case .completed:      return L10n.tr("完成", "完了")
        case .error:          return L10n.tr("錯誤", "エラー")
        }
    }
}
