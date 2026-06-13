import SwiftUI
import AppKit

// 各 enum (RewriteTone, TranslateTarget, SummaryLength, ReformatTarget, AIAction)
// は AIEngine.swift に正式定義あり。ここでは UI ラベルだけ extension で追加。

extension RewriteTone: Identifiable {
    public var id: String { rawValue }
    var japaneseLabel: String {
        switch self {
        case .formal:   return "フォーマル"
        case .casual:   return "カジュアル"
        case .friendly: return "フレンドリー"
        case .concise:  return "簡潔に"
        }
    }
}

extension TranslateTarget: Identifiable {
    public var id: String { rawValue }
    var japaneseLabel: String {
        switch self {
        case .auto:              return "自動判定"
        case .japanese:          return "日本語"
        case .english:           return "英語"
        case .korean:            return "韓国語"
        case .chineseSimplified: return "中国語（簡体）"
        }
    }
}

extension SummaryLength: Identifiable {
    public var id: String { rawValue }
    var japaneseLabel: String {
        switch self {
        case .short:  return "短め（1行）"
        case .medium: return "標準（数行）"
        case .long:   return "長め（段落）"
        }
    }
}

extension ReformatTarget: Identifiable {
    public var id: String { rawValue }
    var japaneseLabel: String {
        switch self {
        case .markdownToHTML: return "Markdown → HTML"
        case .htmlToMarkdown: return "HTML → Markdown"
        case .jsonPretty:     return "JSON 整形"
        case .plainText:      return "プレーンテキスト化"
        case .slugify:        return "slug 化"
        }
    }
}

extension AIAction: Identifiable {
    public var id: String {
        switch self {
        case .rewrite(let tone):      return "rewrite.\(tone.rawValue)"
        case .translate(let target):  return "translate.\(target.rawValue)"
        case .summarize(let length):  return "summarize.\(length.rawValue)"
        case .reformat(let target):   return "reformat.\(target.rawValue)"
        case .emailify:               return "emailify"
        }
    }

    public var label: String {
        switch self {
        case .rewrite(let tone):     return "書き直し（\(tone.japaneseLabel)）"
        case .translate(let target): return "翻訳（\(target.japaneseLabel)）"
        case .summarize(let length): return "要約（\(length.japaneseLabel)）"
        case .reformat(let target):  return "変換: \(target.japaneseLabel)"
        case .emailify:              return "メール風に整形"
        }
    }

    public var systemImage: String {
        switch self {
        case .rewrite:   return "pencil.and.outline"
        case .translate: return "character.bubble"
        case .summarize: return "text.append"
        case .reformat:  return "arrow.triangle.2.circlepath"
        case .emailify:  return "envelope"
        }
    }

    public var keyHint: String? {
        switch self {
        case .rewrite(let tone):
            switch tone {
            case .formal:   return "⌃⇧F"
            case .casual:   return "⌃⇧C"
            case .friendly: return "⌃⇧R"
            case .concise:  return "⌃⇧S"
            }
        case .translate(let target):
            switch target {
            case .auto:              return "⌃⇧T"
            case .japanese:          return "⌃⇧J"
            case .english:           return "⌃⇧E"
            case .korean:            return nil
            case .chineseSimplified: return nil
            }
        case .summarize(let length):
            switch length {
            case .short:  return "⌃⇧U"
            case .medium: return nil
            case .long:   return nil
            }
        case .reformat(let target):
            switch target {
            case .markdownToHTML: return "⌃⇧H"
            case .htmlToMarkdown: return "⌃⇧M"
            case .jsonPretty:     return "⌃⇧P"
            case .plainText:      return nil
            case .slugify:        return nil
            }
        case .emailify:
            return "⌃⇧L"
        }
    }
}

// MARK: - Section model

private struct AIActionSection: Identifiable {
    let id: String
    let title: String
    let actions: [AIAction]
}

private let aiActionSections: [AIActionSection] = [
    AIActionSection(
        id: "rewrite",
        title: "書き直し",
        actions: RewriteTone.allCases.map { .rewrite(tone: $0) }
    ),
    AIActionSection(
        id: "translate",
        title: "翻訳",
        actions: TranslateTarget.allCases.map { .translate(target: $0) }
    ),
    AIActionSection(
        id: "summarize",
        title: "要約",
        actions: SummaryLength.allCases.map { .summarize(length: $0) }
    ),
    AIActionSection(
        id: "reformat",
        title: "フォーマット変換",
        actions: ReformatTarget.allCases.map { .reformat(to: $0) }
    ),
    AIActionSection(
        id: "emailify",
        title: "メール風整形",
        actions: [.emailify]
    ),
]

private let flattenedActions: [AIAction] = aiActionSections.flatMap(\.actions)

// MARK: - AIActionMenu

@MainActor
struct AIActionMenu: View {
    let clip: ClipItem
    let onSelect: (AIAction) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(aiActionSections.enumerated()), id: \.element.id) { _, section in
                                sectionView(section)
                            }
                        }
                        .padding(.horizontal, PastyTheme.panelPadding)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        guard flattenedActions.indices.contains(newValue) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(flattenedActions[newValue].id, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 360)
            .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
            )

            keyHandler
        }
        .frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI アクション")
                    .font(PastyTheme.titleFont)
                Text(headerSubtitle)
                    .font(PastyTheme.subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text("Esc で閉じる")
                .font(PastyTheme.subtitleFont)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, PastyTheme.panelPadding)
        .padding(.vertical, 10)
    }

    private var headerSubtitle: String {
        let trimmed = clip.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "選択中のクリップ"
        }
        let max = 48
        if trimmed.count > max {
            let head = trimmed.prefix(max)
            return "対象: \(head)…"
        }
        return "対象: \(trimmed)"
    }

    // MARK: - Section view

    private func sectionView(_ section: AIActionSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(PastyTheme.subtitleFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 2)

            ForEach(section.actions, id: \.id) { action in
                let globalIndex = flattenedActions.firstIndex(of: action) ?? 0
                row(for: action, isSelected: globalIndex == selectedIndex)
                    .id(action.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedIndex = globalIndex
                        onSelect(action)
                    }
            }
        }
    }

    // MARK: - Row

    private func row(for action: AIAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.systemImage)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 18, alignment: .center)
                .foregroundStyle(isSelected ? Color.white : Color.primary)

            Text(action.label)
                .font(PastyTheme.titleFont)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if let hint = action.keyHint {
                Text(hint)
                    .font(PastyTheme.subtitleFont.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected
                                  ? Color.white.opacity(0.18)
                                  : Color.primary.opacity(0.07))
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }

    // MARK: - Key handling

    private var keyHandler: some View {
        KeyHandlingView(
            onUp:   { moveSelection(-1) },
            onDown: { moveSelection(+1) },
            onReturn: { activateSelection() },
            onEsc:  { onDismiss() }
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private func moveSelection(_ delta: Int) {
        guard !flattenedActions.isEmpty else { return }
        let count = flattenedActions.count
        let next = (selectedIndex + delta + count) % count
        selectedIndex = next
    }

    private func activateSelection() {
        guard flattenedActions.indices.contains(selectedIndex) else { return }
        onSelect(flattenedActions[selectedIndex])
    }
}
