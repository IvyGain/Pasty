import Foundation
import AppKit
import SwiftUI

/// Minimal but useful regex-based highlighter for previewing clips. We
/// intentionally do **not** ship Tree-sitter for v0.1 — `Highlightr` /
/// `Splash` raise binary size by ~10 MB and complicate offline OSS builds.
/// This is good enough for "Pasty has syntax colours" while we wait for
/// a lean Swift highlighter to mature.
enum SyntaxHighlighter {
    enum Language: String {
        case plain, swift, python, json, markdown, html, javascript, shell
    }

    static func attributedString(for code: String,
                                 language: Language,
                                 font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )
        for rule in rules(for: language) {
            rule.apply(to: base)
        }
        return base
    }

    // v0.9.6-beta P1 #3: precompile the regex set per language at type-load
    // time. Hot-path callers (preview rendering on every keystroke / scroll)
    // now reuse the same `NSRegularExpression` instances instead of paying
    // `try!` on each invocation.
    private static let swiftRules: [Rule] = [
        Rule(pattern: #"\b(let|var|func|class|struct|enum|extension|protocol|import|return|if|else|guard|for|in|while|switch|case|break|continue|defer|do|try|catch|throw|throws|public|private|internal|static|final|some|any|where|init|deinit|self|super|true|false|nil)\b"#, color: .systemPink),
        Rule(pattern: #""([^"\\]|\\.)*""#, color: .systemRed),
        Rule(pattern: #"//[^\n]*"#, color: .systemGray),
        Rule(pattern: #"\b[0-9]+(?:\.[0-9]+)?\b"#, color: .systemOrange),
    ]

    private static let pythonRules: [Rule] = [
        Rule(pattern: #"\b(def|class|return|if|elif|else|for|while|in|import|from|as|with|try|except|raise|pass|None|True|False|lambda|yield|await|async)\b"#, color: .systemPink),
        Rule(pattern: #"#[^\n]*"#, color: .systemGray),
        Rule(pattern: #"'([^'\\]|\\.)*'|"([^"\\]|\\.)*""#, color: .systemRed),
        Rule(pattern: #"\b[0-9]+\b"#, color: .systemOrange),
    ]

    private static let jsonRules: [Rule] = [
        Rule(pattern: #""([^"\\]|\\.)*"\s*:"#, color: .systemBlue),
        Rule(pattern: #":\s*"([^"\\]|\\.)*""#, color: .systemRed),
        Rule(pattern: #"\b(true|false|null)\b"#, color: .systemPink),
        Rule(pattern: #"\b-?[0-9]+(?:\.[0-9]+)?\b"#, color: .systemOrange),
    ]

    private static let markdownRules: [Rule] = [
        Rule(pattern: #"^#{1,6}\s.*$"#, color: .systemPurple, options: [.anchorsMatchLines]),
        Rule(pattern: #"\*\*[^*]+\*\*"#, color: .systemPink),
        Rule(pattern: #"`[^`]+`"#, color: .systemRed),
        Rule(pattern: #"\[[^\]]+\]\([^)]+\)"#, color: .systemBlue),
    ]

    private static let htmlRules: [Rule] = [
        Rule(pattern: #"</?[a-zA-Z][a-zA-Z0-9]*(?:\s[^>]*)?>"#, color: .systemPink),
        Rule(pattern: #"\b[a-zA-Z-]+="([^"]*)""#, color: .systemBlue),
        Rule(pattern: #"<!--[\s\S]*?-->"#, color: .systemGray),
    ]

    private static let javascriptRules: [Rule] = [
        Rule(pattern: #"\b(const|let|var|function|return|if|else|for|while|switch|case|break|continue|class|extends|new|this|super|true|false|null|undefined|async|await|import|from|export|default)\b"#, color: .systemPink),
        Rule(pattern: #"//[^\n]*"#, color: .systemGray),
        Rule(pattern: #""([^"\\]|\\.)*"|'([^'\\]|\\.)*'|`([^`\\]|\\.)*`"#, color: .systemRed),
        Rule(pattern: #"\b[0-9]+(?:\.[0-9]+)?\b"#, color: .systemOrange),
    ]

    private static let shellRules: [Rule] = [
        Rule(pattern: #"^\s*#[^\n]*"#, color: .systemGray, options: [.anchorsMatchLines]),
        Rule(pattern: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, color: .systemBlue),
        Rule(pattern: #""([^"\\]|\\.)*"|'[^']*'"#, color: .systemRed),
    ]

    private static func rules(for lang: Language) -> [Rule] {
        switch lang {
        case .plain:      return []
        case .swift:      return swiftRules
        case .python:     return pythonRules
        case .json:       return jsonRules
        case .markdown:   return markdownRules
        case .html:       return htmlRules
        case .javascript: return javascriptRules
        case .shell:      return shellRules
        }
    }

    static func detect(from text: String) -> Language {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return .json }
        if trimmed.contains("def ") && trimmed.contains(":") { return .python }
        if trimmed.contains("func ") || trimmed.contains("@objc") { return .swift }
        if trimmed.hasPrefix("#") || trimmed.contains("\n# ") { return .markdown }
        if trimmed.contains("<html") || trimmed.contains("<div") { return .html }
        if trimmed.contains("=>") || trimmed.contains("const ") { return .javascript }
        if trimmed.hasPrefix("#!/") || trimmed.contains("echo ") { return .shell }
        return .plain
    }

    private struct Rule {
        let regex: NSRegularExpression
        let color: NSColor

        init(pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.color = color
        }

        func apply(to s: NSMutableAttributedString) {
            let range = NSRange(location: 0, length: s.length)
            regex.enumerateMatches(in: s.string, range: range) { match, _, _ in
                if let r = match?.range {
                    s.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
        }
    }
}

/// SwiftUI wrapper for rendering an `NSAttributedString` of code.
struct CodeView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainer?.lineFragmentPadding = 4
        return view
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        nsView.textStorage?.setAttributedString(attributed)
    }
}
