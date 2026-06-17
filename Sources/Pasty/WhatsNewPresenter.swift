import SwiftUI
import AppKit

/// アップデート後（または明示要求時）に「このバージョンで何が変わったか」を
/// 表示するモーダルダイアログ。Markdown 形式のリリースノートを
/// `Sources/Pasty/Resources/whats-new/<version>.md` から読み込み、
/// AttributedString として描画する。
@MainActor
final class WhatsNewPresenter {
    static let shared = WhatsNewPresenter()
    private init() {}

    private static let lastShownKey = "pasty.whatsNewLastShownVersion"

    private var panel: NSPanel?

    /// アプリ起動時に呼ぶ。前回表示済みバージョンと現在バージョンが異なる、
    /// かつ Markdown ファイルが存在するときだけパネルを表示する。
    func presentIfNeeded() {
        let current = currentVersion
        let lastShown = UserDefaults.standard.string(forKey: Self.lastShownKey)
        guard lastShown != current else { return }
        guard loadMarkdown(for: current) != nil else {
            // ファイルが無いバージョンは静かにスキップ
            UserDefaults.standard.set(current, forKey: Self.lastShownKey)
            return
        }
        presentForce()
    }

    /// 設定 →「リリースノート」から呼ばれる強制表示。ファイルが無くても
    /// fallback メッセージを出す。
    func presentForce() {
        dismiss()
        let body = loadMarkdown(for: currentVersion) ?? "## このバージョンのリリースノートはまだありません\n後ほどご確認ください。"
        let view = WhatsNewView(version: currentVersion,
                                markdownBody: body,
                                onDismiss: { [weak self] in self?.dismiss() })
        let host = NSHostingController(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.title = "Pasty の新機能"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.contentViewController = host
        p.isReleasedWhenClosed = false
        p.center()
        p.level = .floating
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(currentVersion, forKey: Self.lastShownKey)
        panel = p
    }

    fileprivate func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    private func loadMarkdown(for version: String) -> String? {
        guard let url = Bundle.module.url(forResource: version,
                                          withExtension: "md",
                                          subdirectory: "whats-new"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

@MainActor
private struct WhatsNewView: View {
    let version: String
    let markdownBody: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            heroHeader
            ScrollView {
                renderedMarkdown
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.5)
            HStack {
                Spacer()
                Button("閉じる", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 540, height: 560)
        .background(VisualEffectBackground())
    }

    private var heroHeader: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pasty \(version)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("このバージョンの新機能")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .frame(height: 90)
    }

    @ViewBuilder
    private var renderedMarkdown: some View {
        // AttributedString の Markdown はリスト/見出しを部分的にしかサポートしない
        // ので、最低限の体裁を 1 文字列で出す。`#`/`##`/`###` 見出しは bold + サイズ別、
        // 行頭 `- ` は箇条書きとして表示。
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parsedBlocks(), id: \.id) { block in
                blockView(block)
            }
        }
    }

    private struct MarkdownBlock: Identifiable {
        let id = UUID()
        let level: Level
        let text: String
        enum Level { case h1, h2, h3, bullet, paragraph, hr }
    }

    private func parsedBlocks() -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        for rawLine in markdownBody.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("### ") {
                out.append(.init(level: .h3, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                out.append(.init(level: .h2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                out.append(.init(level: .h1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                out.append(.init(level: .bullet, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("---") {
                out.append(.init(level: .hr, text: ""))
            } else {
                out.append(.init(level: .paragraph, text: line))
            }
        }
        return out
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.level {
        case .h1:
            Text(attributed(block.text))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .padding(.top, 6)
        case .h2:
            Text(attributed(block.text))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .padding(.top, 10)
        case .h3:
            Text(attributed(block.text))
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 4)
        case .bullet:
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(attributed(block.text))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph:
            Text(attributed(block.text))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        case .hr:
            Divider().padding(.vertical, 6)
        }
    }

    /// インラインの太字 `**...**` を AttributedString に変換。それ以外はそのまま。
    private func attributed(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: s) {
            return attr
        }
        return AttributedString(s)
    }
}
