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
        p.title = L10n("whatsNew.title")
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

    /// 指定バージョンの `<version>.md` から `##` 見出し（level-2）を抜き出して返す。
    /// 文頭の `## ` プレフィックスは取り除き、空文字は除外する。
    /// ファイルが無い／見出しが 1 つも無い場合は空配列を返す。
    func extractFeatureHeadings(forVersion version: String) -> [String] {
        guard let body = loadMarkdown(for: version) else { return [] }
        var out: [String] = []
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 厳密に `## ` を取る (`###` は除外)
            if line.hasPrefix("## "), !line.hasPrefix("### ") {
                let stripped = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty {
                    out.append(stripped)
                }
            }
        }
        return out
    }

    /// 公開ユーティリティ: 現在表示中バージョンの見出し一覧 (OnboardingPresenter から使う)
    var currentVersionString: String { currentVersion }
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
                    .padding(.horizontal, PastyDesign.Spacing.xl)
                    .padding(.vertical, PastyDesign.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle()
                .fill(PastyDesign.Color.border)
                .frame(height: 0.5)
            HStack {
                Spacer()
                Button(L10n("common.close"), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(PastyDesign.Spacing.lg)
        }
        .frame(width: 540, height: 560)
        .background(VisualEffectBackground())
    }

    private var heroHeader: some View {
        ZStack {
            LinearGradient(
                colors: [PastyDesign.Color.accent, PastyDesign.Color.secondary],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Subtle gloss for a more luxurious surface
            LinearGradient(
                colors: [SwiftUI.Color.white.opacity(0.18), .clear],
                startPoint: .top, endPoint: .center
            )
            HStack(spacing: PastyDesign.Spacing.md + 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PastyDesign.Spacing.xs) {
                    Text(L10n("whatsNew.title"))
                        .font(PastyDesign.TypeRamp.hero)
                        .foregroundStyle(.white)
                    // Version pill — luxury accent
                    Text("v\(version)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, PastyDesign.Spacing.sm + 2)
                        .padding(.vertical, PastyDesign.Spacing.xxs + 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(SwiftUI.Color.white.opacity(0.22))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(SwiftUI.Color.white.opacity(0.35), lineWidth: 0.5)
                        )
                }
                Spacer()
            }
            .padding(.horizontal, PastyDesign.Spacing.xl)
        }
        .frame(height: 110)
        .pastyShadow(PastyDesign.Shadow.subtle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n("whatsNew.title")) バージョン \(version)")
        .accessibilityAddTraits(.isHeader)
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
                .font(PastyDesign.TypeRamp.hero)
                .foregroundStyle(PastyDesign.Color.textPrimary)
                .padding(.top, PastyDesign.Spacing.sm - 2)
        case .h2:
            // Section title with leading accent icon "tile"
            HStack(spacing: PastyDesign.Spacing.sm + 2) {
                RoundedRectangle(cornerRadius: PastyDesign.Radius.md, style: .continuous)
                    .fill(PastyDesign.Color.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: PastyDesign.Radius.md, style: .continuous)
                            .strokeBorder(PastyDesign.Color.border, lineWidth: 0.5)
                    )
                    .overlay(
                        Image(systemName: "sparkle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PastyDesign.Color.accent)
                    )
                    .frame(width: 28, height: 28)
                Text(attributed(block.text))
                    .font(PastyDesign.TypeRamp.title)
                    .foregroundStyle(PastyDesign.Color.textPrimary)
            }
            .padding(.top, PastyDesign.Spacing.md - 2)
        case .h3:
            Text(attributed(block.text))
                .font(PastyDesign.TypeRamp.bodyMedium)
                .foregroundStyle(PastyDesign.Color.textPrimary)
                .padding(.top, PastyDesign.Spacing.xs)
        case .bullet:
            HStack(alignment: .top, spacing: PastyDesign.Spacing.sm) {
                Circle()
                    .fill(PastyDesign.Color.accent)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                Text(attributed(block.text))
                    .font(PastyDesign.TypeRamp.body)
                    .foregroundStyle(PastyDesign.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph:
            Text(attributed(block.text))
                .font(PastyDesign.TypeRamp.body)
                .foregroundStyle(PastyDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .hr:
            Rectangle()
                .fill(PastyDesign.Color.border)
                .frame(height: 0.5)
                .padding(.vertical, PastyDesign.Spacing.sm - 2)
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
