import SwiftUI
import AppKit

// MARK: - LinkMetadata stub
//
// `LinkMetadataFetcher` は別エージェントが実装中の想定。
// このファイル内で同名型がモジュールにまだ存在しなくてもビルドが通るよう、
// プロトコル参照ではなく `Any?` を経由した動的探索のフォールバックは取らず、
// 「未実装ならフォールバック表示」を default 動作にする。
// 同モジュールで提供された場合は自動的にそちらが優先される。
#if PASTY_LINK_METADATA_STUB
struct LinkMetadata: Equatable {
    let title: String?
    let host: String
    let faviconURL: URL?
}

@MainActor
final class LinkMetadataFetcher {
    static let shared = LinkMetadataFetcher()
    func fetch(url: URL) async -> LinkMetadata? { nil }
}
#endif

// MARK: - ClipPreviewView

/// ClipItem の全コンテンツをリッチに描画する SwiftUI View。
/// Explorer モード (Strip/Spotlight の右ペイン) と HoverPreview のミニ pill
/// で共通利用される。`isCompact` で寸法プリセットを切り替える。
@MainActor
struct ClipPreviewView: View {
    let clip: ClipItem
    var isCompact: Bool = false
    var isEditing: Binding<Bool>? = nil
    var editedContent: Binding<String>? = nil
    var onSave: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @State private var linkMeta: LinkMetadata? = nil
    @State private var linkLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
            metaBar
            Divider().opacity(0.4)
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let editingBinding = isEditing, editingBinding.wrappedValue {
                editingControls
            }
        }
        .padding(isCompact ? 10 : 14)
        .frame(
            maxWidth: isCompact ? nil : .infinity,
            maxHeight: isCompact ? nil : .infinity,
            alignment: .topLeading
        )
        .frame(
            width: isCompact ? 300 : nil,
            height: isCompact ? 200 : nil,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .fill(.thinMaterial.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(PastyTheme.strokeOpacity), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
        .task(id: clip.id) {
            await loadLinkMetaIfNeeded()
        }
    }

    // MARK: Meta bar

    @ViewBuilder
    private var metaBar: some View {
        let chips: [String] = metaChips()
        if isCompact {
            HStack(spacing: 6) {
                Image(systemName: clip.kind.iconName)
                    .font(.caption2)
                    .foregroundStyle(.tint)
                Text(chips.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: clip.kind.iconName)
                    .font(.caption)
                    .foregroundStyle(.tint)
                MetaChipsFlow(chips: chips)
                Spacer(minLength: 0)
            }
        }
    }

    private func metaChips() -> [String] {
        var chips: [String] = []
        chips.append(clip.kind.rawValue.uppercased())

        switch clip.kind {
        case .text, .richText, .link, .color, .other:
            if let content = clip.content {
                chips.append("\(formattedCount(content.count)) 文字")
            }
        case .image, .file, .video:
            chips.append(formattedBytes(clip.byteSize))
        }

        if let app = clip.sourceAppName, !app.isEmpty {
            chips.append(app)
        }
        chips.append(relativeDate(clip.createdAt))

        if clip.kind == .link, let url = clip.content?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            chips.append("🔗 " + shortenURL(url))
        }
        return chips
    }

    // MARK: Content area

    @ViewBuilder
    private var contentArea: some View {
        if let editingBinding = isEditing,
           editingBinding.wrappedValue,
           let textBinding = editedContent {
            editorView(text: textBinding)
        } else {
            switch clip.kind {
            case .text, .other:
                textOrCodeOrMarkdownView()
            case .richText:
                richTextView()
            case .image:
                imageView()
            case .file, .video:
                fileView()
            case .link:
                linkView()
            case .color:
                colorView()
            }
        }
    }

    // MARK: - Text / Code / Markdown

    @ViewBuilder
    private func textOrCodeOrMarkdownView() -> some View {
        let raw = clip.content ?? clip.preview
        let lang = SyntaxHighlighter.detect(from: raw)

        if lang == .markdown {
            markdownView(raw: raw)
        } else if lang != .plain {
            codeView(raw: raw, language: lang)
        } else {
            plainTextView(raw: raw)
        }
    }

    @ViewBuilder
    private func plainTextView(raw: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(raw)
                    .font(PastyTheme.monoFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            if !isCompact, raw.contains("{{") {
                snippetExpansionCard(template: raw)
            }
        }
    }

    @ViewBuilder
    private func codeView(raw: String, language: SyntaxHighlighter.Language) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isCompact {
                Text(language.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            let attr = SyntaxHighlighter.attributedString(
                for: raw,
                language: language,
                font: .monospacedSystemFont(ofSize: isCompact ? 10 : 12, weight: .regular)
            )
            ScrollView {
                CodeView(attributed: attr)
                    .frame(maxWidth: .infinity, minHeight: isCompact ? 100 : 200, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func markdownView(raw: String) -> some View {
        ScrollView {
            if let attr = try? AttributedString(
                markdown: raw,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            ) {
                Text(attr)
                    .font(isCompact ? .caption : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(raw)
                    .font(PastyTheme.monoFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - RichText

    @ViewBuilder
    private func richTextView() -> some View {
        if let raw = clip.content,
           let data = raw.data(using: .utf8),
           let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            ScrollView {
                CodeView(attributed: attr)
                    .frame(maxWidth: .infinity, minHeight: isCompact ? 100 : 200, alignment: .topLeading)
            }
        } else {
            plainTextView(raw: clip.content ?? clip.preview)
        }
    }

    // MARK: - Image

    @ViewBuilder
    private func imageView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = clip.dataPath,
               let img = ImageBlobCache.shared.image(for: p) {
                GeometryReader { proxy in
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous))
                }
                if !isCompact {
                    HStack(spacing: 6) {
                        Text(formattedBytes(clip.byteSize))
                        Text("·")
                        Text("\(Int(img.size.width)) × \(Int(img.size.height))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                placeholderView(systemName: "photo", title: "画像を読み込めません")
            }
        }
    }

    // MARK: - File

    @ViewBuilder
    private func fileView() -> some View {
        let name = clip.preview
        let path = clip.dataPath.map { ClipBlobs.blobURL(for: $0).path } ?? "—"

        VStack(alignment: .leading, spacing: isCompact ? 6 : 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: isCompact ? 36 : 56, height: isCompact ? 36 : 56)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(isCompact ? PastyTheme.subtitleFont : PastyTheme.titleFont)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(formattedBytes(clip.byteSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !isCompact {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Link

    @ViewBuilder
    private func linkView() -> some View {
        let raw = (clip.content ?? clip.preview).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: raw)

        VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
            if let meta = linkMeta {
                HStack(spacing: 8) {
                    if let favicon = meta.faviconURL {
                        AsyncImage(url: favicon) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fit)
                            default:
                                Image(systemName: "globe")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                    }
                    Text(meta.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let title = meta.title, !title.isEmpty {
                    Text(title)
                        .font(isCompact ? PastyTheme.subtitleFont : PastyTheme.titleFont)
                        .lineLimit(isCompact ? 2 : 4)
                        .textSelection(.enabled)
                }
            } else if linkLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("リンク情報を取得中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(raw)
                .font(isCompact ? .caption.monospaced() : PastyTheme.monoFont)
                .foregroundStyle(.tint)
                .lineLimit(isCompact ? 3 : nil)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if !isCompact, let url = url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("ブラウザで開く", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Color

    @ViewBuilder
    private func colorView() -> some View {
        let hex = (clip.content ?? clip.preview).trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                .fill(Color(hex: hex))
                .frame(maxWidth: .infinity, minHeight: isCompact ? 80 : 140)
                .overlay(
                    RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            Text(hex.uppercased())
                .font(PastyTheme.monoFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Snippet expansion card

    @ViewBuilder
    private func snippetExpansionCard(template: String) -> some View {
        let expanded = SnippetEngine.expand(template).text
        if expanded != template {
            VStack(alignment: .leading, spacing: 4) {
                Text("展開後プレビュー")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(expanded)
                    .font(PastyTheme.monoFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editorView(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(PastyTheme.monoFont)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var editingControls: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                onCancel?()
                isEditing?.wrappedValue = false
            } label: {
                Text("キャンセル")
                Text("Esc")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .keyboardShortcut(.cancelAction)

            Button {
                onSave?()
                isEditing?.wrappedValue = false
            } label: {
                Text("保存")
                Text("⌘↵")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
        }
        .font(.caption)
    }

    // MARK: - Link metadata loader

    private func loadLinkMetaIfNeeded() async {
        guard clip.kind == .link, !isCompact else { return }
        let raw = (clip.content ?? clip.preview).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else { return }
        linkLoading = true
        defer { linkLoading = false }
        let fetched = await LinkMetadataFetcher.shared.fetch(url: url)
        linkMeta = fetched
    }

    // MARK: - Helpers

    private func placeholderView(systemName: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: isCompact ? 24 : 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB, .useBytes]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    private func formattedCount(_ count: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func relativeDate(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        fmt.locale = Locale(identifier: "ja_JP")
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func shortenURL(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        return host
    }
}

// MARK: - Meta chips flow layout

/// メタバーに並べる小さなテキスト群を「横に並べきれない時は折り返す」
/// シンプルな flow レイアウト。SwiftUI 標準の `Layout` を採用。
private struct MetaChipsFlow: View {
    let chips: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Text(chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                widestRow = max(widestRow, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widestRow = max(widestRow, x - spacing)
        return CGSize(width: widestRow, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        let maxX = bounds.maxX

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
