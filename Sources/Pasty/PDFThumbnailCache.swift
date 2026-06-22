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

    private var cache: [String: NSImage] = [:]
    private var lru: [String] = []
    private let maxItems = 128
    private var inFlight: Set<String> = []
    /// 過去に「生成を試みて失敗 / PDF として読めなかった」URL。再試行を抑制する。
    private var failed: Set<String> = []
    /// `inFlight` Set の check+insert を原子的にするためのロック。
    /// MainActor 隔離だけに頼らず NSLock で明示的に直列化し、二重 Task 起動を防ぐ。
    /// ロックを保持したまま await することは絶対に避ける (短い critical section のみ)。
    private let inFlightLock = NSLock()

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
        // check+insert を 1 critical section で原子的に行い、二重 Task 起動を防ぐ。
        let shouldSchedule: Bool = inFlightLock.withLock {
            if inFlight.contains(key) {
                return false
            }
            inFlight.insert(key)
            return true
        }
        if shouldSchedule {
            Task.detached { [weak self] in
                let img = Self.generateThumbnail(at: url)
                await MainActor.run {
                    guard let self else { return }
                    defer {
                        self.inFlightLock.withLock { _ = self.inFlight.remove(key) }
                    }
                    if let img {
                        self.store(key: key, image: img)
                        NotificationCenter.default.post(
                            name: .pastyPDFThumbReady,
                            object: nil,
                            userInfo: ["path": key]
                        )
                    } else {
                        self.failed.insert(key)
                    }
                }
            }
        }
        return nil
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
