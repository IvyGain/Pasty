import Foundation
import GRDB
import Combine

/// SQLite-backed persistence for clipboard items. Local-first by design:
/// the database lives under `~/Library/Application Support/Pasty/`.
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var recent: [ClipItem] = []
    @Published private(set) var totalCount: Int = 0

    let dbWriter: any DatabaseWriter
    let blobDirectory: URL
    private var cancellables: Set<AnyCancellable> = []

    static func shared() throws -> ClipStore {
        let appSupport = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Pasty", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let dbURL = appSupport.appendingPathComponent("pasty.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)

        let blobs = appSupport.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

        let store = try ClipStore(dbWriter: dbQueue, blobDirectory: blobs)
        return store
    }

    init(dbWriter: any DatabaseWriter, blobDirectory: URL) throws {
        self.dbWriter = dbWriter
        self.blobDirectory = blobDirectory
        try migrate()
        try reloadInitial()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.clips") { db in
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("preview", .text).notNull()
                t.column("content", .text)
                t.column("dataPath", .text)
                t.column("byteSize", .integer).notNull().defaults(to: 0)
                t.column("sourceBundleId", .text)
                t.column("sourceAppName", .text)
                t.column("contentHash", .text).notNull().indexed()
            }
        }

        migrator.registerMigration("v1.fts5") { db in
            try db.create(virtualTable: "clips_fts", using: FTS5()) { t in
                t.synchronize(withTable: "clips")
                t.column("preview")
                t.column("content")
                t.column("sourceAppName")
            }
        }

        migrator.registerMigration("v2.pinboards") { db in
            try db.create(table: "pinboards") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull().defaults(to: "#7C8CF8")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "pinboard_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pinboardId", .integer).notNull()
                    .references("pinboards", onDelete: .cascade)
                t.column("clipId", .integer).notNull()
                    .references("clips", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["pinboardId", "clipId"])
            }
        }

        migrator.registerMigration("v2.seedPinboards") { db in
            let now = Date()
            for (i, pair) in PinboardStore.defaultBoards().enumerated() {
                try db.execute(sql: """
                    INSERT INTO pinboards (name, colorHex, sortOrder, createdAt)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [pair.0, pair.1, i, now])
            }
        }

        try migrator.migrate(dbWriter)
    }

    private func reloadInitial() throws {
        let snapshot: (items: [ClipItem], total: Int) = try dbWriter.read { db in
            let items = try ClipItem
                .order(ClipItem.Columns.createdAt.desc)
                .limit(20)
                .fetchAll(db)
            let total = try ClipItem.fetchCount(db)
            return (items, total)
        }
        self.recent = snapshot.items
        self.totalCount = snapshot.total
    }

    @discardableResult
    func insert(_ item: ClipItem) async throws -> ClipItem? {
        let inserted: ClipItem? = try await dbWriter.write { db in
            // Dedupe against the most recent matching hash.
            if let last = try ClipItem
                .order(ClipItem.Columns.createdAt.desc)
                .limit(1)
                .fetchOne(db),
               last.contentHash == item.contentHash {
                return nil
            }
            var copy = item
            try copy.insert(db)
            return copy
        }
        if inserted != nil {
            try reloadInitial()
        }
        return inserted
    }

    func search(query: String, limit: Int = 50) async throws -> [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try await dbWriter.read { db in
                try ClipItem
                    .order(ClipItem.Columns.createdAt.desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        }
        let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) ?? FTS5Pattern(matchingAnyTokenIn: trimmed)
        return try await dbWriter.read { db in
            let sql = """
                SELECT clips.* FROM clips
                JOIN clips_fts ON clips_fts.rowid = clips.id
                WHERE clips_fts MATCH ?
                ORDER BY clips.createdAt DESC
                LIMIT ?
                """
            return try ClipItem.fetchAll(db, sql: sql, arguments: [pattern, limit])
        }
    }

    func deleteAll() async throws {
        _ = try await dbWriter.write { db in
            try ClipItem.deleteAll(db)
        }
        try reloadInitial()
    }
}
