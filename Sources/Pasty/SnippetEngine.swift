import Foundation
import AppKit
import CryptoKit

/// Expands `{{var}}` placeholders inside a clip's content before pasting.
/// Built-in variables: `date`, `time`, `iso`, `user`, `host`, `uuid`,
/// `clipboard`, `cursor`. Custom variables can be added via SettingsStore.
///
/// v0.4.1 additions:
/// - Pipeline modifiers: `{{var | mod1 | mod2:arg}}`
/// - Mail-merge placeholders: `[[name]]`
enum SnippetEngine {
    static let pattern = try! NSRegularExpression(
        pattern: #"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)(?::([^}]*))?\s*\}\}"#,
        options: []
    )

    /// New pipeline pattern recognising `{{var | mod1 | mod2:arg}}`.
    static let pipelinePattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)((?:\s*\|\s*[^}]+)+)\s*\}\}"#,
        options: []
    )

    /// Mail-merge placeholder pattern: `[[fieldName]]`.
    static let mailMergePattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"\[\[\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\]\]"#,
        options: []
    )

    static func expand(_ template: String,
                       customVariables: [String: String] = [:]) -> ExpansionResult {
        var output = template
        var cursorIndex: Int? = nil

        // Resolve `{{cursor}}` first — record its position relative to the
        // *expanded* string so callers can drop the IME cursor there.
        if let r = output.range(of: "{{cursor}}") {
            let prefix = String(output[..<r.lowerBound])
            cursorIndex = prefix.count
            output.removeSubrange(r)
        }

        // First pass: handle pipeline syntax `{{var | mod1 | mod2:arg}}`.
        // We run this before the legacy pattern so that pipeline tokens
        // (which contain `|`) are consumed first and don't get mis-parsed.
        output = expandPipelineTokens(in: output, customVariables: customVariables)

        // Second pass: legacy `{{var}}` and `{{var:arg}}` placeholders.
        let ns = output as NSString
        let matches = pattern.matches(in: output, range: NSRange(location: 0, length: ns.length))

        // Walk matches back-to-front so ranges remain stable as we mutate.
        var mutated = output
        for m in matches.reversed() {
            let nameRange = m.range(at: 1)
            let argRange = m.range(at: 2)
            let mutatedNS = mutated as NSString
            let name = mutatedNS.substring(with: nameRange)
            let arg: String? = argRange.location != NSNotFound ? mutatedNS.substring(with: argRange) : nil
            let value = resolve(variable: name, argument: arg, custom: customVariables)
            mutated = mutatedNS.replacingCharacters(in: m.range, with: value)
        }
        output = mutated

        return ExpansionResult(text: output, cursorIndex: cursorIndex)
    }

    static func resolve(variable: String, argument: String?, custom: [String: String]) -> String {
        switch variable.lowercased() {
        case "date":
            let f = DateFormatter()
            f.dateFormat = argument ?? "yyyy-MM-dd"
            return f.string(from: Date())
        case "time":
            let f = DateFormatter()
            f.dateFormat = argument ?? "HH:mm:ss"
            return f.string(from: Date())
        case "iso":
            return ISO8601DateFormatter().string(from: Date())
        case "user":
            return NSUserName()
        case "host":
            return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        case "uuid":
            return UUID().uuidString
        case "clipboard":
            return NSPasteboard.general.string(forType: .string) ?? ""
        default:
            return custom[variable] ?? argument ?? "{{\(variable)}}"
        }
    }
}

// MARK: - Pipeline (modifier chain) support

extension SnippetEngine {

