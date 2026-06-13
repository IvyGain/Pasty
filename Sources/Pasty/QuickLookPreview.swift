import AppKit
import QuickLookUI
import SwiftUI

/// `Space` で呼ぶ Quick Look フルプレビュー。`QLPreviewPanel` を Pasty パネル
/// から **フォーカスを奪わずに** 立ち上げるためのラッパ。
///
/// 中身は ClipItem ごとに一時ファイルへ書き出して `QLPreviewItem` に渡す方式。
/// 画像クリップは blob をそのまま、テキスト/コードはシンタックスハイライト
/// 付き HTML、リッチテキストは RTF として書き出すので、QuickLook が知っている
/// 形式に確実にハマる。
@MainActor
final class QuickLookPreview: NSObject {
    static let shared = QuickLookPreview()

    private var items: [ClipItem] = []
    private var index: Int = 0
    private var datasource: PreviewDataSource?
    private var tmpDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastyQuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private override init() {}

    /// `items[currentIndex]` の Quick Look を立ち上げる。Esc / 矢印で
    /// QLPreviewPanel が制御を取るので Pasty パネルはそのまま開いておける。
    func show(items: [ClipItem], at currentIndex: Int) {
        guard !items.isEmpty else { return }
        self.items = items
        self.index = max(0, min(currentIndex, items.count - 1))

        let ds = PreviewDataSource(parent: self, items: items)
        self.datasource = ds

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = ds
        panel.delegate = ds
        panel.currentPreviewItemIndex = self.index
        panel.reloadData()
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.refreshCurrentPreviewItem()
        }
    }

    func close() {
        QLPreviewPanel.shared().close()
    }

    // MARK: - URL materialization

    /// ClipItem → QLPreview が読める一時ファイル URL。
    fileprivate func makePreviewURL(for item: ClipItem) -> URL? {
        switch item.kind {
        case .image:
            if let rel = item.dataPath {
                let abs = ClipBlobs.blobURL(for: rel)
                if FileManager.default.fileExists(atPath: abs.path) { return abs }
            }
            return nil

        case .file:
            if let s = item.content, let url = URL(string: s), url.isFileURL,
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            return nil

        case .link, .text, .richText, .color, .other:
            return writeTextPreview(item: item)
        }
    }

    private func writeTextPreview(item: ClipItem) -> URL? {
        let raw = item.content ?? item.preview
        let hash = item.contentHash.isEmpty ? "\(abs(raw.hashValue))" : item.contentHash
        let html = renderHTML(for: item, raw: raw)
        let url = tmpDir
            .appendingPathComponent("pasty-\(hash).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func renderHTML(for item: ClipItem, raw: String) -> String {
        let language = SyntaxHighlighter.detect(from: raw)
        let escaped = raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let body: String
        if language == .markdown {
            body = "<pre class=\"md\">\(escaped)</pre>"
        } else if language == .plain {
            body = "<pre class=\"plain\">\(escaped)</pre>"
        } else {
            body = "<pre class=\"code\">\(escaped)</pre>"
        }
        let title = item.preview
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let chars = raw.count
        let source = item.sourceAppName ?? "—"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <title>\(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 13px/1.55 -apple-system, "SF Pro Text", "Hiragino Kaku Gothic ProN", sans-serif;
                 margin: 0; padding: 28px 36px; }
          header { color: #86868b; font-size: 11px; letter-spacing: 0.08em;
                   text-transform: uppercase; margin-bottom: 16px; }
          header strong { color: var(--accent, #6366f1); margin-right: 8px; }
          pre { white-space: pre-wrap; word-break: break-word;
                font: 13px/1.65 ui-monospace, "SF Mono", Menlo, monospace; }
          pre.md { font-family: -apple-system, "SF Pro Text", sans-serif;
                   font-size: 14px; line-height: 1.7; }
        </style></head><body>
        <header><strong>\(language.rawValue.uppercased())</strong>
        \(chars) chars · \(source)</header>
        \(body)
        </body></html>
        """
    }
}

private final class PreviewDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    // QLPreviewPanel が delegate を nonisolated として呼ぶので、main actor 隔離を
    // 跨げる stash を持つ。show() 時に MainActor 上で詰める。
    nonisolated(unsafe) var cachedItems: [ClipItem] = []
    nonisolated(unsafe) weak var parent: QuickLookPreview?

    init(parent: QuickLookPreview, items: [ClipItem]) {
        self.parent = parent
        self.cachedItems = items
        super.init()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        cachedItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard cachedItems.indices.contains(index) else {
            return WrappedItem(url: URL(fileURLWithPath: "/dev/null"), title: "")
        }
        let item = cachedItems[index]
        let url = MainActor.assumeIsolated { parent?.makePreviewURL(for: item) }
            ?? URL(fileURLWithPath: "/dev/null")
        return WrappedItem(url: url, title: item.preview)
    }
}

private final class WrappedItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        super.init()
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}
