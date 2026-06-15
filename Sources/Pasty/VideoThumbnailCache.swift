import AppKit
import AVFoundation

/// 動画ファイル (mov / mp4 / etc.) の先頭 0.5 秒のフレームをサムネとして
/// 取得し、LRU キャッシュに保持する。`FileImageThumbnailCache` と同じ
/// I/F に揃えてある。
@MainActor
final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()
    private var cache: [String: NSImage] = [:]
    private var lru: [String] = []
    private let maxItems = 128
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
        if !inFlight.contains(key) {
            inFlight.insert(key)
            Task.detached { [weak self] in
                let img = Self.generateThumbnail(at: url)
                await MainActor.run {
                    guard let self else { return }
                    self.inFlight.remove(key)
                    if let img {
                        self.store(key: key, image: img)
                        NotificationCenter.default.post(
                            name: .pastyVideoThumbReady,
                            object: nil,
                            userInfo: ["path": key]
                        )
                    }
                }
            }
        }
        return nil
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