    /// Expands every `{{var | mod1 | mod2:arg}}` occurrence in `template`.
    /// Tokens without a `|` are left alone so the legacy `pattern` can handle them.
    fileprivate static func expandPipelineTokens(in template: String,
                                                 customVariables: [String: String]) -> String {
        var output = template
        let ns = output as NSString
        let matches = pipelinePattern.matches(in: output, range: NSRange(location: 0, length: ns.length))

        // Walk back-to-front for stable ranges.
        for m in matches.reversed() {
            let currentNS = output as NSString
            // Defensive bounds check — string mutations between iterations can
            // (in theory) invalidate ranges; we skip any match that no longer fits.
            guard m.range.location + m.range.length <= currentNS.length else { continue }

            let nameRange = m.range(at: 1)
            let pipeRange = m.range(at: 2)

            guard nameRange.location != NSNotFound,
                  nameRange.location + nameRange.length <= currentNS.length else { continue }

            let name = currentNS.substring(with: nameRange)

            // Pipeline group is non-optional in the regex, but guard anyway.
            let pipelineRaw: String
            if pipeRange.location != NSNotFound,
               pipeRange.location + pipeRange.length <= currentNS.length {
                pipelineRaw = currentNS.substring(with: pipeRange)
            } else {
                pipelineRaw = ""
            }

            // Resolve the base value (no `:arg` here — pipeline syntax does
            // not overlap with the legacy colon argument form).
            let baseValue = resolve(variable: name, argument: nil, custom: customVariables)

            // Parse the modifier chain. `pipelineRaw` starts with `|`.
            let modifiers = pipelineRaw
                .split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            var transformed = baseValue
            for mod in modifiers {
                // `lines:5` → name=lines, arg=5
                if let colonIdx = mod.firstIndex(of: ":") {
                    let modName = String(mod[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let modArg = String(mod[mod.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    transformed = applyModifier(modName, to: transformed, arg: modArg)
                } else {
                    transformed = applyModifier(mod, to: transformed, arg: nil)
                }
            }

            output = (output as NSString).replacingCharacters(in: m.range, with: transformed)
        }

        return output
    }

    /// Applies a single built-in modifier to `value`.
    /// Unknown modifiers return the value unchanged.
    static func applyModifier(_ name: String, to value: String, arg: String? = nil) -> String {
        switch name.lowercased() {
        case "uppercase":
            return value.uppercased()
        case "lowercase":
            return value.lowercased()
        case "capitalize":
            return value.capitalized
        case "trim":
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case "reverse":
            return String(value.reversed())
        case "base64":
            return Data(value.utf8).base64EncodedString()
        case "url":
            return value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        case "escape":
            return value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        case "slugify":
            let lowered = value.lowercased()
            // Keep letters, digits, whitespace, hyphens; drop everything else.
            let stripped = lowered.unicodeScalars.filter {
                CharacterSet.letters.contains($0)
                    || CharacterSet.decimalDigits.contains($0)
                    || CharacterSet.whitespacesAndNewlines.contains($0)
                    || $0 == "-"
            }
            let normalized = String(String.UnicodeScalarView(stripped))
            let parts = normalized.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            return parts.joined(separator: "-")
        case "md5":
            return md5Hex(value)
        case "lines":
            if let raw = arg, let n = Int(raw), n >= 0 {
                let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
                return lines.prefix(n).joined(separator: "\n")
            }
            return value
        default:
            return value
        }
    }

    /// MD5 hex digest using CryptoKit's `Insecure.MD5`.
    /// Note: MD5 is cryptographically broken; used here only for snippet
    /// templating convenience (e.g. gravatar-style hashes).
    fileprivate static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Mail-merge support

extension SnippetEngine {

    /// Extracts every `[[name]]` placeholder in declaration order.
    /// Duplicate names are deduplicated while preserving first-seen order.
    static func parseMailMergeFields(_ template: String) -> [String] {
        let ns = template as NSString
        let matches = mailMergePattern.matches(in: template, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var ordered: [String] = []
        for m in matches {
            let nameRange = m.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let name = ns.substring(with: nameRange)
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    /// Replaces each `[[name]]` with `values[name]` (or empty if missing).
    /// `{{...}}` placeholders are left untouched so callers can run
    /// `applyMailMergeValues` first and `expand` second.
    static func applyMailMergeValues(_ template: String, values: [String: String]) -> String {
        var output = template
        let ns = output as NSString
        let matches = mailMergePattern.matches(in: output, range: NSRange(location: 0, length: ns.length))

        // Walk back-to-front so ranges stay valid as we mutate.
        for m in matches.reversed() {
            let currentNS = output as NSString
            guard m.range.location + m.range.length <= currentNS.length else { continue }
            let nameRange = m.range(at: 1)
            guard nameRange.location != NSNotFound,
                  nameRange.location + nameRange.length <= currentNS.length else { continue }

            let name = currentNS.substring(with: nameRange)
            let replacement = values[name] ?? ""
            output = currentNS.replacingCharacters(in: m.range, with: replacement)
        }
        return output
    }
}

struct ExpansionResult: Equatable {
    let text: String
    let cursorIndex: Int?
}
