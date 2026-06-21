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
///
/// v0.9.5 additions (B9):
/// - Persistent counters: `{{counter:name}}`, `{{counter:name|format:%04d}}`,
///   `{{counter:name|reset}}` — backed by `SettingsStore.snippetCounters`.
/// - Block conditionals: `{{if hasField name}}...{{endif}}` and
///   `{{if equals var "val"}}...{{endif}}`. Non-nested; pre-processed before
///   the variable expansion passes so the inner body can use any placeholder.
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

    /// Block conditional pattern: `{{if PRED ARG ("VAL")?}}...{{endif}}`.
    /// Non-nested by design — the inner body is captured non-greedily so the
    /// first `{{endif}}` closes the nearest `{{if}}`.
    static let ifBlockPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"\{\{\s*if\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+([a-zA-Z_][a-zA-Z0-9_]*)(?:\s+\"([^\"]*)\")?\s*\}\}([\s\S]*?)\{\{\s*endif\s*\}\}"#,
        options: []
    )

    /// Counter pattern inside a legacy `{{counter:NAME[|MOD[:ARG]]...}}` token.
    /// Captures (1) counter name, (2) optional pipeline tail starting with `|`.
    static let counterArgPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([a-zA-Z_][a-zA-Z0-9_]*)((?:\s*\|\s*[^}]+)*)$"#,
        options: []
    )

    /// Primary entry point. `fields` carries mail-merge field values supplied
    /// by the user (used by `{{if hasField NAME}}` and also exposed as
    /// custom variables so `{{NAME}}` resolves through them). `customVariables`
    /// is for non-mail-merge user-defined vars; if both maps contain the same
    /// key, `customVariables` wins.
    static func expand(_ template: String,
                       fields: [String: String],
                       customVariables: [String: String] = [:]) -> ExpansionResult {
        // Build the lookup map used by `resolve` and by `if` predicates.
        // customVariables overrides fields on key collision so callers can
        // explicitly inject computed values.
        var merged = fields
        for (k, v) in customVariables { merged[k] = v }

        var output = template

        // Pass 0: collapse `{{if ...}}...{{endif}}` blocks first. Both true
        // and false branches are decided here so subsequent passes only see
        // the surviving body.
        output = expandIfBlocks(in: output, fields: fields, customVariables: customVariables)

        var cursorIndex: Int? = nil

        // Resolve `{{cursor}}` next — record its position relative to the
        // *expanded* string so callers can drop the IME cursor there.
        if let r = output.range(of: "{{cursor}}") {
            let prefix = String(output[..<r.lowerBound])
            cursorIndex = prefix.count
            output.removeSubrange(r)
        }

        // First expansion pass: pipeline syntax `{{var | mod1 | mod2:arg}}`.
        // We run this before the legacy pattern so that pipeline tokens
        // (which contain `|`) are consumed first and don't get mis-parsed.
        output = expandPipelineTokens(in: output, customVariables: merged)

        // Second expansion pass: legacy `{{var}}` and `{{var:arg}}`.
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
            let value = resolve(variable: name, argument: arg, custom: merged)
            mutated = mutatedNS.replacingCharacters(in: m.range, with: value)
        }
        output = mutated

        return ExpansionResult(text: output, cursorIndex: cursorIndex)
    }

    /// Back-compat overload — pre-B9 callers that don't supply `fields`.
    static func expand(_ template: String,
                       customVariables: [String: String] = [:]) -> ExpansionResult {
        return expand(template, fields: [:], customVariables: customVariables)
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
        case "counter":
            // `{{counter:name}}`, `{{counter:name|format:%04d}}`,
            // `{{counter:name|reset}}` etc. The legacy `:arg` group carries
            // the counter name and (optionally) a `|`-separated modifier
            // chain. Pipeline-pattern syntax `{{counter | format:%04d}}`
            // without a name is intentionally unsupported — counter needs an
            // identifier.
            guard let raw = argument, !raw.isEmpty else { return "" }
            return resolveCounter(rawArgument: raw)
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

// MARK: - B9: counter resolution

extension SnippetEngine {

    /// Parses the argument string of a `{{counter:NAME[|MOD[:ARG]]...}}` token
    /// and routes to the underlying counter store. Returns the formatted
    /// counter value (or empty for `reset`).
    fileprivate static func resolveCounter(rawArgument: String) -> String {
        let ns = rawArgument as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard let m = counterArgPattern.firstMatch(in: rawArgument, range: fullRange),
              m.range(at: 1).location != NSNotFound else {
            // Malformed (e.g. `{{counter:}}` or whitespace-only) — degrade
            // gracefully to empty so the user notices a missing increment
            // rather than seeing a literal placeholder leak through.
            return ""
        }
        let name = ns.substring(with: m.range(at: 1))
        let tailRange = m.range(at: 2)
        let tail: String
        if tailRange.location != NSNotFound, tailRange.length > 0 {
            tail = ns.substring(with: tailRange)
        } else {
            tail = ""
        }

        let modifiers: [String] = tail
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // `reset` short-circuits: zero the counter, return empty. We honour
        // a leading `reset` modifier; any further modifiers in the same chain
        // are ignored because the counter no longer has a numeric value to
        // format.
        if modifiers.first?.lowercased() == "reset" {
            CounterStore.shared.reset(name)
            return ""
        }

        let value = CounterStore.shared.incrementAndGet(name)

        // Apply remaining modifiers (currently only `format:<fmt>` is counter-
        // specific; chain through the regular modifier table for everything
        // else so users can mix in `uppercase` etc. if they ever want to).
        var rendered = String(value)
        for mod in modifiers {
            if let colon = mod.firstIndex(of: ":") {
                let modName = String(mod[..<colon]).trimmingCharacters(in: .whitespaces)
                let modArg = String(mod[mod.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if modName.lowercased() == "format" {
                    rendered = formatCounter(value: value, format: modArg)
                } else {
                    rendered = applyModifier(modName, to: rendered, arg: modArg)
                }
            } else {
                rendered = applyModifier(mod, to: rendered, arg: nil)
            }
        }
        return rendered
    }

    /// `String(format:)` wrapper that survives bogus user input. We accept
    /// printf-style integer specifiers (`%d`, `%04d`, `%05d`, `%x`, ...). For
    /// anything else, fall back to the bare integer rendering rather than
    /// crashing on an invalid format string.
    fileprivate static func formatCounter(value: Int, format: String) -> String {
        guard !format.isEmpty else { return String(value) }
        // Cheap sanity check: must contain a `%` conversion. Anything missing
        // one would silently swallow the value.
        guard format.contains("%") else { return String(value) }
        return String(format: format, value)
    }
}

/// Persistent counter backing for `{{counter:name}}`. Wraps
/// `SettingsStore.snippetCounters` so the snippet engine doesn't have to
/// reach into `@MainActor` state directly from non-main contexts.
///
/// All current callers (`PasteAutomator`, `ClipPreviewView`,
/// `TemplateFieldDialog`) are already on the main actor so we hop through
/// `MainActor.assumeIsolated`. If a future caller invokes `SnippetEngine`
/// from a background thread, the runtime check will trap and signal that
/// the call needs to be marshalled to the main thread first.
fileprivate enum CounterStore {
    enum shared {
        static func incrementAndGet(_ name: String) -> Int {
            return MainActor.assumeIsolated {
                let store = SettingsStore.shared
                let current = store.snippetCounters[name] ?? 0
                let next = current &+ 1
                var updated = store.snippetCounters
                updated[name] = next
                store.snippetCounters = updated
                return next
            }
        }

        static func reset(_ name: String) {
            MainActor.assumeIsolated {
                let store = SettingsStore.shared
                var updated = store.snippetCounters
                updated[name] = 0
                store.snippetCounters = updated
            }
        }
    }
}

// MARK: - B9: block conditional resolution

extension SnippetEngine {

    /// Walks `{{if PRED ARG ("VAL")?}}...{{endif}}` blocks back-to-front and
    /// replaces each with either the inner body (predicate true) or the empty
    /// string (predicate false). Non-nested by design — the regex captures
    /// the body non-greedily so the *first* `{{endif}}` closes the block.
    fileprivate static func expandIfBlocks(in template: String,
                                           fields: [String: String],
                                           customVariables: [String: String]) -> String {
        var output = template
        let ns = output as NSString
        let matches = ifBlockPattern.matches(in: output, range: NSRange(location: 0, length: ns.length))

        for m in matches.reversed() {
            let currentNS = output as NSString
            guard m.range.location + m.range.length <= currentNS.length else { continue }

            let predRange = m.range(at: 1)
            let targetRange = m.range(at: 2)
            let valRange = m.range(at: 3)
            let bodyRange = m.range(at: 4)

            guard predRange.location != NSNotFound,
                  targetRange.location != NSNotFound,
                  bodyRange.location != NSNotFound else { continue }

            let predicate = currentNS.substring(with: predRange).lowercased()
            let target = currentNS.substring(with: targetRange)
            let comparand: String? = (valRange.location != NSNotFound)
                ? currentNS.substring(with: valRange)
                : nil
            let body = currentNS.substring(with: bodyRange)

            let truthy = evaluatePredicate(predicate: predicate,
                                           target: target,
                                           comparand: comparand,
                                           fields: fields,
                                           customVariables: customVariables)
            let replacement = truthy ? body : ""
            output = currentNS.replacingCharacters(in: m.range, with: replacement)
        }

        return output
    }

    /// Evaluates an `if`-block predicate.
    /// - `hasField NAME` → true iff `fields[NAME]` (or `customVariables[NAME]`)
    ///   is present and non-empty after trimming whitespace.
    /// - `equals VAR "VAL"` → true iff `VAR` resolves to `VAL` exactly.
    ///   `VAR` is looked up first in `customVariables`, then `fields`, then
    ///   the builtin resolver (so `equals user "alice"` works too).
    /// Unknown predicates evaluate to false (fail-closed) so a typo doesn't
    /// silently include sensitive content.
    fileprivate static func evaluatePredicate(predicate: String,
                                              target: String,
                                              comparand: String?,
                                              fields: [String: String],
                                              customVariables: [String: String]) -> Bool {
        switch predicate {
        case "hasfield":
            // Prefer fields (the mail-merge contract) but also honour
            // customVariables so callers that route values that way still
            // satisfy `hasField`.
            if let v = fields[target], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            if let v = customVariables[target], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return false
        case "equals":
            guard let expected = comparand else { return false }
            var merged = fields
            for (k, v) in customVariables { merged[k] = v }
            // Use the same resolver path so builtins (`user`, `host`, ...)
            // are reachable too.
            let actual = resolve(variable: target, argument: nil, custom: merged)
            return actual == expected
        default:
            return false
        }
    }
}
