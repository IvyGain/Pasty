import Foundation
import GRDB
import SwiftUI

struct Pinboard: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?
    var name: String
    var colorHex: String           // "#RRGGBB"
    var sortOrder: Int
    var createdAt: Date

    static let databaseTableName = "pinboards"
    enum Columns: String, ColumnExpression { case id, name, colorHex, sortOrder, createdAt }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct PinboardItem: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: Int64?
    var pinboardId: Int64
    var clipId: Int64
    var sortOrder: Int
    /// フォルダ内での表示名（ユーザ定義）。空ならクリップ本来の preview を使う。
    var title: String?

    static let databaseTableName = "pinboard_items"
    enum Columns: String, ColumnExpression { case id, pinboardId, clipId, sortOrder, title }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

@MainActor
final class PinboardStore: ObservableObject {
    @Published private(set) var boards: [Pinboard] = []
    @Published var selectedID: Int64? = nil
    private let dbWriter: any DatabaseWriter

    init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
        do { try reload() } catch { NSLog("Pinboard load failed: \(error)") }
    }

    func reload() throws {
        boards = try dbWriter.read { db in
            try Pinboard.order(Pinboard.Columns.sortOrder).fetchAll(db)
        }
        if selectedID == nil { selectedID = boards.first?.id }
    }

    func create(name: String, colorHex: String) async throws {
        _ = try await dbWriter.write { db in
            let order = try Pinboard.fetchCount(db)
            var b = Pinboard(id: nil, name: name, colorHex: colorHex,
                             sortOrder: order, createdAt: Date())
            try b.insert(db)
        }
        try reload()
    }

    func rename(id: Int64, to newName: String) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(sql: "UPDATE pinboards SET name = ? WHERE id = ?",
                           arguments: [newName, id])
        }
        try reload()
    }

    func setColor(id: Int64, to colorHex: String) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(sql: "UPDATE pinboards SET colorHex = ? WHERE id = ?",
                           arguments: [colorHex, id])
        }
        try reload()
    }

    func delete(id: Int64) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM pinboard_items WHERE pinboardId = ?",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM pinboards WHERE id = ?", arguments: [id])
        }
        try reload()
    }

    func pin(clipId: Int64, toBoard pinboardId: Int64) async throws {
        _ = try await dbWriter.write { db in
            let order = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM pinboard_items WHERE pinboardId = ?",
                arguments: [pinboardId]
            ) ?? 0
            var item = PinboardItem(id: nil, pinboardId: pinboardId,
                                    clipId: clipId, sortOrder: order)
            try item.insert(db)
        }
    }

    func items(in pinboardId: Int64) async throws -> [ClipItem] {
        try await dbWriter.read { db in
            // pinboard_items.title が non-NULL なら、それを `pinDisplayTitle` として
            // メモリ上だけセット。本文 (preview / content) は触らない。
            // v0.9.6-beta (follow-up #2): hide soft-deleted clips from
            // pinboard contents. pinboard_items rows survive the soft delete
            // (so re-pinning on restore stays cheap), but the clip itself must
            // not surface in the UI until deleted_at is cleared.
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*, pi.title AS pi_title FROM clips c
                JOIN pinboard_items pi ON pi.clipId = c.id
                WHERE pi.pinboardId = ?
                  AND c.deleted_at IS NULL
                ORDER BY pi.sortOrder
                """, arguments: [pinboardId])
            return rows.compactMap { row -> ClipItem? in
                guard var clip = try? ClipItem(row: row) else { return nil }
                if let t: String = row["pi_title"], !t.isEmpty {
                    clip.pinDisplayTitle = t
                }
                return clip
            }
        }
    }

    /// フォルダ内クリップの表示名を変更。空文字を渡すと元の preview に戻る。
    func renameItem(clipId: Int64, in pinboardId: Int64, to title: String) async throws {
        _ = try await dbWriter.write { db in
            let v: DatabaseValueConvertible = title.isEmpty ? DatabaseValue.null : title
            try db.execute(
                sql: "UPDATE pinboard_items SET title = ? WHERE pinboardId = ? AND clipId = ?",
                arguments: [v, pinboardId, clipId]
            )
        }
    }

    func unpin(clipId: Int64, fromBoard pinboardId: Int64) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM pinboard_items WHERE clipId = ? AND pinboardId = ?",
                           arguments: [clipId, pinboardId])
        }
    }

    /// v0.9.9-beta: キーボードでの相対並び替え。`delta` が +1 / -1 のように
    /// 現在位置からのオフセットで指定される (⌥↑ / ⌥↓)。端で操作しても
    /// クランプせず単に no-op にする (ドラッグ並び替えと同じセマンティクス)。
    func reorder(boardId: Int64, delta: Int) async throws {
        guard let idx = boards.firstIndex(where: { $0.id == boardId }) else { return }
        let newIdx = idx + delta
        guard newIdx >= 0, newIdx < boards.count else { return }
        try await reorder(boardId: boardId, to: newIdx)
    }

    /// v0.9.9-beta: ⌥⇧↑ で先頭にジャンプ。
    func moveToStart(boardId: Int64) async throws {
        guard let idx = boards.firstIndex(where: { $0.id == boardId }), idx > 0 else { return }
        try await reorder(boardId: boardId, to: 0)
    }

    /// v0.9.9-beta: ⌥⇧↓ で末尾にジャンプ。
    func moveToEnd(boardId: Int64) async throws {
        guard let idx = boards.firstIndex(where: { $0.id == boardId }), idx < boards.count - 1 else { return }
        try await reorder(boardId: boardId, to: boards.count - 1)
    }

    /// v0.8.6: フォルダタブのドラッグ並び替え。`boardId` を `newIndex` の位置に
    /// 移動し、`sortOrder` を 0..n-1 で振り直す。`reload()` 同期版を呼んで
    /// 並びを SwiftUI に反映する。
    func reorder(boardId: Int64, to newIndex: Int) async throws {
        _ = try await dbWriter.write { db in
            let all = try Pinboard.order(Pinboard.Columns.sortOrder).fetchAll(db)
            var working = all.filter { $0.id != boardId }
            guard let moving = all.first(where: { $0.id == boardId }) else { return }
            let clampedIndex = max(0, min(newIndex, working.count))
            working.insert(moving, at: clampedIndex)
            for (i, b) in working.enumerated() {
                guard let bid = b.id else { continue }
                try db.execute(sql: "UPDATE pinboards SET sortOrder = ? WHERE id = ?",
                               arguments: [i, bid])
            }
        }
        try reload()
    }

    static func defaultBoards() -> [(String, String)] {
        [("Inbox", "#7C8CF8"),
         ("Work", "#34C759"),
         ("Code", "#FF9F0A"),
         ("Refs", "#BF5AF2")]
    }
}

extension Color {
    init(hex: String) {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xff) / 255.0
        let g = Double((rgb >> 8)  & 0xff) / 255.0
        let b = Double(rgb        & 0xff) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
