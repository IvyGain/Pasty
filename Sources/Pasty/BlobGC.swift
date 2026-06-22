import Foundation
import GRDB
import os

/// v0.9.6-beta (P0 #3): startup garbage-collection sweep for on-disk blobs.
///
/// Soft-delete (`ClipStore.delete(clipId:)`) leaves the row in `clips` with
/// `deleted_at` set so iCloud sync (C1 phase 2) can ship a tombstone, but the
/// blob on disk (image / file payload under `~/Library/Application Support/
/// Pasty/blobs/`) needs to be reclaimed eventually. We keep blobs for 30 days
/// after a soft delete so the user has a window to "undo" via re-paste, then
/// physically delete both the row (`hardDelete`) and the file.
///
/// Strategy:
/// 1. On the MainActor, snapshot every `(id, dataPath, deleted_at)` row from
///    `clips` — cheap because we only read three small columns.
/// 2. Hop to a detached Task for the disk walk (enumerating ~/Pasty/blobs/),
///    using only plain Swift values across the boundary so we don't smuggle
///    the MainActor-isolated store.
/// 3. KEEP any blob whose relative path matches a live row (deleted_at IS NULL)
///    or a recently-deleted row (within the 30-day grace window).
/// 4. DELETE any other blob from disk.
/// 5. Hop back to the MainActor and `hardDelete` rows whose `deleted_at` is
///    older than 30 days. This also wipes the matching `clips_fts` row via
///    the `clips_ad` trigger that T1's v8 migration installed.
@MainActor
enum BlobGC {
    /// 30-day grace window for soft-deleted rows (in seconds).
    private static let graceWindowSeconds: TimeInterval = 30 * 86400

    private static let logger = Logger(subsystem: "io.pasty.app", category: "BlobGC")

    /// Run one sweep pass and return how many on-disk blobs were deleted vs
    /// kept. Returned tally only covers the blob filesystem; row purges
    /// happen in step 5 and are reported separately via the logger.
    static func sweep(store: ClipStore) async throws -> (deleted: Int, kept: Int) {
        // Snapshot the blob directory from the store so we exactly match the
        // path ClipStore + ClipBlobs are using (avoids drift between
        // bundle-id and "Pasty" sub-directory naming).
        let blobDir = store.blobDirectory
        let fm = FileManager.default
        guard fm.fileExists(atPath: blobDir.path) else {
            logger.info("blob dir does not exist; nothing to sweep")
            return (0, 0)
        }

        // Step 1: collect rows with their dataPath + deleted_at on the
        // MainActor (ClipStore is MainActor-isolated). We only need three
        // primitive columns.
        let rows = try await fetchClipRows(store: store)

        let nowSec = Date().timeIntervalSince1970
        let graceCutoff = nowSec - graceWindowSeconds

        // Build the live-set: any clip with non-nil dataPath whose row is
        // either live (deleted_at IS NULL) or still within the grace window.
        // Use a Set<String> of relative paths for O(1) lookup during the
        // disk walk.
        var liveRelativePaths: Set<String> = []
        var idsToHardDelete: [Int64] = []
        for row in rows {
            let isExpired: Bool = {
                guard let deletedAt = row.deletedAt else { return false }
                return deletedAt < graceCutoff
            }()
            if isExpired {
                idsToHardDelete.append(row.id)
            } else if let path = row.dataPath, !path.isEmpty {
                liveRelativePaths.insert(path)
            }
        }

        // Step 2: disk walk on a detached Task so the MainActor isn't
        // blocked while we stat hundreds of files. Only plain Swift values
        // cross the boundary.
        let blobDirPath = blobDir.path
        let liveSnapshot = liveRelativePaths
        let walkResult: (deleted: Int, kept: Int) = await Task.detached(priority: .utility) {
            sweepDisk(blobDirPath: blobDirPath, liveRelativePaths: liveSnapshot)
        }.value

        // Step 5: hard-delete expired rows on the MainActor. This also
        // unlinks the matching FTS row via the clips_ad trigger.
        var hardDeletedRows = 0
        for id in idsToHardDelete {
            do {
                _ = try await store.hardDelete(id)
                hardDeletedRows += 1
            } catch {
                logger.error("hardDelete failed for id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if hardDeletedRows > 0 {
            logger.info("hard-deleted \(hardDeletedRows, privacy: .public) expired tombstone rows")
        }

        return walkResult
    }

    // MARK: - Helpers

    /// Plain-value snapshot of a clip row used by BlobGC. Crossing the
    /// MainActor → detached-Task boundary requires Sendable, and three
    /// scalars are trivially Sendable.
    private struct ClipRow: Sendable {
        let id: Int64
        let dataPath: String?
        let deletedAt: TimeInterval?
    }

    /// Read `(id, dataPath, deleted_at)` for every row in `clips`. We don't
    /// have an existing ClipStore API that exposes soft-deleted rows + their
    /// deleted_at timestamp together, so we drop down to a raw read on the
    /// store's `dbWriter`. ClipStore.dbWriter is a public `let`, so this is
    /// a sanctioned read path (no new ClipStore surface required).
    private static func fetchClipRows(store: ClipStore) async throws -> [ClipRow] {
        try await store.dbWriter.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql: "SELECT id, dataPath, deleted_at FROM clips"
            )
            var out: [ClipRow] = []
            while let row = try cursor.next() {
                let id: Int64 = row["id"]
                let dataPath: String? = row["dataPath"]
                let deletedAt: Double? = row["deleted_at"]
                out.append(ClipRow(
                    id: id,
                    dataPath: dataPath,
                    deletedAt: deletedAt
                ))
            }
            return out
        }
    }

    /// Enumerate every regular file under `blobDirPath`, KEEP the ones whose
    /// path relative to the blob dir is in `liveRelativePaths`, DELETE the
    /// rest. Errors per file are logged and counted as kept (= we couldn't
    /// confirm deletion, so we err on the side of preserving user data).
    nonisolated private static func sweepDisk(
        blobDirPath: String,
        liveRelativePaths: Set<String>
    ) -> (deleted: Int, kept: Int) {
        let fm = FileManager.default
        let blobDirURL = URL(fileURLWithPath: blobDirPath)
        var deleted = 0
        var kept = 0

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: blobDirURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                logger.error("enumerator error at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return true
            }
        ) else {
            logger.error("could not build enumerator for \(blobDirPath, privacy: .public)")
            return (0, 0)
        }

        let blobDirAbsolute = blobDirURL.standardizedFileURL.path
        let prefix = blobDirAbsolute.hasSuffix("/") ? blobDirAbsolute : blobDirAbsolute + "/"

        while let next = enumerator.nextObject() {
            guard let fileURL = next as? URL else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            guard values?.isRegularFile == true else { continue }

            let absolute = fileURL.standardizedFileURL.path
            let relative: String
            if absolute.hasPrefix(prefix) {
                relative = String(absolute.dropFirst(prefix.count))
            } else {
                // Outside the expected root — skip and count as kept so we
                // never delete files that aren't ours.
                kept += 1
                continue
            }

            if liveRelativePaths.contains(relative) {
                kept += 1
                continue
            }

            do {
                try fm.removeItem(at: fileURL)
                deleted += 1
            } catch {
                logger.error("failed to delete blob \(absolute, privacy: .public): \(String(describing: error), privacy: .public)")
                kept += 1
            }
        }

        return (deleted, kept)
    }
}
