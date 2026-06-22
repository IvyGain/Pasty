import SwiftUI
import AppKit
import LinkPresentation
import CryptoKit

/// v0.9.0 (塊 Z / D): LINK kind のクリップカードに「タイトル + ファビコン」の
/// 軽量プレビューを乗せるためのキャッシュ層。
///
/// 構成:
/// - `NSCache` ベースのメモリキャッシュ (上限 200)。
/// - `~/Library/Caches/io.pasty.app/url-previews/<sha256>.plist` のディスクキャッシュ。
///   `LPLinkMetadata` は `NSSecureCoding` 準拠なので、`NSKeyedArchiver` で永続化できる。
/// - favicon (NSImage) は同 sha256 の `.tiff` で並列に保存。
/// - 同一 URL に対して同時並行で `LPMetadataProvider` を走らせないよう、
///   `inflight` に進行中の `Task` を保持して結果を共有 (coalesce)。
///
/// 失敗時は `nil` を返し、`URLLinkPreview` ビュー側で「URL 文字列を素朴に表示する」
/// fallback に流れる。タイムアウトは 5 秒。
///
/// v0.9.5-beta (塊 P1): `URLLinkPreviewItem` で metadata と favicon NSImage を束ね、
/// `iconProvider` (NSItemProvider) を async で NSImage に解決するように拡張。
/// `LPLinkMetadata.iconImage` は macOS に存在しない (UIKit-only) ため。
public struct URLLinkPreviewItem {
    public let metadata: LPLinkMetadata
    public let favicon: NSImage?
}

@MainActor
final class URLLinkPreviewCache {
    static let shared = URLLinkPreviewCache()

