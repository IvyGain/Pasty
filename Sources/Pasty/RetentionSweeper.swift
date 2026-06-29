import Foundation
import GRDB
import os

/// v0.10.0-beta (Axis 5): periodic hard-delete sweeper for tombstoned clips.
///
/// `ClipStore.delete(clipId:)` only marks rows with `deleted_at` — required
/// so iCloud sync (C1 phase 2) can ship a tombstone — but those rows would
/// accumulate forever without a GC. This sweeper drops rows whose
/// `deleted_at` aged past the 90-day grace window.
///
/// Cooperates with:
///   • `BlobGC` (30-day window): physically reclaims orphan blobs and
///     hard-deletes their rows ahead of us.
///   • `clips_softdelete_au` trigger (v10 migration): keeps `clips_fts`
///     consistent on the soft-delete UPDATE itself; the `clips_ad` trigger
///     (v8) then evicts the FTS row when we DELETE from `clips` here.
///
/// Strategy:
///   1. Single write transaction issues `DELETE FROM clips WHERE
///      deleted_at IS NOT NULL AND deleted_at < cutoff`.
///   2. Post-delete COUNT(*) reports how many tombstones survived the
///      grace window cut.
///   3. After the row sweep, invoke `BlobGC.sweep(store:)` so any blob
///      bound to a row we just deleted gets unlinked on disk too. (BlobGC
///      walks the blob dir against live + recent rows, so calling it here
///      is safe and idempotent.)
@MainActor
enum RetentionSweeper {
    /// 90-day grace window for soft-deleted rows (in seconds).
    /// Wider than BlobGC's 30 days on purpose: BlobGC reclaims disk space
    /// first; the row sweep is a defense-in-depth pass for sync metadata
    /// retention.
    static let graceWindowSeconds: TimeInterval = 90 * 86400

    private static let logger = Logger(subsystem: "io.pasty.app", category: "RetentionSweeper")

    /// Production entry point — opens `ClipStore.shared()` and runs the sweep.
    static func sweep() async throws -> (hardDeleted: Int, keptRows: Int) {
        let store = try ClipStore.shared()
        return try await sweep(store: store)
    }

    /// Testable entry point — sweeps against an injected store so tests can
    /// drive a per-temp-dir DB. Production callers in PastyApp use this
    /// overload directly to avoid spinning up a second ClipStore.
    @discardableResult
    static func sweep(store: ClipStore) async throws -> (hardDeleted: Int, keptRows: Int) {
        logger.info("RetentionSweeper sweep starting (graceWindowSeconds=\(Int(graceWindowSeconds), privacy: .public))")

        let cutoff = Date().timeIntervalSince1970 - graceWindowSeconds

        let (hardDeleted, keptRows): (Int, Int) = try await store.dbWriter.write { db in
            // FTS5 sync caveat: the v10 `clips_softdelete_au` trigger already
            // evicted the soft-deleted rows from `clips_fts` at soft-delete
            // time. The v8 `clips_ad` trigger fires again on DELETE and tries
            // to evict the same rowids from an external-content FTS5 index
            // that no longer has them — which leaves the FTS5 index in a
            // "database disk image is malformed" state. We can't change the
            // trigger (per Axis 5 constraint), so we re-insert the expiring
            // rows into `clips_fts` before the DELETE: the clips_ad trigger
            // then finds them and removes them cleanly. The re-inserted rows
            // are never visible to search (search filters on
            // `clips.deleted_at IS NULL`, and the DELETE runs in the same
            // transaction).
            try db.execute(sql: """
                INSERT INTO clips_fts(rowid, preview, content, sourceAppName, extractedOCRText)
                SELECT id, preview, content, sourceAppName, extractedOCRText
                FROM clips
                WHERE deleted_at IS NOT NULL AND deleted_at < ?
                """, arguments: [cutoff])

            try db.execute(
                sql: "DELETE FROM clips WHERE deleted_at IS NOT NULL AND deleted_at < ?",
                arguments: [cutoff]
            )
            let deleted = db.changesCount
            let kept = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clips WHERE deleted_at IS NOT NULL"
            ) ?? 0
            return (deleted, kept)
        }

        logger.info("RetentionSweeper hardDeleted=\(hardDeleted, privacy: .public) kept=\(keptRows, privacy: .public)")

        // NOTE: Blob reclamation is the responsibility of `BlobGC.sweep`,
        // which PastyApp.swift invokes ahead of us at startup. We do not
        // chain BlobGC here because BlobGC issues additional writes against
        // the same DatabaseWriter and is best run as an independent step.
        return (hardDeleted, keptRows)
    }
}
