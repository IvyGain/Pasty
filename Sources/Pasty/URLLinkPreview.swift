import SwiftUI
import LinkPresentation
import CryptoKit

/// v0.9.0 (塊 Z / D): LINK kind のクリップカードに「タイトル + ファビコン」の
/// 軽量プレビューを乗せるためのキャッシュ層。
///
/// 構成:
/// - `NSCache` ベースのメモリキャッシュ (上限 200)。
/// - `~/Library/Caches/io.pasty.app/url-previews/<sha256>.plist` のディスクキャッシュ。
///   `LPLinkMetadata` は `NSSecureCoding` 準拠なので、`NSKeyedArchiver` で永続化できる。
/// - 同一 URL に対して同時並行で `LPMetadataProvider` を走らせないよう、
///   `inflight` に進行中の `Task` を保持して結果を共有 (coalesce)。
///
/// 失敗時は `nil` を返し、`URLLinkPreview` ビュー側で「URL 文字列を素朴に表示する」
/// fallback に流れる。タイムアウトは 5 秒。
@MainActor
final class URLLinkPreviewCache {
    static let shared = URLLinkPreviewCache()

    private let memCache = NSCache<NSString, LPLinkMetadata>()
    private var inflight: [String: Task<LPLinkMetadata?, Never>] = [:]
    private let diskDir: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskDir = base.appendingPathComponent("io.pasty.app/url-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        memCache.countLimit = 200
    }

    /// デバッグ / 設定画面でディスク状態を確認するための公開パス。
    var diskCacheURL: URL { diskDir }

    private func diskURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent("\(hex).plist")
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

    /// 非同期 fetch: メモリ → ディスク → ネットワークの順に試す。
    func metadata(for url: URL) async -> LPLinkMetadata? {
        let key = url.absoluteString
        let nsKey = key as NSString
        if let cached = memCache.object(forKey: nsKey) { return cached }
        if let disk = loadFromDisk(key) {
            memCache.setObject(disk, forKey: nsKey)
            return disk
        }
        if let existing = inflight[key] {
            return await existing.value
        }
        let task = Task<LPLinkMetadata?, Never> { [weak self] in
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
            await MainActor.run {
                if let md {
                    self?.memCache.setObject(md, forKey: nsKey)
                    self?.saveToDisk(md, key: key)
                }
                self?.inflight.removeValue(forKey: key)
            }
            return md
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
    @State private var metadata: LPLinkMetadata?

    init(url: URL) {
        self.url = url
        // 同期 fast path: キャッシュにあれば即座に State を埋め、
        // 1 フレーム目から「タイトルが出ている状態」で見せる。
        _metadata = State(initialValue: URLLinkPreviewCache.shared.cached(for: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let m = metadata {
                HStack(spacing: 6) {
                    // LPLinkMetadata.iconImage は AppKit には存在しない (UIKit のみ)。
                    // macOS では iconProvider (NSItemProvider) を非同期解決する必要があるが、
                    // ここではビルドを通すための最小スタブとして systemImage フォールバックを使う。
                    // TODO(塊 Z/D): iconProvider を async で解決して NSImage に変換する。
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                    Text(m.title ?? url.host ?? url.absoluteString)
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
            if metadata != nil { return }
            metadata = await URLLinkPreviewCache.shared.metadata(for: url)
        }
    }
}
