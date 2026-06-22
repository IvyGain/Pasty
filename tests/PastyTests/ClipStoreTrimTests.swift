import XCTest
import GRDB
@testable import Pasty

/// v0.9.8-beta Wave 1A: regression coverage for `ClipStore.trimToMaxClips`,
/// the new auto-trim entry point that replaces the dismissed "結果が1000件を
/// 超えています" toast. Tests verify:
///   1. excess clips beyond `maxCount` are soft-deleted oldest-first
///   2. pinned clips are excluded from both the count and the delete set
///   3. `maxCount == 0` is a no-op (the "無制限" preset)
///
/// Mirrors the fixture style of `ClipStoreSoftDeleteTests`: per-test unique
/// tempdir + direct `ClipStore(dbWriter:blobDirectory:)` so we don't pollute
/// the user's Application Support DB.
final class ClipStoreTrimTests: XCTestCase {

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

    /// Insert `count` clips with strictly increasing `createdAt` so we can
    /// reason about "oldest first" deterministically. Returns the inserted
    /// row ids in chronological order (oldest → newest).
    @MainActor
    private func insertChronologicalClips(
        into dbWriter: DatabaseQueue,
        count: Int,
        baseDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> [Int64] {
        try dbWriter.write { db in
            var ids: [Int64] = []
            for i in 0..<count {
                let createdAt = baseDate.addingTimeInterval(Double(i))
                try db.execute(sql: """
                    INSERT INTO clips (createdAt, kind, preview, content, dataPath,
                        byteSize, sourceBundleId, sourceAppName, contentHash)
                    VALUES (?, 'text', ?, ?, NULL, ?, NULL, NULL, ?)
                    """, arguments: [
                        createdAt,
                        "clip-\(i)",
                        "body-\(i)",
                        Int64(7),
                        "h-trim-\(i)-\(UUID().uuidString)"
                    ])
                ids.append(db.lastInsertedRowID)
            }
            return ids
        }
    }

    /// Pin a clip to the first seeded pinboard (default board #1). Returns
    /// the pinboard_items row id. The default migration v2.seedPinboards
    /// guarantees pinboards exist with id starting at 1.
    @MainActor
    private func pinClip(_ clipId: Int64, into dbWriter: DatabaseQueue) throws {
        try dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pinboard_items (pinboardId, clipId, sortOrder)
                VALUES (1, ?, 0)
                """, arguments: [clipId])
        }
    }

    /// Returns the set of `id`s currently live (`deleted_at IS NULL`).
    @MainActor
    private func liveClipIds(in dbWriter: DatabaseQueue) throws -> Set<Int64> {
        try dbWriter.read { db in
            let rows = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM clips WHERE deleted_at IS NULL ORDER BY id ASC"
            )
            return Set(rows)
        }
    }

    // MARK: - Tests

    /// 5 clips with strictly increasing `createdAt` → trim to 3 → the 2
    /// oldest must be soft-deleted, the 3 newest survive.
    @MainActor
    func testTrimDeletesOldestFirst() async throws {
        let (store, dbWriter) = try makeStore()
        let ids = try insertChronologicalClips(into: dbWriter, count: 5)
        XCTAssertEqual(ids.count, 5)

        let trimmed = try store.trimToMaxClips(3)
        XCTAssertEqual(trimmed, 2,
                       "expected 2 soft-deletes (5 live, cap 3) but got \(trimmed)")

        let live = try liveClipIds(in: dbWriter)
        XCTAssertEqual(live, Set(ids.suffix(3)),
                       "the 3 newest clips (by createdAt) must survive; got \(live)")
        for oldId in ids.prefix(2) {
            XCTAssertFalse(live.contains(oldId),
                           "oldest clip id=\(oldId) should have been soft-deleted")
        }
    }

    /// 5 clips, the 2 oldest are pinned → trim to 2. Pinned clips are
    /// excluded from BOTH the count and the delete set, so the effective
    /// "live unpinned" count is 3 (clips at index 2, 3, 4). Capping
    /// unpinned to 2 sheds the oldest unpinned (index 2), leaving 4 live
    /// total (2 pinned + 2 newest unpinned).
    @MainActor
    func testTrimPreservesPinnedClips() async throws {
        let (store, dbWriter) = try makeStore()
        let ids = try insertChronologicalClips(into: dbWriter, count: 5)
        // Pin the 2 OLDEST so we can verify the pin protects them even
        // though by createdAt they'd be the first targets.
        try pinClip(ids[0], into: dbWriter)
        try pinClip(ids[1], into: dbWriter)

        let trimmed = try store.trimToMaxClips(2)
        XCTAssertEqual(trimmed, 1,
                       "expected 1 soft-delete (3 unpinned, cap 2) but got \(trimmed)")

        let live = try liveClipIds(in: dbWriter)
        // Pinned ones must survive.
        XCTAssertTrue(live.contains(ids[0]),
                      "pinned oldest clip id=\(ids[0]) was incorrectly trimmed")
        XCTAssertTrue(live.contains(ids[1]),
                      "pinned 2nd-oldest clip id=\(ids[1]) was incorrectly trimmed")
        // The 2 newest unpinned survive.
        XCTAssertTrue(live.contains(ids[3]),
                      "unpinned newest-1 clip id=\(ids[3]) was incorrectly trimmed")
        XCTAssertTrue(live.contains(ids[4]),
                      "unpinned newest clip id=\(ids[4]) was incorrectly trimmed")
        // The single oldest UNPINNED gets shed.
        XCTAssertFalse(live.contains(ids[2]),
                       "oldest unpinned clip id=\(ids[2]) should have been trimmed")
        XCTAssertEqual(live.count, 4,
                       "expected 4 live clips (2 pinned + 2 newest unpinned), got \(live.count)")
    }

    /// `maxCount == 0` is the "無制限" preset: no trim must occur, even
    /// when there are 10+ live clips. Returns 0 (no rows affected).
    @MainActor
    func testTrimZeroIsNoOp() async throws {
        let (store, dbWriter) = try makeStore()
        let ids = try insertChronologicalClips(into: dbWriter, count: 10)
        XCTAssertEqual(ids.count, 10)

        let trimmed = try store.trimToMaxClips(0)
        XCTAssertEqual(trimmed, 0,
                       "maxCount==0 must be a no-op, but trimmed \(trimmed) rows")

        let live = try liveClipIds(in: dbWriter)
        XCTAssertEqual(live, Set(ids),
                       "no clips should have been soft-deleted; live=\(live)")
    }
}
