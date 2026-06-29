import XCTest
import GRDB
@testable import Pasty

/// v0.10.0-beta (Axis 5): end-to-end soft-delete + RetentionSweeper coverage.
///
/// Where `ClipStoreSoftDeleteTests` proves the read filters and the v10
/// FTS5 trigger behave correctly on the insert/delete edge, this suite
/// drives the full tombstone lifecycle: search-hiding, restore, and the
/// 90-day GC cutoff enforced by `RetentionSweeper`.
final class SoftDeleteLifecycleTests: XCTestCase {

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
        preview: String = "lifecycle marker",
        content: String = "lifecycle marker payload",
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

    // MARK: - testDeleteHidesFromSearch

    @MainActor
    func testDeleteHidesFromSearch() async throws {
        let (store, _) = try makeStore()
        let id = try await insertSampleClip(
            store,
            preview: "Pasty hideme",
            content: "Pasty hideme search canary",
            hash: "h-lifecycle-hide-1"
        )

        let hitsLive = try await store.search(query: "hideme")
        XCTAssertEqual(hitsLive.count, 1,
                       "search must surface the live clip pre-delete")

        try await store.delete(clipId: id)

        let hitsDead = try await store.search(query: "hideme")
        XCTAssertTrue(hitsDead.isEmpty,
                      "soft-deleted clip must not appear in search; got \(hitsDead)")
    }

    // MARK: - testRestoreShowsInSearchAgain

    @MainActor
    func testRestoreShowsInSearchAgain() async throws {
        let (store, dbWriter) = try makeStore()
        let id = try await insertSampleClip(
            store,
            preview: "Pasty restoreme",
            content: "Pasty restoreme search canary",
            hash: "h-lifecycle-restore-1"
        )

        try await store.delete(clipId: id)
        let hitsAfterDelete = try await store.search(query: "restoreme")
        XCTAssertTrue(hitsAfterDelete.isEmpty,
                      "sanity: clip should be hidden after soft-delete")

        // Restore by clearing deleted_at. The v10 `clips_softdelete_au_restore`
        // trigger should re-insert the row into clips_fts.
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE clips SET deleted_at = NULL WHERE id = ?",
                arguments: [id]
            )
        }

        let hitsAfterRestore = try await store.search(query: "restoreme")
        XCTAssertEqual(hitsAfterRestore.count, 1,
                       "restored clip must reappear in search; got \(hitsAfterRestore)")
        XCTAssertEqual(hitsAfterRestore.first?.id, id,
                       "restored search result id mismatch")
    }

    // MARK: - testSweepHardDeletesAfter90d

    @MainActor
    func testSweepHardDeletesAfter90d() async throws {
        let (store, dbWriter) = try makeStore()
        let id = try await insertSampleClip(
            store,
            preview: "expired tombstone",
            content: "expired tombstone body",
            hash: "h-lifecycle-expired-1"
        )

        // Soft-delete and then back-date the tombstone past the 90-day window.
        try await store.delete(clipId: id)
        let oldEnough = Date().timeIntervalSince1970 - (91 * 86400)
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE clips SET deleted_at = ? WHERE id = ?",
                arguments: [oldEnough, id]
            )
        }

        let (hardDeleted, kept) = try await RetentionSweeper.sweep(store: store)
        XCTAssertEqual(hardDeleted, 1,
                       "sweeper must hard-delete the expired tombstone")
        XCTAssertEqual(kept, 0,
                       "no tombstones should remain after sweep of single expired row")

        let surviving: Int = try await dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips WHERE id = ?", arguments: [id]) ?? -1
        }
        XCTAssertEqual(surviving, 0,
                       "expired tombstone row must be gone after sweep")
    }

    // MARK: - testSweepKeepsRecentSoftDeletes

    @MainActor
    func testSweepKeepsRecentSoftDeletes() async throws {
        let (store, dbWriter) = try makeStore()
        let id = try await insertSampleClip(
            store,
            preview: "recent tombstone",
            content: "recent tombstone body",
            hash: "h-lifecycle-recent-1"
        )

        // Soft-delete with a `deleted_at` of "now" — well inside the 90-day
        // grace window. ClipStore.delete already stamps deleted_at to now;
        // we re-stamp it explicitly to make the intent obvious.
        try await store.delete(clipId: id)
        let now = Date().timeIntervalSince1970
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE clips SET deleted_at = ? WHERE id = ?",
                arguments: [now, id]
            )
        }

        let (hardDeleted, kept) = try await RetentionSweeper.sweep(store: store)
        XCTAssertEqual(hardDeleted, 0,
                       "sweeper must not touch tombstones inside the grace window")
        XCTAssertEqual(kept, 1,
                       "recently soft-deleted row should still be reported as kept")

        let tombstones: Int = try await dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clips WHERE deleted_at IS NOT NULL"
            ) ?? -1
        }
        XCTAssertEqual(tombstones, 1,
                       "recent tombstone must survive the sweep")
    }
}
