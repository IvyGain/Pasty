import Foundation
import GRDB

/// Pasty's mini search DSL. Examples:
///   • `pasty`                      — plain FTS5 keyword
///   • `type:link safari`           — kind filter + keyword
///   • `source:VSCode swift`        — source-app filter + keyword
///   • `/(TODO|FIXME)/`             — regex over preview + content
///   • `>1d`                        — anything from the last day
///   • `pinboard:Code react`        — restrict to a pinboard
struct SearchQuery {
    var freeText: String = ""
    var kind: ClipKind?
    var sourceApp: String?
    var pinboard: String?
    var withinDays: Int?
    var regex: NSRegularExpression?
    var limit: Int = 80

    static func parse(_ raw: String) -> SearchQuery {
        var q = SearchQuery()
        var freeParts: [String] = []

        for token in raw.split(separator: " ") {
            let t = String(token)
            if t.hasPrefix("type:") {
                q.kind = ClipKind(rawValue: String(t.dropFirst(5)).lowercased())
            } else if t.hasPrefix("source:") {
                q.sourceApp = String(t.dropFirst(7))
            } else if t.hasPrefix("pinboard:") {
                q.pinboard = String(t.dropFirst(9))
            } else if t.hasPrefix(">") && t.hasSuffix("d"),
                      let days = Int(t.dropFirst().dropLast()) {
                q.withinDays = days
            } else if t.hasPrefix("/") && t.hasSuffix("/") && t.count >= 2 {
                let pattern = String(t.dropFirst().dropLast())
                q.regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive])
            } else {
                freeParts.append(t)
            }
        }

        q.freeText = freeParts.joined(separator: " ")
        return q
    }
}

enum SearchEngine {
    @MainActor
    static func run(_ q: SearchQuery, store: ClipStore) async throws -> [ClipItem] {
        try await store.dbWriter.read { db in
            // Resolve pinboard-id filter, if any.
            var pinboardClipIDs: Set<Int64>? = nil
            if let name = q.pinboard, !name.isEmpty {
                let ids = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT pi.clipId FROM pinboard_items pi
                        JOIN pinboards p ON p.id = pi.pinboardId
                        WHERE p.name LIKE ?
                        """,
                    arguments: ["%\(name)%"]
                )
                pinboardClipIDs = Set(ids)
                if pinboardClipIDs!.isEmpty { return [] }
            }

            var rows: [ClipItem]
            if q.freeText.isEmpty {
                // v0.9.6-beta (follow-up #1): exclude soft-deleted rows from
                // the empty-query / browse path so the search DSL never
                // surfaces tombstoned clips even when no FTS5 MATCH is used.
                rows = try ClipItem
                    .filter(sql: "deleted_at IS NULL")
                    .order(ClipItem.Columns.createdAt.desc)
                    .limit(q.limit * 2)
                    .fetchAll(db)
            } else {
                let pattern = FTS5Pattern(matchingAllPrefixesIn: q.freeText)
                    ?? FTS5Pattern(matchingAnyTokenIn: q.freeText)
                // v0.9.6-beta (follow-up #1): clips_fts is in external-content
                // mode; soft-deleted rows can linger in the FTS index until the
                // clips_softdelete_au trigger (migration v10) fires or a
                // backfill rebuilds it. AND clips.deleted_at IS NULL on the
                // clips side so the DSL stays consistent with ClipStore.search.
                // v0.9.9-beta (Cluster D D1): rank FTS hits by BM25 first so the
                // most relevant snippet floats up, then fall back to createdAt DESC
                // as a deterministic tiebreaker (and to preserve the recent-first
                // feel for ties / equal-score matches).
                rows = try ClipItem.fetchAll(db, sql: """
                    SELECT clips.* FROM clips
                    JOIN clips_fts ON clips_fts.rowid = clips.id
                    WHERE clips_fts MATCH ?
                      AND clips.deleted_at IS NULL
                    ORDER BY bm25(clips_fts) ASC, clips.createdAt DESC
                    LIMIT ?
                    """, arguments: [pattern, q.limit * 2])
            }

            if let kind = q.kind {
                // 拡張子ベースの fuzzy 判定: kind=.file の PNG も .image フィルタにヒット
                rows = rows.filter { $0.matchesFilter(kind) }
            }
            if let src = q.sourceApp?.lowercased(), !src.isEmpty {
                rows = rows.filter { ($0.sourceAppName ?? "").lowercased().contains(src) }
            }
            if let days = q.withinDays {
                let threshold = Date(timeIntervalSinceNow: -TimeInterval(days) * 86_400)
                rows = rows.filter { $0.createdAt >= threshold }
            }
            if let regex = q.regex {
                rows = rows.filter { row in
                    let haystack = (row.content ?? "") + "\n" + row.preview
                    let range = NSRange(haystack.startIndex..., in: haystack)
                    return regex.firstMatch(in: haystack, range: range) != nil
                }
            }
            if let ids = pinboardClipIDs {
                rows = rows.filter { ids.contains($0.id ?? -1) }
            }

            return Array(rows.prefix(q.limit))
        }
    }
}
