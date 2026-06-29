import Foundation
import GRDB

/// Thread-safe LRU cache (64 entries) for compiled `FTS5Pattern` values.
///
/// Compiling an `FTS5Pattern` involves tokenizing the input string and
/// allocating GRDB-internal state. For the strip-panel search box the
/// same prefix gets typed and re-typed many times per second; caching
/// the compiled pattern shaves a measurable amount of work off the
/// hot reload path (see Wave 1 Axis 6 audit, v0.10.0-beta).
///
/// The cache is keyed by the raw query string. Eviction follows LRU
/// semantics: when the cache reaches `maxCapacity`, the least-recently
/// *accessed* entry is dropped. Cache hits move the entry to the most
/// recent slot so frequently-used queries stay warm.
///
/// `nonisolated(unsafe)` storage is guarded by an `os_unfair_lock`,
/// which is sufficient because the critical sections are
/// non-reentrant, allocation-free hash lookups.
enum FTS5PatternCache {
    private static let maxCapacity = 64
    nonisolated(unsafe) private static var cache: [String: FTS5Pattern] = [:]
    nonisolated(unsafe) private static var insertionOrder: [String] = []
    nonisolated(unsafe) private static var lock = os_unfair_lock()

    // v0.10.0-beta perf instrumentation: hit/miss counters guarded by the
    // existing `lock`. Reads via `stats` re-take the lock for consistency.
    nonisolated(unsafe) private static var hits: Int = 0
    nonisolated(unsafe) private static var misses: Int = 0

    /// Returns a cached or freshly-compiled `FTS5Pattern` for `query`.
    /// Falls back from `matchingAllPrefixesIn` to `matchingAnyTokenIn`
    /// to mirror the original call sites in SearchEngine/ClipStore.
    static func pattern(for query: String) -> FTS5Pattern? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if let cached = cache[query] {
            // Move to end (most recent)
            if let idx = insertionOrder.firstIndex(of: query) {
                insertionOrder.remove(at: idx)
                insertionOrder.append(query)
            }
            hits += 1
            return cached
        }

        let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
                   ?? FTS5Pattern(matchingAnyTokenIn: query)
        guard let pattern else { return nil }
        misses += 1

        if cache.count >= maxCapacity, let evictKey = insertionOrder.first {
            cache.removeValue(forKey: evictKey)
            insertionOrder.removeFirst()
        }
        cache[query] = pattern
        insertionOrder.append(query)
        return pattern
    }

    /// v0.10.0-beta perf: snapshot of hit/miss counters since process
    /// start (or last `invalidateAll`). Cheap to read — guarded by the
    /// same `os_unfair_lock` as the cache itself.
    static var stats: (hits: Int, misses: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (hits, misses)
    }

    /// Drops every cached pattern. Intended for tests and for memory
    /// pressure responders; production code should not call this on
    /// the hot path.
    static func invalidateAll() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        cache.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
    }
}
