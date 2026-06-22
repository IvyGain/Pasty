import Foundation
import GRDB
import Combine
import CryptoKit
import os

/// v0.9.6-beta (P0 #5): typed errors so PastyApp can distinguish DB failure
/// modes and decide whether to recover by renaming/replacing the file vs.
/// hard-failing. We surface the underlying GRDB / SQLite error verbatim for
/// crash reports and logs.
enum ClipStoreError: Error {
    case openFailed(underlying: Error)
    case migrationFailed(underlying: Error)
    case initialLoadFailed(underlying: Error)
    case backfillFailed(underlying: Error)
}

private let clipStoreLogger = Logger(subsystem: "io.pasty.app", category: "ClipStore")

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
        try PerfLog.timing("clipStore.shared.total") {
            let appSupport = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Pasty", isDirectory: true)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

            let dbURL = appSupport.appendingPathComponent("pasty.sqlite")
            let dbQueue: DatabaseQueue
            do {
                dbQueue = try DatabaseQueue(path: dbURL.path)
            } catch {
                throw ClipStoreError.openFailed(underlying: error)
            }

            let blobs = appSupport.appendingPathComponent("blobs", isDirectory: true)
            try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

            let store = try ClipStore(dbWriter: dbQueue, blobDirectory: blobs)
            return store
        }
    }

    init(dbWriter: any DatabaseWriter, blobDirectory: URL) throws {
        self.dbWriter = dbWriter
        self.blobDirectory = blobDirectory
        do {
            try migrate()
        } catch let error as ClipStoreError {
            throw error
        } catch {
            throw ClipStoreError.migrationFailed(underlying: error)
        }
        // v0.9.6-beta (P0 #4): FTS5 backfill idempotency marker. If migration v9
        // is fresh or the marker is missing/false, re-run the backfill so that
        // soft-deleted-aware FTS index stays consistent with `clips`.
        do {
            try runFTS5BackfillIfNeeded()
        } catch {
            // Don't fail init for a marker glitch — but log loudly. Search may
            // be partially stale until the next launch.
            clipStoreLogger.error("FTS5 backfill failed: \(String(describing: error), privacy: .public)")
        }
        do {
            try reloadInitial()
        } catch {
            throw ClipStoreError.initialLoadFailed(underlying: error)
        }
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

        // v0.8.4-beta (M-2): entity_uuid backfill は同期マイグレーションから外し、
        // 起動後にバックグラウンドで分割実行する。大容量 clips テーブルでの
        // 起動ストールを避けるため。フラグは UserDefaults で 1 回だけ完了判定する。

        // v0.9.5-beta (B3): perApp retention は SettingsStore.perAppRetentionRules で
        // 値を持つので、clips テーブルへの新規カラムは不要。schema バージョン番号だけ
        // 進めて、後続 codegen が cleanup ロジックを足したときの参照点にする。
        migrator.registerMigration("v6.perAppRetentionDays") { _ in
            // intentionally empty: storage lives in UserDefaults via SettingsStore.
        }

        // v0.9.5-beta (B6): 画像クリップに対する Vision OCR 結果のキャッシュカラム。
        // FTS5 (`clips_fts`) への組み込みは B6 ロジック codegen で別途行う。
        migrator.registerMigration("v7.extractedOCRText") { db in
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN extractedOCRText TEXT")
        }

        // v0.9.5-beta (B6): FTS5 仮想テーブルを再構築して extractedOCRText を
        // 検索対象に含める。content='clips' / content_rowid='id' で外部 content
        // モードに切り替え、INSERT/UPDATE/DELETE トリガーで本体テーブルと同期する。
        // 既存行はマイグレーション時に一括 backfill する。
        migrator.registerMigration("v8.fts5_with_ocr") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_au")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_ad")
            try db.execute(sql: "DROP TABLE IF EXISTS clips_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    preview, content, sourceAppName, extractedOCRText,
                    content='clips', content_rowid='id'
                )
                """)
            try db.execute(sql: """
                INSERT INTO clips_fts(rowid, preview, content, sourceAppName, extractedOCRText)
                SELECT id, preview, content, sourceAppName, extractedOCRText FROM clips
                """)
            try db.execute(sql: """
                CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
                  INSERT INTO clips_fts(rowid, preview, content, sourceAppName, extractedOCRText)
                  VALUES (new.id, new.preview, new.content, new.sourceAppName, new.extractedOCRText);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
                  INSERT INTO clips_fts(clips_fts, rowid, preview, content, sourceAppName, extractedOCRText)
                  VALUES ('delete', old.id, old.preview, old.content, old.sourceAppName, old.extractedOCRText);
                  INSERT INTO clips_fts(rowid, preview, content, sourceAppName, extractedOCRText)
                  VALUES (new.id, new.preview, new.content, new.sourceAppName, new.extractedOCRText);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                  INSERT INTO clips_fts(clips_fts, rowid, preview, content, sourceAppName, extractedOCRText)
                  VALUES ('delete', old.id, old.preview, old.content, old.sourceAppName, old.extractedOCRText);
                END
                """)
        }

        // v0.9.6-beta (P0 #4): generic meta key/value table so we can record
        // idempotency markers (e.g. FTS5 backfill state) without bloating
        // UserDefaults or coupling them to migration version numbers.
        migrator.registerMigration("v9.pasty_meta") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pasty_meta(
                    key TEXT PRIMARY KEY,
                    value TEXT
                )
                """)
        }

        try migrator.migrate(dbWriter)
    }

    // MARK: - FTS5 backfill idempotency (P0 #4)

    /// v0.9.6-beta (P0 #4): if the `pasty_meta` marker `v8.fts5_backfilled`
    /// isn't `"true"`, wipe `clips_fts` and re-insert every live row (rows
    /// where `deleted_at IS NULL`). Soft-deleted rows stay out of the FTS
    /// index so search doesn't accidentally surface them.
    ///
    /// Called once per init; cheap when the marker is already set (just a
    /// SELECT). Wrapped in a single transaction so a partial backfill can't
    /// leave the FTS table inconsistent.
    private func runFTS5BackfillIfNeeded() throws {
        try dbWriter.write { db in
            let marker = try String.fetchOne(
                db,
                sql: "SELECT value FROM pasty_meta WHERE key = ?",
                arguments: ["v8.fts5_backfilled"]
            )
            if marker == "true" { return }

            try db.execute(sql: "DELETE FROM clips_fts")
            try db.execute(sql: """
                INSERT INTO clips_fts(rowid, preview, content, sourceAppName, extractedOCRText)
                SELECT id, preview, content, sourceAppName, extractedOCRText
                FROM clips
                WHERE deleted_at IS NULL
                """)
            try db.execute(sql: """
                INSERT OR REPLACE INTO pasty_meta(key, value)
                VALUES ('v8.fts5_backfilled', 'true')
                """)
        }
    }

    // MARK: - Deferred entity_uuid backfill (M-2)

    /// 起動後にバックグラウンドで実行される。`entity_uuid` が NULL の行を
    /// 500 件ずつ埋める。完了したら UserDefaults フラグで二度と走らせない。
    /// insert() / update() は既に新規行に entity_uuid を刻んでいるので、
    /// `WHERE entity_uuid IS NULL` ガードがある限り並行 INSERT と衝突しない。
    func backfillEntityUUIDsIfNeeded() async {
        let flagKey = "pasty.entityUuidBackfillCompleted"
        if UserDefaults.standard.bool(forKey: flagKey) { return }

        await Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                while true {
                    let affected = try await self.runBackfillBatch(limit: 500)
                    if affected == 0 { break }
                }
                UserDefaults.standard.set(true, forKey: flagKey)
            } catch {
                // ログだけ残して伝播しない。次回起動でリトライされる。
                NSLog("[ClipStore] entity_uuid backfill failed: \(error)")
            }
        }.value
    }

    /// 1 バッチ分の backfill を実行し、影響を受けた総行数を返す。
    /// `clips` / `pinboards` / `pinboard_items` 各テーブルで `entity_uuid IS NULL`
    /// の行を最大 `limit` 件ずつ UUID で埋める。
    private func runBackfillBatch(limit: Int) async throws -> Int {
        try await dbWriter.write { db in
            var totalAffected = 0
            for table in ["clips", "pinboards", "pinboard_items"] {
                // SQLite の randomblob を使った in-place UUID 生成。
                // WHERE 句で IS NULL / '' ガードを掛けるので並行 INSERT と衝突しない。
                try db.execute(sql: """
                    UPDATE \(table)
                    SET entity_uuid = lower(hex(randomblob(16)))
                    WHERE rowid IN (
                        SELECT rowid FROM \(table)
                        WHERE entity_uuid IS NULL OR entity_uuid = ''
                        LIMIT \(limit)
                    )
                    """)
                totalAffected += db.changesCount
            }
            return totalAffected
        }
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
        // v0.9.6-beta (P0 #1): exclude soft-deleted rows from the in-memory
        // recent feed and the total counter so the menu bar / strip never
        // surface tombstones.
        let snapshot: (items: [ClipItem], total: Int) = try dbWriter.read { db in
            let items = try ClipItem
                .filter(sql: "deleted_at IS NULL")
                .order(ClipItem.Columns.createdAt.desc)
                .limit(20)
                .fetchAll(db)
            let total = try ClipItem
                .filter(sql: "deleted_at IS NULL")
                .fetchCount(db)
            return (items, total)
        }
        self.recent = snapshot.items
        self.totalCount = snapshot.total
    }

    /// v0.9.6-beta (P0 #1): typed lookup by primary key, soft-delete aware.
    /// Returns `nil` for unknown ids *and* for ids whose row has been
    /// tombstoned, so UI / paste-stack call sites can't accidentally
    /// resurrect a deleted clip.
    func byId(_ id: Int64) async throws -> ClipItem? {
        try await dbWriter.read { db in
            try ClipItem
                .filter(sql: "deleted_at IS NULL")
                .filter(ClipItem.Columns.id == id)
                .fetchOne(db)
        }
    }

    @discardableResult
    func insert(_ item: ClipItem) async throws -> ClipItem? {
        let deviceId = Self.currentDeviceId
        let inserted: ClipItem? = try await dbWriter.write { db in
            // Dedupe against the most recent matching hash.
            // v0.9.6-beta (P0 #1): skip soft-deleted rows so re-pasting after
            // a delete re-creates the clip (the user just brought it back —
            // honour that signal).
            if let last = try ClipItem
                .filter(sql: "deleted_at IS NULL")
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
            // v0.9.6-beta (P0 #1): empty-query path returns the recent feed —
            // mirror the soft-delete filter applied in reloadInitial.
            return try await dbWriter.read { db in
                try ClipItem
                    .filter(sql: "deleted_at IS NULL")
                    .order(ClipItem.Columns.createdAt.desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        }
        let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) ?? FTS5Pattern(matchingAnyTokenIn: trimmed)
        return try await dbWriter.read { db in
            // v0.9.6-beta (P0 #1): the FTS5 join doesn't know about
            // `deleted_at`, so AND it on the clips side. The FTS5 backfill
            // (runFTS5BackfillIfNeeded) skips tombstoned rows on a fresh
            // backfill, but live deletes only land in clips_fts via the
            // clips_ad trigger after a hard DELETE — so for the soft-delete
            // window this WHERE is the only guard.
            let sql = """
                SELECT clips.* FROM clips
                JOIN clips_fts ON clips_fts.rowid = clips.id
                WHERE clips_fts MATCH ?
                  AND clips.deleted_at IS NULL
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

    /// v0.9.5-beta (B6): Vision OCR の結果を該当クリップに永続化する。
    /// FTS5 トリガー (clips_au) が走るため検索インデックスも同時に更新される。
    /// `reloadInitial()` を呼ばないのは、OCR はバックグラウンド処理で
    /// UI 上のレコード並びには影響しない／頻繁に走り得るため。
    func updateOCRText(clipId: Int64, text: String) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE clips SET extractedOCRText = ?, updated_at = ? WHERE id = ?",
                arguments: [text, Date().timeIntervalSince1970, clipId]
            )
        }
    }

    /// v0.9.6-beta (P0 #2): UI delete is now a **soft delete**. The row stays
    /// in `clips` with `deleted_at` set so iCloud sync (C1 phase 2) can ship
    /// a tombstone. Any blob on disk is reclaimed later by `BlobGC` via
    /// `hardDelete(_:)` during the startup sweep.
    ///
    /// Call sites (StripPanel, AIActionMenu, etc.) remain identical; the
    /// signature is unchanged.
    func delete(clipId: Int64) async throws {
        let nowTS = Date().timeIntervalSince1970
        _ = try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE clips SET deleted_at = ?, updated_at = ? WHERE id = ?",
                arguments: [nowTS, nowTS, clipId]
            )
        }
        try reloadInitial()
    }

    /// v0.9.6-beta (P0 #2): physically remove a row from `clips` (and the
    /// matching `clips_fts` row) and return its `dataPath` so the caller
    /// (BlobGC) can unlink the on-disk blob. Reserved for the startup GC
    /// sweep — UI code should keep calling `delete(clipId:)`.
    ///
    /// Returns `nil` when the row no longer exists.
    @discardableResult
    func hardDelete(_ id: Int64) async throws -> String? {
        try await dbWriter.write { db in
            // Snapshot the dataPath before the row goes away.
            let dataPath = try String.fetchOne(
                db,
                sql: "SELECT dataPath FROM clips WHERE id = ?",
                arguments: [id]
            )
            // clips_fts is in external-content mode (content='clips',
            // content_rowid='id'), so the proper sync is the clips_ad
            // trigger which fires on DELETE FROM clips. We don't issue a
            // direct DELETE on clips_fts because external-content tables
            // reject row-level deletes outside the 'delete' command.
            try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id])
            return dataPath
        }
    }

    /// v0.9.5-beta (B3): アプリ別 + グローバル保持期間に基づく soft delete。
    ///
    /// - `globalDays`: ルール対象外の `sourceBundleId` を持つクリップに適用する
    ///   既定の保持日数。`<= 0` の場合はグローバル cleanup を行わない (= 無期限)。
    ///   SettingsStore の `maxRetentionDays` が `-1` のときは無期限扱い。
    /// - `perAppRules`: アプリ別の上書きルール。`rule.days == -1` は当該アプリの
    ///   クリップを無期限保護する (cleanup 対象から外す)。`rule.days > 0` は
    ///   そのアプリのクリップを当該日数で soft delete する。
    ///
    /// 削除は **soft delete** (`deleted_at` をセット) で行う。物理 DELETE を
    /// 走らせると C1 phase 2 の iCloud 同期 (tombstone 起点) と衝突するため。
    /// UI 側のリスト/検索クエリは将来的に `deleted_at IS NULL` を付けて読み出す。
    ///
    /// 戻り値は影響を受けたクリップ件数 (global + perApp の合計)。テスト用途。
    @discardableResult
    func cleanupOld(globalDays: Int,
                    perAppRules: [PerAppRetentionRule]) async throws -> Int {
        // 早期 return: globalDays <= 0 かつ perAppRules も全件無期限なら何もしない。
        let perAppExpiring = perAppRules.filter { $0.days > 0 }
        let globalActive = globalDays > 0
        if !globalActive && perAppExpiring.isEmpty {
            return 0
        }

        let now = Date()
        let nowTS = now.timeIntervalSince1970
        let knownBundleIds = perAppRules.map { $0.bundleId }

        let affected: Int = try await dbWriter.write { db in
            var total = 0

            // 1. global cleanup: knownBundleIds に含まれない (= ルールなし) 行を
            //    globalDays で soft delete。`sourceBundleId IS NULL` の行も
            //    "ルールなし" なのでこちらに乗る。
            if globalActive {
                let cutoff = now.addingTimeInterval(-Double(globalDays) * 86400)
                var sql = """
                    UPDATE clips
                    SET deleted_at = ?, updated_at = ?
                    WHERE deleted_at IS NULL
                      AND createdAt < ?
                    """
                var args: [DatabaseValueConvertible] = [nowTS, nowTS, cutoff]
                if !knownBundleIds.isEmpty {
                    let placeholders = knownBundleIds.map { _ in "?" }.joined(separator: ",")
                    sql += " AND (sourceBundleId IS NULL OR sourceBundleId NOT IN (\(placeholders)))"
                    args.append(contentsOf: knownBundleIds.map { $0 as DatabaseValueConvertible })
                }
                try db.execute(sql: sql, arguments: StatementArguments(args))
                total += db.changesCount
            }

            // 2. per-app cleanup: rule.days > 0 のものだけ実行。
            //    rule.days == -1 (無期限) は knownBundleIds に含まれているので
            //    上の global cleanup の `NOT IN` で保護されている。
            for rule in perAppExpiring {
                let cutoff = now.addingTimeInterval(-Double(rule.days) * 86400)
                try db.execute(sql: """
                    UPDATE clips
                    SET deleted_at = ?, updated_at = ?
                    WHERE deleted_at IS NULL
                      AND createdAt < ?
                      AND sourceBundleId = ?
                    """, arguments: [nowTS, nowTS, cutoff, rule.bundleId])
                total += db.changesCount
            }

            return total
        }

        // 削除されたクリップが recent / totalCount に反映されるよう再読み込み。
        if affected > 0 {
            try reloadInitial()
        }
        return affected
    }
}

enum SHA256Helper {
    static func hash(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
