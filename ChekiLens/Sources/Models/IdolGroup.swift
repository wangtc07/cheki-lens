import Foundation
import SwiftData

// MARK: - IdolGroup

/// 偶像團體實體（分類層級：團體 → 成員 → 拍立得）
///
/// 顏色以標準 hex 字串儲存（如 `"#FF6B9D"`），在 UI 層轉為 `Color`
@Model
final class IdolGroup {

    // MARK: Properties

    /// 唯一識別 UUID
    var id: UUID

    /// 團體名稱（如「日向坂46」、「乃木坂46」）
    var name: String

    /// 團體識別顏色 hex 字串（如 `"#FF6B9D"`），nil 表示使用預設藍
    var colorHex: String?

    /// 創建時間
    var createdAt: Date

    /// 顯示排序權重（越小越靠前）
    var sortOrder: Int

    // MARK: Relations

    /// 旗下偶像成員清單
    @Relationship(deleteRule: .cascade, inverse: \IdolMember.group)
    var members: [IdolMember]

    // MARK: Init

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String? = nil,
        createdAt: Date = Date(),
        sortOrder: Int = 0,
        members: [IdolMember] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.members = members
    }
}

// MARK: - Computed Helpers

extension IdolGroup {

    /// 按排序權重與創建時間排序的成員清單
    var sortedMembers: [IdolMember] {
        members.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.stageName < $1.stageName
        }
    }

    /// 旗下拍立得總張數（聚合各成員）
    var totalChekiCount: Int {
        members.reduce(0) { $0 + $1.chekiItems.count }
    }
}
