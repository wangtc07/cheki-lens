import Foundation
import SwiftData

// MARK: - ChekiMemo

/// 附屬於拍立得的備忘錄實體（特典會活動筆記、# 標籤）
///
/// 設計：一對一關聯至 `ChekiItem`（使用 `@Relationship(deleteRule: .cascade)`）
/// 採用 Apple 原生 HIG 上滑 Info Sheet 體驗
@Model
final class ChekiMemo {

    // MARK: Properties

    /// 唯一識別 UUID
    var id: UUID

    /// 特典會 / 見面會活動名稱（如「日向坂46 個人握手会 幕張メッセ」）
    var eventName: String?

    /// 會話筆記文字（自由文字，顯示於 Info Sheet 的 Caption 區塊）
    var noteText: String?

    /// # 標籤清單（如 `["#日向坂46", "#推し", "#握手会"]`）
    var hashtags: [String]

    /// 備忘建立時間
    var createdAt: Date

    /// 最後修改時間
    var updatedAt: Date

    // MARK: Relations

    /// 所屬拍立得（反向關聯，由 `ChekiItem.memo` 驅動）
    var chekiItem: ChekiItem?

    // MARK: Init

    init(
        id: UUID = UUID(),
        eventName: String? = nil,
        noteText: String? = nil,
        hashtags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        chekiItem: ChekiItem? = nil
    ) {
        self.id = id
        self.eventName = eventName
        self.noteText = noteText
        self.hashtags = hashtags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.chekiItem = chekiItem
    }
}

// MARK: - Computed Helpers

extension ChekiMemo {

    /// 是否為空白備忘（所有欄位皆無填寫）
    var isEmpty: Bool {
        (eventName?.isEmpty ?? true) &&
        (noteText?.isEmpty ?? true) &&
        hashtags.isEmpty
    }

    /// 格式化後的 hashtag 字串（如 `"#日向坂46 #推し"`）
    var hashtagsFormatted: String {
        hashtags.joined(separator: " ")
    }

    /// 更新備忘並自動刷新 updatedAt 時間戳
    func update(eventName: String? = nil, noteText: String? = nil, hashtags: [String]? = nil) {
        if let eventName { self.eventName = eventName }
        if let noteText { self.noteText = noteText }
        if let hashtags { self.hashtags = hashtags }
        self.updatedAt = Date()
    }
}
