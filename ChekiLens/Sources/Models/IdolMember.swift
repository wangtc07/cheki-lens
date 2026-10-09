import Foundation
import SwiftData

// MARK: - IdolMember

/// 偶像成員實體（分類層級：團體 → 成員 → 拍立得）
@Model
final class IdolMember {

    // MARK: Properties

    /// 唯一識別 UUID
    var id: UUID

    /// 藝名 / 舞台名（如「與田祐希」、「齋藤飛鳥」）
    var stageName: String

    /// 本名（可選，用於備忘搜尋；nil 表示不公開或未填寫）
    var realName: String?

    /// 頭像圖片壓縮後 JPEG 資料（nil 表示使用系統預設人像圖示）
    @Attribute(.externalStorage)
    var avatarImageData: Data?

    /// 自訂標籤陣列（如 `["推し", "最推", "センター"]`）
    var tags: [String]

    /// 創建時間
    var createdAt: Date

    /// 顯示排序權重（在所屬團體內的排序，越小越靠前）
    var sortOrder: Int

    // MARK: Relations

    /// 所屬團體（nil 表示未分類成員）
    var group: IdolGroup?

    /// 此成員擁有的全部拍立得
    @Relationship(deleteRule: .cascade, inverse: \ChekiItem.idolMember)
    var chekiItems: [ChekiItem]

    // MARK: Init

    init(
        id: UUID = UUID(),
        stageName: String,
        realName: String? = nil,
        avatarImageData: Data? = nil,
        tags: [String] = [],
        createdAt: Date = Date(),
        sortOrder: Int = 0,
        group: IdolGroup? = nil,
        chekiItems: [ChekiItem] = []
    ) {
        self.id = id
        self.stageName = stageName
        self.realName = realName
        self.avatarImageData = avatarImageData
        self.tags = tags
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.group = group
        self.chekiItems = chekiItems
    }
}

// MARK: - Computed Helpers

extension IdolMember {

    /// 顯示名稱：優先藝名
    var displayName: String { stageName }

    /// 成員相冊名稱：直接使用成員名（不加括號）
    var albumTitle: String {
        stageName
    }

    /// 最新一張拍立得（按 displayDate 排序）
    var latestCheki: ChekiItem? {
        chekiItems
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .max(by: { $0.displayDate < $1.displayDate })
    }

    /// 完成處理的拍立得數量
    var completedChekiCount: Int {
        chekiItems.filter { !$0.isDeleted && $0.modelContext != nil && $0.processingState == .completed }.count
    }
}
