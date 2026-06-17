import Foundation
import GRDB
import Combine
import CryptoKit

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

        // v0.4.2: 貼付イベントの永続化。`PasteHistory` のメモリ版を補強し、
        // Insights ダッシュボードの「よく貼るクリップ」を正確な実測に切り替える。
        migrator.registerMigration("v3.paste_events") { db in
            try db.create(table: "paste_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("clipId", .integer).notNull()
                    .references("clips", onDelete: .cascade)
                    .indexed()
                t.column("targetBundleId", .text)
                t.column("targetAppName", .text)
                t.column("pastedAt", .datetime).notNull().indexed()
            }
        }

        // v0.4.9: フォルダ内クリップに表示名（title）を付けられるように。
        migrator.registerMigration("v4.pinboardItemTitle") { db in
            try db.execute(sql: "ALTER TABLE pinboard_items ADD COLUMN title TEXT")
        }

        // v0.8 (C1 phase 1): iCloud 同期足場。実際の同期ロジックは phase 2 で
        // 入る。ここでは journal テーブル + 全エンティティへの soft delete /
        // entity_uuid / provenance カラムだけを足す。詳しくは
        // `.ai/decisions/c1-icloud-sync-{architecture,security,schema}.md` を参照。
        migrator.registerMigration("v5.sync_journal") { db in
            try db.execute(sql: """
                CREATE TABLE sync_journal (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    op TEXT NOT NULL,
                    entity_type TEXT NOT NULL,
                    entity_uuid TEXT NOT NULL,
                    lamport INTEGER NOT NULL,
                    device_id TEXT NOT NULL,
                    encrypted_payload BLOB,
                    nonce BLOB NOT NULL,
                    schema_version INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL,
                    synced_at REAL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_sync_journal_device_lamport ON sync_journal(device_id, lamport)")
            try db.execute(sql: "CREATE INDEX idx_sync_journal_entity_uuid ON sync_journal(entity_uuid)")
            try db.execute(sql: "CREATE INDEX idx_sync_journal_unsynced ON sync_journal(synced_at) WHERE synced_at IS NULL")
        }

        migrator.registerMigration("v5.soft_delete_columns") { db in
            for table in ["clips", "pinboards", "pinboard_items"] {
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN deleted_at REAL")
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN updated_at REAL NOT NULL DEFAULT 0")
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN origin_device_id TEXT")
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN entity_uuid TEXT")
            }
        }

        migrator.registerMigration("v5.entity_uuid_backfill") { db in
            for table in ["clips", "pinboards", "pinboard_items"] {
                // SQLite の randomblob を使った in-place UUID 生成。
                try db.execute(sql: """
                    UPDATE \(table)
                    SET entity_uuid = lower(hex(randomblob(16)))
                    WHERE entity_uuid IS NULL OR entity_uuid = ''
                    """)
            }
        }

        try migrator.migrate(dbWriter)
    }

    /// 現在の端末を識別する UUID。Keychain に置きたいが、phase 1 では
    /// `UserDefaults` の `pasty.deviceId` キーに保存する暫定実装。
    static var currentDeviceId: String {
        let key = "pasty.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
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
        let deviceId = Self.currentDeviceId
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
            // v0.8 (C1 phase 1): origin_device_id と entity_uuid を最終行に
            // 刻む。実際の同期は CloudSyncEngine 側で phase 2 で実装。
            if let rowId = copy.id {
                try db.execute(sql: """
                    UPDATE clips
                    SET origin_device_id = ?,
                        updated_at = ?,
                        entity_uuid = COALESCE(NULLIF(entity_uuid, ''), lower(hex(randomblob(16))))
                    WHERE id = ?
                    """, arguments: [deviceId, Date().timeIntervalSince1970, rowId])
            }
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

    /// ユーザが Pasty 内で「新しい定型文」を作るときの保存口。
    /// クリップボードに置いた覚えはなくても、Pasty の中で書いた文は即倉庫に入る。
    @discardableResult
    func createTextClip(content: String,
                        pinTo pinboardId: Int64? = nil,
                        preview: String? = nil,
                        sourceAppName: String = "Pasty") async throws -> ClipItem {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let view = preview ?? String(trimmed.split(separator: "\n").first ?? "").prefix(120).description
        let hash = SHA256Helper.hash(of: trimmed)

        let inserted: ClipItem? = try await dbWriter.write { db in
            var item = ClipItem(
                id: nil,
                createdAt: Date(),
                kind: .text,
                preview: view.isEmpty ? "Untitled snippet" : view,
                content: content,
                dataPath: nil,
                byteSize: Int64(content.utf8.count),
                sourceBundleId: "io.pasty.snippet",
                sourceAppName: sourceAppName,
                contentHash: hash
            )
            try item.insert(db)
            return item
        }

        try reloadInitial()
        return inserted ?? ClipItem(
            id: nil, createdAt: Date(), kind: .text,
            preview: view, content: content, dataPath: nil,
            byteSize: 0, sourceBundleId: nil, sourceAppName: nil, contentHash: ""
        )
    }

    /// 既存クリップの本文を上書き（編集機能のバックエンド）。
    func update(clipId: Int64, content: String) async throws {
        _ = try await dbWriter.write { db in
            let preview = String(content.split(separator: "\n").first ?? "").prefix(120).description
            try db.execute(
                sql: "UPDATE clips SET content = ?, preview = ?, byteSize = ? WHERE id = ?",
                arguments: [content, preview, Int64(content.utf8.count), clipId]
            )
        }
        try reloadInitial()
    }

    func delete(clipId: Int64) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [clipId])
        }
        try reloadInitial()
    }
}

enum SHA256Helper {
    static func hash(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
