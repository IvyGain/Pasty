import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// `ClipItem` をシステムのペーストボードに書き戻し、直前のフロントアプリに
/// 戻してから ⌘V を送出する。`paste(_:)` は単発、`pasteSequence(_:)` は
/// 複数アイテムを順番に貼り付ける（フォームへの自動入力や複数行展開向け）。
@MainActor
final class PasteAutomator {
    static let shared = PasteAutomator()
    private init() {}

    /// Accessibility 権限が取れているか。初回は OS のダイアログを出す。
    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 1 つのクリップを貼り付ける。`autoPaste` が true なら ⌘V も送る。
    func paste(_ item: ClipItem, asPlainText: Bool = false, autoPaste: Bool = true) {
        Task { @MainActor in
            place(item, asPlainText: asPlainText)
            guard autoPaste else { return }
            await PreviousAppTracker.shared.restoreFocus()
            emitCommandV()
        }
    }

    /// 複数クリップを順番に貼り付ける。
    /// - separator: 結合戦略
    ///     - `.join(string)` : 1 つの文字列に連結して 1 度だけ貼り付け（推奨デフォルト）
    ///     - `.sequence` : 各アイテムを置いて ⌘V → 次のアイテムを置いて ⌘V を反復
    ///                       （フォーム入力や Tab 区切りで「次の欄」に進めたい時用）
    func pasteSequence(_ items: [ClipItem],
                       asPlainText: Bool = false,
                       strategy: SequenceStrategy = .join(separator: "\n"),
                       autoPaste: Bool = true) {
        guard !items.isEmpty else { return }
        switch strategy {
        case .join(let sep):
            // 画像 / バイナリは「結合」には参加しない（=文字列に変換するのが嘘になる）。
            // ファイルパスは絶対パス文字列として文字列扱いする。
            let parts: [String] = items.compactMap { clip in
                switch clip.kind {
                case .image:
                    return clip.dataPath.map { ClipBlobs.blobURL(for: $0).path }
                case .file:
                    return clip.content ?? clip.preview
                default:
                    return clip.content ?? clip.preview
                }
            }
            let merged = parts.joined(separator: sep)
            let synthetic = ClipItem(
                id: nil, createdAt: Date(),
                kind: .text,
                preview: String(merged.prefix(120)),
                content: merged,
                dataPath: nil,
                byteSize: Int64(merged.utf8.count),
                sourceBundleId: "io.pasty.bulk",
                sourceAppName: "Pasty Bulk",
                contentHash: ""
            )
            paste(synthetic, asPlainText: asPlainText, autoPaste: autoPaste)
        case .sequence(let delay):
            Task { @MainActor in
                guard autoPaste else {
                    // フォーカス復元しないモードでは最後のアイテムだけクリップに置く
                    if let last = items.last { place(last, asPlainText: asPlainText) }
                    return
                }
                await PreviousAppTracker.shared.restoreFocus()
                for (idx, item) in items.enumerated() {
                    place(item, asPlainText: asPlainText)
                    // 1 つ目は restoreFocus 直後なので待ちなし、2 つ目以降は短い間を空ける
                    if idx > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    emitCommandV()
                    // ペースト後、レシーバが文字を入れる時間を確保
                    try? await Task.sleep(nanoseconds: 60_000_000) // 60 ms
                }
            }
        }
    }

    enum SequenceStrategy {
        /// 1 度の貼付に連結。改行 / カンマ / TAB などお好みのセパレータで。
        case join(separator: String)
        /// 1 アイテムごとに ⌘V を撃つ。`delay` は各 ⌘V の間隔。
        case sequence(delayBetween: TimeInterval)
    }

    // MARK: - private

    private func place(_ item: ClipItem, asPlainText: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text, .richText, .link, .color, .other:
            if let raw = item.content {
                // {{date}} {{cursor}} {{uuid}} {{user}} {{clipboard}} などを貼付
                // 直前にここで展開する。テンプレ自体は履歴に残したまま、貼付されるのは
                // 展開後の文字列。
                let expanded = SnippetEngine.expand(raw)
                pb.setString(expanded.text, forType: .string)
                if item.kind == .richText, !asPlainText, let data = expanded.text.data(using: .utf8) {
                    pb.setData(data, forType: .rtf)
                }
            } else {
                pb.setString(item.preview, forType: .string)
            }
        case .file:
            if let s = item.content, let url = URL(string: s) {
                if url.isFileURL {
                    pb.writeObjects([url as NSURL])
                } else {
                    pb.setString(s, forType: .string)
                }
            }
        case .image:
            if let p = item.dataPath {
                let url = ClipBlobs.blobURL(for: p)
                if let data = try? Data(contentsOf: url) {
                    // 受信側アプリの互換性のため PNG / TIFF / fileURL を一緒に並べる。
                    // 多くの編集アプリは PNG を最優先で読むが、Pages/Keynote のような
                    // Cocoa 系は TIFF を期待することもあるので両方提供。
                    pb.setData(data, forType: .png)
                    if let image = NSImage(data: data),
                       let tiff = image.tiffRepresentation {
                        pb.setData(tiff, forType: .tiff)
                    }
                    pb.writeObjects([url as NSURL])
                }
            }
        }
    }

    private func emitCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src,
                           virtualKey: CGKeyCode(kVK_ANSI_V),
                           keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: src,
                         virtualKey: CGKeyCode(kVK_ANSI_V),
                         keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}

/// バイナリ payload（画像・ファイル・将来的に動画）を内容ハッシュで
/// 保存するシンプルなアドレスドストア。SQLiteを肥大化させず、`dataPath`
/// は相対パスだけを持つ。
enum ClipBlobs {
    static var directory: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = appSupport
            .appendingPathComponent("Pasty", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func blobURL(for relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    /// 画像データを `images/<hash>.<ext>` に保存して相対パスを返す。
    /// 既に同じハッシュのファイルがあれば書かずにパスだけ返す（自然なdedupe）。
    @discardableResult
    static func writeImage(_ data: Data, hash: String, suggestedExt: String = "png") -> String {
        let subdir = "images"
        let dir = directory.appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rel = "\(subdir)/\(hash).\(suggestedExt)"
        let url = directory.appendingPathComponent(rel)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        return rel
    }
}
