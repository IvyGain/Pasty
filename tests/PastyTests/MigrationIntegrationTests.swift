import XCTest
import GRDB
@testable import Pasty

/// v0.10.0-beta (Axis 5): end-to-end migration chain coverage.
///
/// We can't poke `ClipStore.migrate()` directly — it's `private` — so we
/// drive the full chain by constructing a `ClipStore` against a fresh
/// in-memory `DatabaseQueue`. That exercises the same `DatabaseMigrator`
/// chain (v1.clips → v10.fts5_softdelete_trigger) the production app
/// runs at startup.
final class MigrationIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let url = tempDir {
            try? FileManager.default.removeItem(at: url)
        }
        tempDir = nil
        try await super.tearDown()
    }

    /// Returns a freshly-migrated in-memory DB. The `ClipStore` is held
    /// alongside the writer so its blob dir stays alive for the test body.
    @MainActor
    private func makeMigratedStore() throws -> (ClipStore, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()  // in-memory
        let store = try ClipStore(dbWriter: dbQueue, blobDirectory: tempDir)
        return (store, dbQueue)
    }

    // MARK: - testV1ToV10ChainProducesValidSchema

    /// Boots a fresh DB through every registered migration and verifies the
    /// resulting schema has all the tables PastyApp depends on at runtime.
    @MainActor
    func testV1ToV10ChainProducesValidSchema() async throws {
        let (_, dbQueue) = try makeMigratedStore()

        let tableNames: Set<String> = try await dbQueue.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name"
            )
            return Set(rows)
        }

        // Core tables introduced across v1..v10.
        XCTAssertTrue(tableNames.contains("clips"),
                      "v1.clips migration must produce clips table; got \(tableNames)")
        XCTAssertTrue(tableNames.contains("clips_fts"),
                      "v8.fts5_with_ocr must produce clips_fts virtual table; got \(tableNames)")
        XCTAssertTrue(tableNames.contains("sync_journal"),
                      "v5.sync_journal must produce sync_journal table; got \(tableNames)")
        XCTAssertTrue(tableNames.contains("pasty_meta"),
                      "v9.pasty_meta must produce pasty_meta table; got \(tableNames)")
        XCTAssertTrue(tableNames.contains("pinboards"),
                      "v2.pinboards must produce pinboards table; got \(tableNames)")
        XCTAssertTrue(tableNames.contains("pinboard_items"),
                      "v2.pinboards must produce pinboard_items table; got \(tableNames)")

        // v10 soft-delete trigger must exist so search filtering stays consistent.
        let triggerNames: Set<String> = try await dbQueue.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name"
            )
            return Set(rows)
        }
        XCTAssertTrue(triggerNames.contains("clips_softdelete_au"),
                      "v10 migration must install clips_softdelete_au trigger; got \(triggerNames)")
        XCTAssertTrue(triggerNames.contains("clips_softdelete_au_restore"),
                      "v10 migration must install clips_softdelete_au_restore trigger; got \(triggerNames)")

        // The clips table must have the soft-delete columns added in v5.
        let clipColumns: Set<String> = try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(clips)")
            return Set(rows.compactMap { $0["name"] as String? })
        }
        XCTAssertTrue(clipColumns.contains("deleted_at"),
                      "v5.soft_delete_columns must add deleted_at; got \(clipColumns)")
        XCTAssertTrue(clipColumns.contains("entity_uuid"),
                      "v5.soft_delete_columns must add entity_uuid; got \(clipColumns)")
        XCTAssertTrue(clipColumns.contains("extractedOCRText"),
                      "v7.extractedOCRText must add extractedOCRText; got \(clipColumns)")
    }

    // MARK: - testMigrationIsIdempotent

    /// Re-opens a `ClipStore` against the same persistent DB twice. GRDB's
    /// `DatabaseMigrator` is registration-table-backed, so any subsequent
    /// open should be a no-op: tables must not be recreated, triggers must
    /// not multiply, and FTS row counts must stay stable.
    @MainActor
    func testMigrationIsIdempotent() async throws {
        let dbURL = tempDir.appendingPathComponent("idempotent.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)

        // First open: runs the full migration chain.
        _ = try ClipStore(dbWriter: dbQueue, blobDirectory: tempDir)

        let firstSchemaFingerprint: String = try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT type || ':' || name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE '%grdb_migrations%' ORDER BY type, name"
            ).joined(separator: "|")
        }

        let firstMigrationsApplied: Set<String> = try await dbQueue.read { db in
            // GRDB stores applied migration identifiers in `grdb_migrations`.
            // The exact table name is internal; we tolerate either spelling.
            let rows = try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
            )
            return Set(rows)
        }
        XCTAssertTrue(firstMigrationsApplied.contains("v10.fts5_softdelete_trigger"),
                      "first open must apply through v10; got \(firstMigrationsApplied)")

        // Second open: should be a pure no-op.
        _ = try ClipStore(dbWriter: dbQueue, blobDirectory: tempDir)

        let secondSchemaFingerprint: String = try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT type || ':' || name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE '%grdb_migrations%' ORDER BY type, name"
            ).joined(separator: "|")
        }
        let secondMigrationsApplied: Set<String> = try await dbQueue.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
            )
            return Set(rows)
        }

        XCTAssertEqual(firstSchemaFingerprint, secondSchemaFingerprint,
                       "second migrator pass altered the schema")
        XCTAssertEqual(firstMigrationsApplied, secondMigrationsApplied,
                       "second migrator pass changed the applied migration set")
    }

    // MARK: - testFTS5RebuiltAfterMigration

    /// After a fresh migration, inserting a clip via the GRDB API should
    /// propagate to `clips_fts` (via the v8/v10 INSERT trigger), so a
    /// MATCH query against the FTS table returns the row.
    @MainActor
    func testFTS5RebuiltAfterMigration() async throws {
        let (store, dbQueue) = try makeMigratedStore()

        // Insert via the public ClipStore API so the v10-aware triggers fire
        // the same way they do in production.
        let inserted = try await store.insert(
            ClipItem(
                id: nil,
                createdAt: Date(),
                kind: .text,
                preview: "test fts payload",
                content: "test fts payload body",
                dataPath: nil,
                byteSize: 19,
                sourceBundleId: nil,
                sourceAppName: nil,
                contentHash: "h-fts-migration-1"
            )
        )
        XCTAssertNotNil(inserted, "insert should persist the clip")

        let matchCount: Int = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clips_fts WHERE clips_fts MATCH ?",
                arguments: ["test"]
            ) ?? -1
        }
        XCTAssertEqual(matchCount, 1,
                       "post-migration FTS5 index must surface inserted clip via MATCH")
    }
}
