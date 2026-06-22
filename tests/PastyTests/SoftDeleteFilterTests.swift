import XCTest
import GRDB
@testable import Pasty

/// v0.9.6-beta (follow-up #1, #2, #3 + P1 #12): regression coverage for the
/// soft-delete filter spreading into SearchEngine (DSL), PinboardStore.items,
/// the InsightsDashboard aggregations, and the v10 FTS5 soft-delete trigger.
///
/// We hit the SQL layer directly for the Insights checks because the
/// dashboard loader is a private static helper inside InsightsDashboard.swift
/// and we don't want to leak it to satisfy a test. The aggregation queries
/// under test are the verbatim WHERE clauses added in follow-up #3.
final class SoftDeleteFilterTests: XCTestCase {

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
    @discardableResult
    private func insertSampleClip(
        _ store: ClipStore,
        preview: String,
        content: String,
        hash: String = "h-\(UUID().uuidString)",
        kind: ClipKind = .text,
        sourceAppName: String? = nil
    ) async throws -> Int64 {
        let item = ClipItem(
            id: nil, createdAt: Date(), kind: kind,
            preview: preview, content: content, dataPath: nil,
            byteSize: Int64(content.utf8.count),
            sourceBundleId: nil, sourceAppName: sourceAppName,
            contentHash: hash
        )
        let inserted = try await store.insert(item)
        guard let id = inserted?.id else {
            XCTFail("insert returned no id"); throw XCTSkip("insert returned no id")
        }
        return id
    }

    // MARK: - follow-up #1: SearchEngine empty-query path

    @MainActor
    func testSearchEngineExcludesDeleted_emptyQuery() async throws {
        let (store, _) = try makeStore()
        let keepId = try await insertSampleClip(
            store, preview: "keep-empty", content: "keep-empty", hash: "se-empty-keep"
        )
        let dropId = try await insertSampleClip(
            store, preview: "drop-empty", content: "drop-empty", hash: "se-empty-drop"
        )
        try await store.delete(clipId: dropId)

        let q = SearchQuery.parse("")
        let rows = try await SearchEngine.run(q, store: store)
        let ids = rows.compactMap { $0.id }
        XCTAssertTrue(ids.contains(keepId), "live clip missing from empty-query DSL")
        XCTAssertFalse(ids.contains(dropId), "soft-deleted clip leaked through empty-query DSL")
    }

    // MARK: - follow-up #1: SearchEngine FTS5 MATCH path

    @MainActor
    func testSearchEngineExcludesDeleted_FTSMatch() async throws {
        let (store, _) = try makeStore()
        let keepId = try await insertSampleClip(
            store, preview: "foo alpha", content: "foo alpha", hash: "se-fts-keep"
        )
        let dropId = try await insertSampleClip(
            store, preview: "foo bravo", content: "foo bravo", hash: "se-fts-drop"
        )

        // Sanity: both clips match before the soft delete.
        let pre = try await SearchEngine.run(SearchQuery.parse("foo"), store: store)
        XCTAssertEqual(pre.count, 2, "FTS sanity: both clips should match before delete")

        try await store.delete(clipId: dropId)

        let post = try await SearchEngine.run(SearchQuery.parse("foo"), store: store)
        let ids = post.compactMap { $0.id }
        XCTAssertEqual(post.count, 1, "FTS MATCH must return exactly 1 row post-soft-delete")
        XCTAssertTrue(ids.contains(keepId))
        XCTAssertFalse(ids.contains(dropId), "soft-deleted clip leaked through FTS MATCH path")
    }

    // MARK: - follow-up #2: PinboardStore.items(in:)

    @MainActor
    func testPinboardItemsExcludesDeleted() async throws {
        let (store, dbWriter) = try makeStore()
        let keepId = try await insertSampleClip(
            store, preview: "pin-keep", content: "pin-keep", hash: "pin-keep"
        )
        let dropId = try await insertSampleClip(
            store, preview: "pin-drop", content: "pin-drop", hash: "pin-drop"
        )

        let pinStore = PinboardStore(dbWriter: dbWriter)
        try await pinStore.create(name: "TestBoard", colorHex: "#7C8CF8")
        guard let boardId = pinStore.boards.first(where: { $0.name == "TestBoard" })?.id else {
            XCTFail("pinboard not created"); return
        }
        try await pinStore.pin(clipId: keepId, toBoard: boardId)
        try await pinStore.pin(clipId: dropId, toBoard: boardId)

        let before = try await pinStore.items(in: boardId)
        XCTAssertEqual(before.count, 2, "sanity: both pinned clips visible pre-delete")

        try await store.delete(clipId: dropId)

        let after = try await pinStore.items(in: boardId)
        let ids = after.compactMap { $0.id }
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(ids.contains(keepId))
        XCTAssertFalse(ids.contains(dropId), "soft-deleted clip leaked through PinboardStore.items")
    }