    private let memCache = NSCache<NSString, LPLinkMetadata>()
    private let faviconMemCache = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<URLLinkPreviewItem?, Never>] = [:]
    private let diskDir: URL

    private init() {
        // v0.9.6-beta P0 #6: Caches directory lookup is technically optional.
        // Sandbox / unusual environments could in theory return an empty array.
        // Degrade gracefully to a tmp-backed path so memory cache still works
        // and disk persistence becomes best-effort rather than crashing the app.
        let base: URL
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            base = cachesDir
        } else {
            NSLog("URLLinkPreviewCache: cachesDirectory unavailable, falling back to NSTemporaryDirectory()")
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        self.diskDir = base.appendingPathComponent("io.pasty.app/url-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        memCache.countLimit = 200
        faviconMemCache.countLimit = 200
    }

    /// デバッグ / 設定画面でディスク状態を確認するための公開パス。
    var diskCacheURL: URL { diskDir }

    private func sha256Hex(_ key: String) -> String {
        let hash = SHA256.hash(data: Data(key.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(for key: String) -> URL {
        return diskDir.appendingPathComponent("\(sha256Hex(key)).plist")
    }

    private func faviconDiskURL(for key: String) -> URL {
        return diskDir.appendingPathComponent("\(sha256Hex(key)).tiff")
    }

    private func loadFromDisk(_ key: String) -> LPLinkMetadata? {
        let url = diskURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: data)
    }

    private func saveToDisk(_ metadata: LPLinkMetadata, key: String) {
        let url = diskURL(for: key)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: metadata,
                                                       requiringSecureCoding: true) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadFaviconFromDisk(_ key: String) -> NSImage? {
        let url = faviconDiskURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private func saveFaviconToDisk(_ image: NSImage, key: String) {
        let url = faviconDiskURL(for: key)
        if let tiff = image.tiffRepresentation {
            try? tiff.write(to: url, options: .atomic)
        }
    }

    /// `LPLinkMetadata.iconProvider` (NSItemProvider) を async で解決する。
    /// macOS では `iconImage` プロパティが存在しないため、こちらを使う必要がある。
    private static func resolveFavicon(from metadata: LPLinkMetadata) async -> NSImage? {
        guard let provider = metadata.iconProvider,
              provider.canLoadObject(ofClass: NSImage.self) else {
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            provider.loadObject(ofClass: NSImage.self) { obj, _ in
                cont.resume(returning: obj as? NSImage)
            }
        }
    }

    /// 同期 fast path: メモリ / ディスクキャッシュにヒットしたら即座に返す。
    /// 何もなければ `nil`。SwiftUI の `.task` から `metadata(for:)` を呼ぶときに
    /// 「描画 1 フレーム目で既にプレビューが出てる」状態を作るために使う。
    func cached(for url: URL) -> LPLinkMetadata? {
        let key = url.absoluteString
        let nsKey = key as NSString
        if let cached = memCache.object(forKey: nsKey) { return cached }
        if let disk = loadFromDisk(key) {
            memCache.setObject(disk, forKey: nsKey)
            return disk
        }
        return nil
    }

    /// 同期 fast path (v0.9.5-beta): metadata + favicon を束ねた `URLLinkPreviewItem` を返す。
    /// metadata が無ければ nil。favicon は無いこともある (まだ解決されていない / 取得不可)。
    func cachedItem(for url: URL) -> URLLinkPreviewItem? {
        guard let md = cached(for: url) else { return nil }
        let key = url.absoluteString
        let nsKey = key as NSString
        let favicon: NSImage? = {
            if let img = faviconMemCache.object(forKey: nsKey) { return img }
            if let img = loadFaviconFromDisk(key) {
                faviconMemCache.setObject(img, forKey: nsKey)
                return img
            }
            return nil
        }()
        return URLLinkPreviewItem(metadata: md, favicon: favicon)
    }

    /// 非同期 fetch: メモリ → ディスク → ネットワークの順に試す。
    /// 後方互換のため `LPLinkMetadata?` を返す API は残す。
    func metadata(for url: URL) async -> LPLinkMetadata? {
        return await previewItem(for: url)?.metadata
    }

    /// 非同期 fetch (v0.9.5-beta): metadata + favicon NSImage の束を返す。
    /// SettingsStore.urlPreviewFaviconEnabled が false の場合は favicon 解決をスキップ。
    func previewItem(for url: URL) async -> URLLinkPreviewItem? {
        let key = url.absoluteString
        let nsKey = key as NSString

        // メモリ / ディスクキャッシュ fast path.
        if let cachedMd = memCache.object(forKey: nsKey) {
            let favicon: NSImage? = {
                if let img = faviconMemCache.object(forKey: nsKey) { return img }
                if let img = loadFaviconFromDisk(key) {
                    faviconMemCache.setObject(img, forKey: nsKey)
                    return img
                }
                return nil
            }()
            return URLLinkPreviewItem(metadata: cachedMd, favicon: favicon)
        }
        if let disk = loadFromDisk(key) {
            memCache.setObject(disk, forKey: nsKey)
            let favicon: NSImage? = {
                if let img = faviconMemCache.object(forKey: nsKey) { return img }
                if let img = loadFaviconFromDisk(key) {
                    faviconMemCache.setObject(img, forKey: nsKey)
                    return img
                }
                return nil
            }()
            return URLLinkPreviewItem(metadata: disk, favicon: favicon)
        }

        if let existing = inflight[key] {
            return await existing.value
        }

        let faviconEnabled = SettingsStore.shared.urlPreviewFaviconEnabled

        let task = Task<URLLinkPreviewItem?, Never> { [weak self] in
            let provider = LPMetadataProvider()
            provider.timeout = 5
            // LPMetadataProvider は async 版が macOS 12+ で利用可能。
            // ない環境向けに completion handler を `withCheckedContinuation` で
            // 包む安全側のラッパを使う。
            let md: LPLinkMetadata? = await withCheckedContinuation { cont in
                provider.startFetchingMetadata(for: url) { metadata, _ in
                    cont.resume(returning: metadata)
                }
            }

            // favicon を async に解決 (任意).
            var favicon: NSImage? = nil
            if faviconEnabled, let md = md {
                favicon = await URLLinkPreviewCache.resolveFavicon(from: md)
            }

            return await MainActor.run { () -> URLLinkPreviewItem? in
                guard let self else { return nil }
                if let md {
                    self.memCache.setObject(md, forKey: nsKey)
                    self.saveToDisk(md, key: key)
                    if let favicon {
                        self.faviconMemCache.setObject(favicon, forKey: nsKey)
                        self.saveFaviconToDisk(favicon, key: key)
                    }
                }
                self.inflight.removeValue(forKey: key)
                if let md {
                    return URLLinkPreviewItem(metadata: md, favicon: favicon)
                }
                return nil
            }
        }
        inflight[key] = task
        return await task.value
    }
}

/// v0.9.0 (塊 Z / D): LINK kind のクリップに対する SwiftUI ビュー。
/// ファビコン + タイトル + ホスト名の薄いカード断片を返す。
/// 取得失敗 / 取得中はそのまま URL 文字列を出すので、見た目が「空」になる瞬間はない。
struct URLLinkPreview: View {
    let url: URL
    @State private var item: URLLinkPreviewItem?

    init(url: URL) {
        self.url = url
        // 同期 fast path: キャッシュにあれば即座に State を埋め、
        // 1 フレーム目から「タイトルが出ている状態」で見せる。
        _item = State(initialValue: URLLinkPreviewCache.shared.cachedItem(for: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item = item {
                HStack(spacing: 6) {
                    // v0.9.5-beta (塊 P1): iconProvider から解決した NSImage を優先描画。
                    // 解決できなかったサイトは systemImage の link アイコンに fallback。
                    if let icon = item.favicon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .cornerRadius(3)
                    } else {
                        Image(systemName: "link")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    Text(item.metadata.title ?? url.host ?? url.absoluteString)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(url.host ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(url.absoluteString)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: url.absoluteString) {
            // すでに metadata + favicon が揃っていれば再 fetch しない。
            if item != nil && item?.favicon != nil { return }
            // metadata のみ手元にある場合も、favicon が無ければ再 fetch を試す。
            if let newItem = await URLLinkPreviewCache.shared.previewItem(for: url) {
                item = newItem
            }
        }
    }
}
