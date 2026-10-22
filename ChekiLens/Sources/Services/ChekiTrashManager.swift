import Foundation
import SwiftData

/// 負責拍立得軟刪除、30 天到期自動硬刪除管線、清空垃圾桶與復原的核心管理器
@MainActor
final class ChekiTrashManager {

    // MARK: - Singleton

    static let shared = ChekiTrashManager()

    /// 預設過期天數（30 天）
    static let defaultExpirationDays: Int = 30

    private init() {}

    // MARK: - Operations

    /// 執行軟刪除：將指定拍立得項目移入「最近刪除」相冊
    func softDelete(
        _ items: [ChekiItem],
        in modelContext: ModelContext,
        at date: Date = Date()
    ) throws {
        let liveItems = items.filter { !$0.isDeleted && $0.modelContext != nil }
        guard !liveItems.isEmpty else { return }

        for item in liveItems {
            item.softDelete(at: date)
        }
        try modelContext.save()
    }

    /// 執行復原：將指定拍立得項目自「最近刪除」相冊復原回圖庫
    func restore(
        _ items: [ChekiItem],
        in modelContext: ModelContext
    ) throws {
        let trashedItems = items.filter { $0.isDeleted && $0.modelContext != nil }
        guard !trashedItems.isEmpty else { return }

        for item in trashedItems {
            item.restoreFromTrash()
        }
        try modelContext.save()
    }

    /// 永久硬刪除指定拍立得項目：徹底自資料庫抹除並非同步清除本機快取
    func permanentlyDelete(
        _ items: [ChekiItem],
        in modelContext: ModelContext
    ) async throws {
        let validItems = items.filter { $0.modelContext != nil }
        guard !validItems.isEmpty else { return }

        for item in validItems {
            let itemID = item.id
            await ChekiImageCacheManager.shared.removeAllImages(for: itemID)

            if let memo = item.memo {
                item.memo = nil
                modelContext.delete(memo)
            }
            item.idolMember = nil
            modelContext.delete(item)
        }
        try modelContext.save()
    }

    /// 同步永久硬刪除指定拍立得項目
    func permanentlyDeleteSync(
        _ items: [ChekiItem],
        in modelContext: ModelContext
    ) throws {
        let validItems = items.filter { $0.modelContext != nil }
        guard !validItems.isEmpty else { return }

        for item in validItems {
            let itemID = item.id
            ChekiImageCacheManager.shared.removeAllImagesSync(for: itemID)

            if let memo = item.memo {
                item.memo = nil
                modelContext.delete(memo)
            }
            item.idolMember = nil
            modelContext.delete(item)
        }
        try modelContext.save()
    }

    /// 清空所有「最近刪除」項目（手動立即永久刪除）
    @discardableResult
    func emptyTrash(in modelContext: ModelContext) async throws -> Int {
        let allItems = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        let trashedItems = allItems.filter(\.isDeleted)

        guard !trashedItems.isEmpty else { return 0 }
        try await permanentlyDelete(trashedItems, in: modelContext)
        return trashedItems.count
    }

    /// 同步清空所有「最近刪除」項目
    @discardableResult
    func emptyTrashSync(in modelContext: ModelContext) throws -> Int {
        let allItems = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        let trashedItems = allItems.filter(\.isDeleted)

        guard !trashedItems.isEmpty else { return 0 }
        try permanentlyDeleteSync(trashedItems, in: modelContext)
        return trashedItems.count
    }

    /// 執行 30 天過期項目自動清除管線：
    /// 檢驗所有 `deletedAt != nil` 之項目，若距今已超過 `expirationDays`（預設 30 天）則永久硬刪除。
    @discardableResult
    func purgeExpiredItems(
        in modelContext: ModelContext,
        referenceDate: Date = Date(),
        expirationDays: Int = defaultExpirationDays
    ) async throws -> Int {
        let allItems = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        let expiredItems = allItems.filter { item in
            item.isExpired(relativeTo: referenceDate, expirationDays: expirationDays)
        }

        guard !expiredItems.isEmpty else { return 0 }
        try await permanentlyDelete(expiredItems, in: modelContext)
        return expiredItems.count
    }

    /// 同步執行 30 天過期項目自動清除管線
    @discardableResult
    func purgeExpiredItemsSync(
        in modelContext: ModelContext,
        referenceDate: Date = Date(),
        expirationDays: Int = defaultExpirationDays
    ) throws -> Int {
        let allItems = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        let expiredItems = allItems.filter { item in
            item.isExpired(relativeTo: referenceDate, expirationDays: expirationDays)
        }

        guard !expiredItems.isEmpty else { return 0 }
        try permanentlyDeleteSync(expiredItems, in: modelContext)
        return expiredItems.count
    }

    // MARK: - Query Helpers

    /// 取得所有位於「最近刪除」的拍立得清單（依刪除時間新到舊排序）
    func fetchTrashedItems(in modelContext: ModelContext) throws -> [ChekiItem] {
        let all = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        return all
            .filter(\.isDeleted)
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// 取得所有非刪除狀態的有效拍立得清單
    func fetchActiveItems(in modelContext: ModelContext) throws -> [ChekiItem] {
        let all = try modelContext.fetch(FetchDescriptor<ChekiItem>())
        return all.filter { !$0.isDeleted }
    }
}
