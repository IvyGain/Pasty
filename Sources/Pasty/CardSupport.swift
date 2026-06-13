import SwiftUI
import AppKit

// MARK: - Source app icon cache
/// `bundleIdentifier` → `NSImage` のメモリキャッシュ。`NSWorkspace.icon(forFile:)`
/// は OS への問合せが入って軽くないので、カードグリッドが滑らかにスクロール
/// できるようプロセス内でキャッシュしておく。
@MainActor
final class SourceAppIconCache {
    static let shared = SourceAppIconCache()
    private var cache: [String: NSImage] = [:]
    private let workspace = NSWorkspace.shared

    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        var img: NSImage? = nil
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            img = workspace.icon(forFile: url.path)
        }
        if let img { cache[bundleID] = img }
        return img
    }
}

// MARK: - Kind palette
/// Paste 風の「カードの上に乗る色帯」と「ラベル」のペア。
/// Pasty では Liquid Glass トーンに馴染むよう、彩度をやや落として
/// 高級感のあるニュアンスにしている。
enum KindPalette {
    static func color(for kind: ClipKind) -> Color {
        switch kind {
        case .text:     return Color(hex: "#34C759")  // Notes 風グリーン
        case .richText: return Color(hex: "#FF9F0A")  // フォーマット付き = サフラン
        case .image:    return Color(hex: "#FF375F")  // 写真 = コーラル
        case .file:     return Color(hex: "#5E5CE6")  // ファイル = アクアブルー
        case .link:     return Color(hex: "#0A84FF")  // リンク = Safari ブルー
        case .color:    return Color(hex: "#BF5AF2")  // カラー = ラベンダー
        case .other:    return Color(hex: "#8E8E93")
        }
    }

    static func label(for kind: ClipKind) -> String {
        switch kind {
        case .text:     return "TEXT"
        case .richText: return "RICH"
        case .image:    return "IMAGE"
        case .file:     return "FILE"
        case .link:     return "LINK"
        case .color:    return "COLOR"
        case .other:    return "ITEM"
        }
    }

    /// シンタックスからコードと判別された場合のラベル上書き。
    static func detectedLabel(for clip: ClipItem) -> String {
        if clip.kind == .text, let s = clip.content {
            let lang = SyntaxHighlighter.detect(from: s)
            switch lang {
            case .swift, .python, .javascript, .shell:
                return "CODE"
            case .json:     return "JSON"
            case .html:     return "HTML"
            case .markdown: return "MD"
            case .plain:    return KindPalette.label(for: clip.kind)
            }
        }
        return KindPalette.label(for: clip.kind)
    }

    static func detectedColor(for clip: ClipItem) -> Color {
        if clip.kind == .text, let s = clip.content {
            let lang = SyntaxHighlighter.detect(from: s)
            switch lang {
            case .swift, .python, .javascript, .shell:
                return Color(hex: "#FFD60A")  // コード = ハイライト系イエロー
            case .json:     return Color(hex: "#FF9F0A")
            case .html:     return Color(hex: "#FF6482")
            case .markdown: return Color(hex: "#64D2FF")
            case .plain:    return color(for: clip.kind)
            }
        }
        return color(for: clip.kind)
    }
}

// MARK: - Relative time
/// 「2 hours ago」「5 days ago」風の短い相対表記。
/// ロケールに合わせて日本語/英語が自動で切り替わる Foundation 標準を活用。
enum RelativeTimeFormatter {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Bottom domain helper
/// 「kvellhome.com/lookbook」のように、URL から短いドメイン+パス短縮を作る。
/// 失敗時は nil を返す（メタバーから単に省く）。
extension String {
    /// `s.matches(["A", "B", "C"])` を簡潔に書くためのヘルパ。
    func matches(_ candidates: [String]) -> Bool { candidates.contains(self) }
}

enum DomainShortener {
    static func short(for clip: ClipItem) -> String? {
        guard let content = clip.content else { return nil }
        guard let url = URL(string: content),
              let host = url.host else { return nil }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path.isEmpty || url.path == "/" ? "" : url.path
        // パスは 22 文字でカット
        let trimmedPath = path.count > 22 ? String(path.prefix(22)) + "…" : path
        return h + trimmedPath
    }
}
