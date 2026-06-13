import SwiftUI
import AppKit

/// クリップのプレビュー用サムネイル。画像クリップはBlobから読んで、
/// それ以外はSF Symbolにフォールバック。
struct ClipThumbnail: View {
    let clip: ClipItem
    var size: CGFloat = 28
    var corner: CGFloat = 6

    var body: some View {
        Group {
            if clip.kind == .image, let p = clip.dataPath,
               let nsImage = ImageBlobCache.shared.image(for: p) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: clip.kind.iconName)
                    .foregroundStyle(.tint)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 何度も同じ画像をディスクから読まないための最小キャッシュ。
@MainActor
final class ImageBlobCache {
    static let shared = ImageBlobCache()
    private var cache: [String: NSImage] = [:]
    private var lru: [String] = []     // 末尾が最近使用
    private let maxItems = 256

    func image(for relativePath: String) -> NSImage? {
        if let cached = cache[relativePath] {
            touch(relativePath)
            return cached
        }
        let url = ClipBlobs.blobURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let img = NSImage(contentsOf: url) else { return nil }
        if cache.count >= maxItems, let oldest = lru.first {
            cache.removeValue(forKey: oldest)
            lru.removeFirst()
        }
        cache[relativePath] = img
        lru.append(relativePath)
        return img
    }

    private func touch(_ key: String) {
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
            lru.append(key)
        }
    }
}

/// `.file` kind だけど中身が画像ファイル (PNG/JPEG/HEIC/GIF 等) の時に
/// ローカル file:// URL から実画像を読み出してキャッシュするヘルパ。
/// CleanShot/macOS スクリーンショット/Finder ドラッグなどから来た画像が
/// すべてカードに正しくプレビュー表示されるようにする。
@MainActor
final class FileImageThumbnailCache {
    static let shared = FileImageThumbnailCache()
    private var cache: [String: NSImage] = [:]
    private var lru: [String] = []
    private let maxItems = 256
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp",
        "tiff", "tif", "bmp", "icns"
    ]

    func image(for clip: ClipItem) -> NSImage? {
        guard clip.kind == .file else { return nil }
        let raw = clip.content ?? clip.preview
        guard !raw.isEmpty else { return nil }
        // 改行区切りで複数 path/url のときは先頭だけ採用
        let firstLine = raw
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? raw
        guard let url = Self.url(fromContent: firstLine) else { return nil }
        let ext = url.pathExtension.lowercased()
        guard Self.imageExtensions.contains(ext) else { return nil }

        let key = url.path
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let img = NSImage(contentsOf: url) else { return nil }
        if cache.count >= maxItems, let oldest = lru.first {
            cache.removeValue(forKey: oldest)
            lru.removeFirst()
        }
        cache[key] = img
        lru.append(key)
        return img
    }

    private func touch(_ key: String) {
        if let idx = lru.firstIndex(of: key) {
            lru.remove(at: idx)
            lru.append(key)
        }
    }

    /// `file:///` URL もプレーンパス (例: `/Users/.../foo.png`) も両方受ける。
    private static func url(fromContent s: String) -> URL? {
        if s.hasPrefix("file://"), let u = URL(string: s) { return u }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        // ~ 展開
        if s.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: s).expandingTildeInPath)
        }
        return nil
    }
}
