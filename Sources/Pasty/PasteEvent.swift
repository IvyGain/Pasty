import Foundation
import GRDB

/// 「いつ・どのクリップを・どのアプリに貼ったか」を 1 行ずつ永続化するレコード。
/// `PasteHistory`（メモリ上の Undo/再貼付バッファ）の永続化版で、Insights
/// ダッシュボードや学習ロジックの根拠データになる。
///
/// v0.4.2 で `paste_events` テーブルとして導入（migration `v3.paste_events`）。
struct PasteEvent: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: Int64?
    var clipId: Int64
    var targetBundleId: String?
    var targetAppName: String?
    var pastedAt: Date

    static let databaseTableName = "paste_events"

    enum Columns: String, ColumnExpression {
        case id, clipId, targetBundleId, targetAppName, pastedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - ClipStore extension: paste event queries

extension ClipStore {
    /// 貼付イベントを記録。`PasteAutomator` の `_doPaste` から非同期で呼ばれる。
    /// `clipId` が nil のクリップ（合成クリップ等）は対象外。
    func recordPaste(clipId: Int64,
                     targetBundleId: String?,
                     targetAppName: String?) async throws {
        _ = try await dbWriter.write { db in
            var event = PasteEvent(
                id: nil,
                clipId: clipId,
                targetBundleId: targetBundleId,
                targetAppName: targetAppName,
                pastedAt: Date()
            )
            try event.insert(db)
        }
    }

    /// 直近 N 件の貼付履歴（新しい順）。
    func recentPastes(limit: Int) async throws -> [PasteEvent] {
        try await dbWriter.read { db in
            try PasteEvent
                .order(PasteEvent.Columns.pastedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// よく貼るクリップ Top N（paste_events を集計、貼付回数 desc）。
    /// 返り値は `(クリップ本体, 貼付回数)` のタプル列。
    func mostPastedClips(limit: Int) async throws -> [(ClipItem, Int)] {
        try await dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*, COUNT(pe.id) AS cnt
                FROM clips c
                JOIN paste_events pe ON pe.clipId = c.id
                GROUP BY c.id
                ORDER BY cnt DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.compactMap { row -> (ClipItem, Int)? in
                // FetchableRecord 由来の init(row:) は throwing なので try? で握り潰す。
                // ここで一行スキップしても集計のレベル感に影響はない。
                guard let clip = try? ClipItem(row: row) else { return nil }
                let count: Int = row["cnt"] ?? 0
                return (clip, count)
            }
        }
    }

    /// 直近 N 日間の貼付件数。0 日指定なら「今日 (start-of-day から)」を返す。
    func pasteCount(since days: Int) async throws -> Int {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let from = calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday
        return try await dbWriter.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM paste_events WHERE pastedAt >= ?",
                arguments: [from]) ?? 0
        }
    }
}