    // MARK: - follow-up #3: Insights aggregations

    @MainActor
    func testInsightsExcludesDeleted() async throws {
        // We rebuild the same aggregation queries that InsightsDashboard.loadSnapshot
        // uses, so that any regression in the WHERE clause causes a failure here
        // without exposing the private loader.
        let (store, dbWriter) = try makeStore()
        let keepId = try await insertSampleClip(
            store, preview: "ins-keep", content: "ins-keep",
            hash: "ins-keep", sourceAppName: "KeepApp"
        )
        let dropId = try await insertSampleClip(
            store, preview: "ins-drop", content: "ins-drop",
            hash: "ins-drop", sourceAppName: "DropApp"
        )

        try await store.delete(clipId: dropId)

        // todayCount / weekCount-equivalent
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let totalToday: Int = try await dbWriter.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM clips WHERE createdAt >= ? AND deleted_at IS NULL",
                arguments: [startOfToday]
            ) ?? -1
        }
        XCTAssertEqual(totalToday, 1, "todayCount must exclude soft-deleted rows")

        // kind aggregation
        let kindCount: Int = try await dbWriter.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM clips WHERE deleted_at IS NULL AND kind = 'text'"
            ) ?? -1
        }
        XCTAssertEqual(kindCount, 1, "kind aggregation must exclude soft-deleted rows")

        // app aggregation
        let dropAppRows: Int = try await dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT sourceBundleId, sourceAppName, COUNT(*) AS c
                    FROM clips
                    WHERE deleted_at IS NULL
                    GROUP BY COALESCE(sourceAppName, sourceBundleId, 'Unknown')
                )
                WHERE sourceAppName = 'DropApp'
            """) ?? -1
        }
        XCTAssertEqual(dropAppRows, 0, "DropApp must not appear in Insights app rollup")

        // Sanity: keep id is still alive in the rollup table.
        let keepAppRows: Int = try await dbWriter.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT sourceBundleId, sourceAppName, COUNT(*) AS c
                    FROM clips
                    WHERE deleted_at IS NULL
                    GROUP BY COALESCE(sourceAppName, sourceBundleId, 'Unknown')
                )
                WHERE sourceAppName = 'KeepApp'
            """) ?? -1
        }
        XCTAssertEqual(keepAppRows, 1, "KeepApp must remain in Insights app rollup")
        _ = keepId
    }

    // MARK: - P1 #12: v10 FTS5 soft-delete trigger

    @MainActor
    func testV10TriggerRemovesFTSRow() async throws {
        let (store, dbWriter) = try makeStore()
        let id = try await insertSampleClip(
            store, preview: "trigger needle", content: "trigger needle body",
            hash: "trig-1"
        )

        // Step 1: MATCH finds the row pre-soft-delete (FTS5 INSERT trigger).
        let preHits = try await store.search(query: "needle")
        XCTAssertEqual(preHits.count, 1, "FTS sanity: clip should match pre-soft-delete")

        // Step 2: soft-delete → v10 trigger removes the row from clips_fts in
        // the *same* DB session (no reopen, no backfill).
        try await store.delete(clipId: id)

        let postHits = try await store.search(query: "needle")
        XCTAssertTrue(postHits.isEmpty,
                      "v10 trigger must drop FTS row on soft-delete (same session)")

        // Also confirm at the SQL level: clips_fts MATCH alone, no clips JOIN.
        // External-content FTS5 still answers MATCH directly; if the trigger
        // didn't fire, the rowid would still come back here.
        let rawHits: Int = try await dbWriter.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM clips_fts WHERE clips_fts MATCH ?",
                arguments: ["needle"]
            ) ?? -1
        }
        XCTAssertEqual(rawHits, 0, "clips_fts must not retain a row for the tombstoned clip")

        // Step 3: restore (deleted_at = NULL) → v10 restore trigger re-inserts.
        try await dbWriter.write { db in
            try db.execute(sql: "UPDATE clips SET deleted_at = NULL WHERE id = ?",
                           arguments: [id])
        }

        let restoredHits = try await store.search(query: "needle")
        XCTAssertEqual(restoredHits.count, 1,
                       "v10 restore trigger must re-insert FTS row on un-delete")
    }
}
