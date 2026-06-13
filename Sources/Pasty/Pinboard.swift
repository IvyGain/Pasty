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

    static let databaseTableName = "pinboard_items"
    enum Columns: String, ColumnExpression { case id, pinboardId, clipId, sortOrder }
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
            try ClipItem.fetchAll(db, sql: """
                SELECT c.* FROM clips c
                JOIN pinboard_items pi ON pi.clipId = c.id
                WHERE pi.pinboardId = ?
                ORDER BY pi.sortOrder
                """, arguments: [pinboardId])
        }
    }

    func unpin(clipId: Int64, fromBoard pinboardId: Int64) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM pinboard_items WHERE clipId = ? AND pinboardId = ?",
                           arguments: [clipId, pinboardId])
        }
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
