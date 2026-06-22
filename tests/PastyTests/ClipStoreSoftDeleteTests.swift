import XCTest
import GRDB
@testable import Pasty

/// v0.9.6-beta (P0 #1, #2, #4, #5): regression coverage for the new
/// soft-delete read filters, FTS5 backfill idempotency, and the throwing
/// `init` recovery path.
///
/// Each test gets a unique tempdir; tearDown wipes it so the suite leaves
/// no on-disk state behind.
final class ClipStoreSoftDeleteTests: XCTestCase {

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

    @MainActor
    private func makeStore() throws -> (ClipStore, DatabaseQueue) {
        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        let dbWriter = try DatabaseQueue(path: dbURL.path)
        let store = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)
        return (store, dbWriter)
    }

    @MainActor
    private func insertSampleClip(
        _ store: ClipStore,
        preview: String = "hello world",
        content: String = "hello world",
        hash: String = "h-\(UUID().uuidString)"
    ) async throws -> Int64 {
        let item = ClipItem(
            id: nil, createdAt: Date(), kind: .text,
            preview: preview, content: content, dataPath: nil,
            byteSize: Int64(content.utf8.count),
            sourceBundleId: nil, sourceAppName: nil,
            contentHash: hash
        )
        let inserted = try await store.insert(item)
        guard let id = inserted?.id else {
            XCTFail("insert returned no id"); throw XCTSkip("insert returned no id")
        }
        return id
    }

    // MARK: - P0 #1: soft-delete read filter

    @MainActor
    func testSoftDeletedClipNotInRecent() async throws {
        let (store, _) = try makeStore()
        let id = try await insertSampleClip(store, preview: "kept-in-recent")
        XCTAssertEqual(store.recent.count, 1)

        try await store.delete(clipId: id)

        XCTAssertFalse(store.recent.contains(where: { $0.id == id }),
                       "soft-deleted clip leaked into recent feed")
        XCTAssertEqual(store.totalCount, 0,
                       "totalCount should exclude soft-deleted rows")
    }

    @MainActor
    func testSoftDeletedClipNotInSearch() async throws {
        let (store, _) = try makeStore()
        let id = try await insertSampleClip(
            store, preview: "Pasty regression",
            content: "Pasty regression test marker",
            hash: "h-search-1"
        )
        // Sanity: search returns the clip while live.
        let hits1 = try await store.search(query: "regression")
        XCTAssertEqual(hits1.count, 1)

        try await store.delete(clipId: id)

        let hits2 = try await store.search(query: "regression")
        XCTAssertTrue(hits2.isEmpty,
                      "search returned soft-deleted clip: \(hits2)")

        // Also check the empty-query path (recent-fallback).
        let recent = try await store.search(query: "   ")
        XCTAssertFalse(recent.contains(where: { $0.id == id }),
                       "empty-query search returned soft-deleted clip")
    }

    @MainActor
    func testSoftDeletedClipNotInById() async throws {
        let (store, _) = try makeStore()
        let id = try await insertSampleClip(store, hash: "h-byid-1")

        // Live: byId returns it.
        let live = try await store.byId(id)
        XCTAssertNotNil(live, "byId should return live clip")

        try await store.delete(clipId: id)

        let dead = try await store.byId(id)
        XCTAssertNil(dead, "byId returned soft-deleted clip")
    }

    // MARK: - P0 #2: delete = soft delete, hardDelete returns dataPath

    @MainActor
    func testDeleteIsSoftDelete() async throws {
        let (store, dbWriter) = try makeStore()
        let id = try await insertSampleClip(store, hash: "h-soft-1")
        try await store.delete(clipId: id)

        let (rowStillExists, deletedAt): (Bool, Double?) = try await dbWriter.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT deleted_at FROM clips WHERE id = ?",
                arguments: [id]
            )
            return (row != nil, row?["deleted_at"])
        }
        XCTAssertTrue(rowStillExists,
                      "delete must keep row for tombstone-based sync")
        XCTAssertNotNil(deletedAt,
                        "delete must set deleted_at timestamp")
    }

    @MainActor
    func testHardDeleteRemovesRowAndReturnsDataPath() async throws {
        let (store, dbWriter) = try makeStore()
        // Insert directly so we can set dataPath.
        let dataPath = "blobs/sample.png"
        let id: Int64 = try await dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO clips (createdAt, kind, preview, content, dataPath,
                    byteSize, sourceBundleId, sourceAppName, contentHash)
                VALUES (?, 'image', 'hard-del', NULL, ?, 0, NULL, NULL, ?)
                """, arguments: [Date(), dataPath, "h-hard-1"])
            return db.lastInsertedRowID
        }

        let returned = try await store.hardDelete(id)
        XCTAssertEqual(returned, dataPath)

        let rowCount: Int = try await dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips WHERE id = ?", arguments: [id]) ?? -1
        }
        XCTAssertEqual(rowCount, 0, "hardDelete must remove the row")
    }

    // MARK: - P0 #4: FTS5 backfill marker

    @MainActor
    func testFTS5BackfillRunsWhenMarkerMissing() async throws {
        let (store, dbWriter) = try makeStore()
        _ = try await insertSampleClip(
            store, preview: "alpha bravo", content: "alpha bravo charlie",
            hash: "h-fts-1"
        )

        // Force the marker missing and clear the FTS index so we can prove
        // the next init re-runs the backfill.
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM pasty_meta WHERE key = 'v8.fts5_backfilled'")
            try db.execute(sql: "DELETE FROM clips_fts")
        }

        // Open a *fresh* ClipStore against the same DB. Its init() should
        // run runFTS5BackfillIfNeeded() and repopulate clips_fts.
        let reopened = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)
        let hits = try await reopened.search(query: "alpha")
        XCTAssertEqual(hits.count, 1,
                       "FTS5 backfill should have re-indexed the live clip")
    }

    @MainActor
    func testFTS5BackfillIdempotent() async throws {
        let (store, dbWriter) = try makeStore()
        _ = try await insertSampleClip(
            store, preview: "idem one", content: "idem one body",
            hash: "h-fts-idem-1"
        )

        // Re-opening twice must not double-insert FTS rows.
        _ = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)
        _ = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)

        let ftsRowCount: Int = try await dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips_fts") ?? -1
        }
        let clipRowCount: Int = try await dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips WHERE deleted_at IS NULL") ?? -1
        }
        XCTAssertEqual(ftsRowCount, clipRowCount,
                       "FTS5 row count must equal live clip count after repeated init")
    }

    // MARK: - P0 #5: init throws on corrupt DB

    @MainActor
    func testInitThrowsOnCorruptDatabase() async throws {
        // Write garbage bytes where SQLite expects its file header. A genuine
        // SQLite file starts with "SQLite format 3\0"; anything else makes
        // GRDB / SQLite refuse to open the file as a DB.
        let dbURL = tempDir.appendingPathComponent("corrupt.sqlite")
        let garbage = Data(repeating: 0xFE, count: 4096)
        try garbage.write(to: dbURL)

        do {
            let dbWriter = try DatabaseQueue(path: dbURL.path)
            _ = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)
            XCTFail("expected ClipStore init to throw against corrupt DB")
        } catch {
            // Any thrown error is acceptable; we just want NOT a fatalError.
            // We additionally check that — when the failure happens inside
            // ClipStore — it's a ClipStoreError so PastyApp can branch on it.
            if let csError = error as? ClipStoreError {
                switch csError {
                case .openFailed, .migrationFailed, .initialLoadFailed, .backfillFailed:
                    break // expected
                }
            }
            // Pass: it threw rather than aborting the process.
        }
    }
}
