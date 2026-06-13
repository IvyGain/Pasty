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
