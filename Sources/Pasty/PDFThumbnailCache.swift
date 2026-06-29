import AppKit
import PDFKit

/// PDF ファイルの 1 ページ目をサムネ画像として取得し、LRU キャッシュに保持する。
/// `VideoThumbnailCache` と同じ I/F に揃え、HoverPreview / Explorer 側から
/// `image(for:)` を sync で呼び出せるようにする。
///
/// - cache hit  → 即座に NSImage を返す
/// - cache miss → バックグラウンドでサムネ生成し、完了したら
///                `NotificationCenter` に `.pastyPDFThumbReady` を post する。
///                UI 側がそれを購読して再描画するパターン。
@MainActor
final class PDFThumbnailCache {
    static let shared = PDFThumbnailCache()
    /// v0.10.0-beta: disk sidecar for cold-start hits. mtime-based LRU,
    /// 20 MiB cap, 90 day TTL. Sweep is invoked once on deferred startup
    /// from `PastyApp`. NOT used for in-flight dedup or `failed` tracking
    /// — those stay in memory.
    static let diskStore = DiskThumbnailStore(
        bucket: "pdf-thumbs",
        maxBytes: 20 * 1024 * 1024,
        maxAge: 90 * 86400)

    private var cache: [String: NSImage] = [:]
    private var lru: [String] = []
    private let maxItems = 128
    /// 進行中の生成 URL。@MainActor 隔離で全 mutate が直列化されるため、追加ロック不要。
    /// Swift 6 strict concurrency 移行で NSLock を撤去 (v0.10.0-beta)。
    private var inFlight: Set<String> = []
    /// 過去に「生成を試みて失敗 / PDF として読めなかった」URL。再試行を抑制する。
    private var failed: Set<String> = []

    /// `clip.content` から file URL を解釈してサムネを取得。`.pdf` 以外でも、
    /// 呼び出し側が拡張子で振り分けた後に呼ぶ前提なので拡張子チェックは緩め。
    func image(for clip: ClipItem) -> NSImage? {
        guard let url = pdfURL(for: clip) else { return nil }
        let key = url.path
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        if failed.contains(key) { return nil }
        // @MainActor 隔離で check+insert は自動的に原子的。
        if inFlight.contains(key) { return nil }
        inFlight.insert(key)
        Task.detached { [weak self] in
            // v0.10.0-beta: try disk LRU before re-rasterising the PDF.
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
                name: .pastyPDFThumbReady,
                object: nil,
                userInfo: ["path": key]
            )
            if persistToDisk, let tiff = image.tiffRepresentation {
                Task.detached(priority: .utility) {
                    await Self.diskStore.store(key: key, data: tiff)
                }
            }
        } else {
            failed.insert(key)
        }
    }

    /// テスト / プレビュー用。任意の URL から sync hit のみ調べる。
    func cached(for url: URL) -> NSImage? { cache[url.path] }

    nonisolated private static func generateThumbnail(at url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let document = PDFDocument(url: url) else { return nil }
        guard let page = document.page(at: 0) else { return nil }
        // `.mediaBox` で 1 ページ目を 200×280 (A4 縦比に近い) で書き出す。
        // PDFKit が自動で aspect-fit してくれる。
        let size = CGSize(width: 200, height: 280)
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        // PDFKit が空イメージを返してきた場合の保険。
        if thumb.size.width < 1 || thumb.size.height < 1 { return nil }
        return thumb
    }

    private func pdfURL(for clip: ClipItem) -> URL? {
        // file kind の content は QuickLookPreview と同じ規約: file:// URL 文字列
        let raw = (clip.content ?? clip.preview).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("file://"), let u = URL(string: raw) { return u }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        if raw.hasPrefix("~") { return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath) }
        // dataPath に PDF blob として保存されているケース (将来用)。
        if let p = clip.dataPath {
            return ClipBlobs.blobURL(for: p)
        }
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
    static let pastyPDFThumbReady = Notification.Name("pasty.pdfThumb.ready")
}
