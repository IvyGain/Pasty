import AppKit
import AVFoundation

/// 動画ファイル (mov / mp4 / etc.) の先頭 0.5 秒のフレームをサムネとして
/// 取得し、LRU キャッシュに保持する。`FileImageThumbnailCache` と同じ
/// I/F に揃えてある。
@MainActor
final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()
    /// v0.10.0-beta: disk sidecar for cold-start hits. mtime-based LRU,
    /// 40 MiB cap, 90 day TTL. Sweep is invoked once on deferred startup
    /// from `PastyApp`. NOT used for in-flight dedup — that stays in
    /// memory via `inFlight`.
    static let diskStore = DiskThumbnailStore(
        bucket: "video-thumbs",
        maxBytes: 40 * 1024 * 1024,
        maxAge: 90 * 86400)
    private var cache: [String: NSImage] = [:]
    private var lru: [String] = []
    private let maxItems = 128
    /// 進行中の生成 URL。@MainActor 隔離で全 mutate が直列化されるため、追加ロック不要。
    /// Swift 6 strict concurrency 移行で NSLock を撤去 (v0.10.0-beta)。
    private var inFlight: Set<String> = []

    /// 同期で取得を試みる (cache hit 時のみ即座に NSImage、miss は非同期生成して
    /// nil を返す。生成完了後は NotificationCenter で `pastyVideoThumbReady`
    /// を post するので UI 側がそれを購読すれば再描画される)。
    func image(for clip: ClipItem) -> NSImage? {
        guard let url = videoURL(for: clip) else { return nil }
        let key = url.path
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        // @MainActor 隔離で check+insert は自動的に原子的。
        if inFlight.contains(key) { return nil }
        inFlight.insert(key)
        Task.detached { [weak self] in
            // v0.10.0-beta: try disk LRU before re-rendering the AVAsset.
            // On hit, hop back to MainActor to repopulate memory cache.
            if let data = await Self.diskStore.load(key: key),
               let image = NSImage(data: data) {
                await self?.completeThumbnailGeneration(key: key, image: image, persistToDisk: false)
                return
            }
            let img = Self.generateThumbnail(at: url)
            await self?.completeThumbnailGeneration(key: key, image: img, persistToDisk: true)
        }
        return nil
    }

    /// `Task.detached` から呼び戻される MainActor-isolated コールバック。
    /// `MainActor.run { [weak self] ... }` を使うと strict concurrency で
    /// "reference to captured var 'self'" 警告が出るため、メソッド経由で受ける。
    ///
    /// `persistToDisk` is `false` when the image was just loaded *from*
    /// disk (no need to round-trip), and `true` for freshly-rendered
    /// thumbnails. Disk write fires off-MainActor via the actor.
    private func completeThumbnailGeneration(key: String, image: NSImage?, persistToDisk: Bool) {
        inFlight.remove(key)
        if let image {
            store(key: key, image: image)
            NotificationCenter.default.post(
                name: .pastyVideoThumbReady,
                object: nil,
                userInfo: ["path": key]
            )
            if persistToDisk, let tiff = image.tiffRepresentation {
                Task.detached(priority: .utility) {
                    await Self.diskStore.store(key: key, data: tiff)
                }
            }
        }
    }

    nonisolated private static func generateThumbnail(at url: URL) -> NSImage? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 320)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? gen.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func videoURL(for clip: ClipItem) -> URL? {
        let raw = (clip.content ?? clip.preview).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("file://"), let u = URL(string: raw) { return u }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        if raw.hasPrefix("~") { return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath) }
        return nil
    }

    private func store(key: String, image: NSImage) {
        if cache.count >= maxItems, let oldest = lru.first {
            cache.removeValue(forKey: oldest)
            lru.removeFirst()
        }
        cache[key] = image
        lru.append(key)
    }

    private func touch(_ key: String) {
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
            lru.append(key)
        }
    }
}

extension Notification.Name {
    static let pastyVideoThumbReady = Notification.Name("pasty.videoThumb.ready")
}
