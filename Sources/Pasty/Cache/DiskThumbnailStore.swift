import Foundation
import CryptoKit
import os

/// v0.10.0-beta — pragmatic disk-LRU sidecar for thumbnail caches.
///
/// Design notes:
/// - Filesystem is used as the LRU manifest: `mtime` is touched on every
///   `load(...)` hit, so eviction can sort by oldest-first without an
///   external index. No SQLite, no plist — keeps the moving parts down
///   for a beta and avoids cross-actor schema races.
/// - One actor instance per bucket. Disk I/O is serialized inside the
///   actor; callers (`@MainActor` thumbnail caches) `await` into it.
/// - The API trades in `Data` rather than `NSImage` so nothing
///   non-`Sendable` crosses the actor boundary. The MainActor caller
///   converts on its side (via `NSImage(data:)` / `tiffRepresentation`).
/// - `evictExpiredAndOversize()` is invoked once, deferred ~5s after
///   launch, from `PastyApp` startup — heavy directory walks must NOT
///   run on the hot path.
actor DiskThumbnailStore {
    private let bucketDir: URL
    private let maxBytes: Int
    private let maxAge: TimeInterval

    init(bucket: String, maxBytes: Int, maxAge: TimeInterval) {
        let cachesDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
        self.bucketDir = cachesDir
            .appendingPathComponent("io.pasty.app/\(bucket)", isDirectory: true)
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        try? FileManager.default.createDirectory(
            at: bucketDir, withIntermediateDirectories: true)
    }

    /// Returns raw TIFF data on hit and touches mtime as an LRU signal.
    /// Returns `nil` on miss / read error.
    func load(key: String) -> Data? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        // Touch mtime to record access (LRU signal).
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// Atomically writes the thumbnail TIFF payload to disk. Failures
    /// are swallowed — the disk store is best-effort and a write loss
    /// only costs one regeneration on next access.
    func store(key: String, data: Data) {
        let url = fileURL(for: key)
        try? data.write(to: url, options: .atomic)
    }

    /// Called once during deferred startup sweep. Drops entries older
    /// than `maxAge`, then, if the bucket is still over `maxBytes`,
    /// evicts oldest-first until usage falls to ≤ 90 % of the cap.
    func evictExpiredAndOversize() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: bucketDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return }

        let now = Date()
        var keepers: [(url: URL, mtime: Date, size: Int)] = []
        // v0.10.0-beta perf instrumentation: count files removed across both
        // eviction phases so we can verify the disk-LRU actually fires.
        var deletedCount = 0

        // 1) Age eviction
        for url in entries {
            let attrs = try? url.resourceValues(forKeys: Set(keys))
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            let size = attrs?.fileSize ?? 0
            if now.timeIntervalSince(mtime) > maxAge {
                try? FileManager.default.removeItem(at: url)
                deletedCount += 1
            } else {
                keepers.append((url, mtime, size))
            }
        }

        // 2) Size cap eviction (oldest first; drain to 90 % headroom)
        var totalBytes = keepers.reduce(0) { $0 + $1.size }
        if totalBytes > maxBytes {
            keepers.sort { $0.mtime < $1.mtime } // oldest first
            let targetBytes = Int(Double(maxBytes) * 0.9)
            for entry in keepers {
                if totalBytes <= targetBytes { break }
                try? FileManager.default.removeItem(at: entry.url)
                totalBytes -= entry.size
                deletedCount += 1
            }
        }

        Logger(subsystem: "io.pasty.app", category: "DiskThumbnailStore")
            .info("evict: bucket=\(self.bucketDir.lastPathComponent, privacy: .public) deleted=\(deletedCount, privacy: .public) finalBytes=\(totalBytes, privacy: .public)")
    }

    /// Maps an arbitrary string key (typically a file path) to a stable
    /// `<hex>.tiff` filename. MD5 is chosen for filename derivation only
    /// — this is not a security context.
    private func fileURL(for key: String) -> URL {
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02hhx", $0) }.joined()
        return bucketDir.appendingPathComponent("\(hex).tiff")
    }
}
