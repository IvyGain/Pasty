import Foundation
import AppKit
#if canImport(Vision)
import Vision
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Public action types

/// An on-device AI action that can be performed on a piece of clipboard text.
public enum AIAction: Equatable {
    case rewrite(tone: RewriteTone)
    case translate(target: TranslateTarget)
    case summarize(length: SummaryLength)
    case reformat(to: ReformatTarget)
    case emailify
}

/// Tone used by ``AIAction/rewrite(tone:)``.
public enum RewriteTone: String, CaseIterable, Equatable {
    case formal
    case casual
    case friendly
    case concise
}

/// Target language for ``AIAction/translate(target:)``. `auto` swaps between
/// Japanese and English based on the input's detected language.
public enum TranslateTarget: String, CaseIterable, Equatable {
    case auto
    case japanese
    case english
    case korean
    case chineseSimplified
}

/// Summary length used by ``AIAction/summarize(length:)``.
public enum SummaryLength: String, CaseIterable, Equatable {
    case short
    case medium
    case long
}

/// Reformat output target used by ``AIAction/reformat(to:)``.
public enum ReformatTarget: String, CaseIterable, Equatable {
    case markdownToHTML
    case htmlToMarkdown
    case jsonPretty
    case plainText
    case slugify
}

/// Result envelope returned by ``AIEngine/perform(_:on:)``.
public struct AIResult: Equatable {
    public let text: String
    public let backend: Backend

    public enum Backend: String, Equatable {
        case foundationModels
        case naturalLanguage
        case heuristic
    }

    public init(text: String, backend: Backend) {
        self.text = text
        self.backend = backend
    }
}

/// Errors raised by ``AIEngine/perform(_:on:)``.
public enum AIEngineError: LocalizedError {
    case modelUnavailable
    case requestFailed(underlying: Error)
    case invalidInput

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Apple Intelligence (Foundation Models) is not available on this Mac. Requires macOS 26+ with Apple Intelligence enabled."
        case .requestFailed(let error):
            return "AI request failed: \(error.localizedDescription)"
        case .invalidInput:
            return "The input text is empty or invalid."
        }
    }
}

/// v0.9.6-beta (P1 #10): UI 層から `switch` で分岐できる typed error。
/// `AIEngineError` を吸収して 4 つの代表ケースに集約する。
public enum AIError: Error {
    case modelNotAvailable
    case osUnsupported
    case aiDisabledBySettings
    case other(Error)

    /// 既存の `AIEngineError` / 任意の `Error` を `AIError` にマップする。
    /// 呼び出し側は `catch let e as AIError` か、`AIError.from(error)` を使う。
    public static func from(_ error: Error) -> AIError {
        if let aiErr = error as? AIError { return aiErr }
        if let engineErr = error as? AIEngineError {
            switch engineErr {
            case .modelUnavailable:
                // macOS 26 未満なら OS 不一致、それ以外なら model unavailable。
                if #available(macOS 26.0, *) {
                    return .modelNotAvailable
                } else {
                    return .osUnsupported
                }
            case .requestFailed(let underlying):
                return .other(underlying)
            case .invalidInput:
                return .other(engineErr)
            }
        }
        return .other(error)
    }
}

// MARK: - OCR concurrency gate

/// v0.9.6-beta P1 #2: Vision `VNRecognizeTextRequest` is heavy enough that
/// firing it concurrently for every image clip can pin all P-cores. Throttle
/// to at most 2 concurrent OCR jobs via this actor-guarded semaphore.
actor OCRQueue {
    static let shared = OCRQueue(max: 2)

    private let max: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(max: Int) {
        self.max = max
    }

    func acquire() async {
        if inFlight < max {
            inFlight += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            // Slot stays occupied; ownership transfers to the woken waiter.
            next.resume()
        } else {
            inFlight = Swift.max(0, inFlight - 1)
        }
    }
}

// MARK: - AIEngine

/// On-device intelligence layer. Everything here runs locally and is free.
///
/// Capabilities:
///   - Vision Live Text OCR for image clips
///   - NaturalLanguage tagging / language ID for text clips
///   - Foundation Models (macOS 26+ Apple Intelligence) for rewrite,
///     translate, summarize, reformat, emailify — with a heuristic
///     fallback path for older macOS or when the model is not ready.
@MainActor
enum AIEngine {

    // MARK: - OCR

    static func ocr(image data: Data, languages: [String] = ["ja-JP", "en-US"]) async -> String? {
        #if canImport(Vision)
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        // v0.9.6-beta P1 #2: cap concurrent Vision OCR requests at 2.
        await OCRQueue.shared.acquire()
        defer { Task { await OCRQueue.shared.release() } }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        } catch {
            NSLog("OCR failed: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Tagging / language

    static func tags(for text: String, max: Int = 5) -> [String] {
        #if canImport(NaturalLanguage)
        let tagger = NLTagger(tagSchemes: [.lemma, .nameType])
        tagger.string = text
        var counts: [String: Int] = [:]
        let range = text.startIndex..<text.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, tokenRange in
            if let tag = tag,
               tag != .other,
               case .word? = Optional(NLTokenUnit.word) {
                let word = String(text[tokenRange])
                if word.count >= 3 {
                    counts[word.lowercased(), default: 0] += 1
                }
            }
            return true
        }
        if counts.isEmpty {
            // Fall back to most frequent significant words.
            for w in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let key = w.lowercased()
                guard key.count >= 4 else { continue }
                counts[key, default: 0] += 1
            }
        }
        let top = counts.sorted { $0.value > $1.value }
            .prefix(max)
            .map { $0.key }
        return Array(top)
        #else
        return []
        #endif
    }

    static func detectLanguage(_ text: String) -> String? {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
        #else
        return nil
        #endif
    }

    // MARK: - Summary (heuristic)

    /// 1-line summary by picking the longest "informative" sentence.
    /// Good enough for previews; the full `summarize` action upgrades to
    /// Foundation Models when available.
    static func quickSummary(_ text: String, limit: Int = 140) -> String {
        let sentences = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".。!?!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return String(text.prefix(limit)) }
        let scored = sentences.map { ($0, $0.count) }
        let best = scored.max(by: { $0.1 < $1.1 })?.0 ?? sentences[0]
        return String(best.prefix(limit))
    }

    // MARK: - Foundation Models availability

    /// Whether on-device Apple Intelligence (Foundation Models) can be used.
    static var isFoundationModelsAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    // MARK: - Main action dispatcher

    /// Run the requested ``AIAction`` against `text`. Uses Foundation Models
    /// when available, otherwise falls back to heuristics or
    /// NaturalLanguage-backed processing.
    static func perform(_ action: AIAction, on text: String) async throws -> AIResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIEngineError.invalidInput }
        let ctx = SettingsStore.shared.aiPromptContext

        switch action {
        case .rewrite(let tone):
            return try await runRewrite(text: trimmed, tone: tone, ctx: ctx)
        case .translate(let target):
            return try await runTranslate(text: trimmed, target: target, ctx: ctx)
        case .summarize(let length):
            return try await runSummarize(text: trimmed, length: length, ctx: ctx)
        case .reformat(let target):
            return try await runReformat(text: trimmed, target: target, ctx: ctx)
        case .emailify:
            return try await runEmailify(text: trimmed, ctx: ctx)
        }
    }

    /// ユーザーの style guide / email template を prompt 前段に注入する。
    /// 空ならそのまま `core` を返す。
    private static func decoratePrompt(_ core: String,
                                       ctx: SettingsStore.AIPromptContext,
                                       includeEmailTemplate: Bool = false) -> String {
        var pieces: [String] = []
        if !ctx.styleGuide.isEmpty {
            pieces.append("""
            [フォーマット規約]
            You must follow these style rules in every response:
            \(ctx.styleGuide)
            """)
        }
        if includeEmailTemplate && !ctx.emailTemplate.isEmpty {
            pieces.append("""
            [メール出力フォーマット]
            Use this template for the email body. Where `{{body}}` appears, insert the rewritten body. Keep the rest of the template verbatim (including signature placeholders such as 〔担当者名〕):
            \(ctx.emailTemplate)
            """)
        }
        pieces.append(core)
        return pieces.joined(separator: "\n\n")
    }

    // MARK: - Action implementations

    private static func runRewrite(text: String,
                                   tone: RewriteTone,
                                   ctx: SettingsStore.AIPromptContext) async throws -> AIResult {
        let toneDescription: String
        switch tone {
        case .formal:   toneDescription = "formal, professional"
        case .casual:   toneDescription = "casual, relaxed"
        case .friendly: toneDescription = "friendly, warm"
        case .concise:  toneDescription = "concise, terse"
        }
        let core = """
        Rewrite the following text in a \(toneDescription) tone. Preserve the original meaning and language. Reply with only the rewritten text, with no preamble.

        \(text)
        """
        let prompt = decoratePrompt(core, ctx: ctx)
        if isFoundationModelsAvailable {
            let response = try await runFoundationModels(prompt: prompt)
            return AIResult(text: response, backend: .foundationModels)
        }
        // Heuristic: pass-through.
        return AIResult(text: text, backend: .heuristic)
    }

    private static func runTranslate(text: String,
                                     target: TranslateTarget,
                                     ctx: SettingsStore.AIPromptContext) async throws -> AIResult {
        let resolved: TranslateTarget
        if target == .auto {
            let lang = detectLanguage(text) ?? "en"
            resolved = (lang == "ja") ? .english : .japanese
        } else {
            resolved = target
        }

        let languageName: String
        switch resolved {
        case .japanese:          languageName = "Japanese"
        case .english:           languageName = "English"
        case .korean:            languageName = "Korean"
        case .chineseSimplified: languageName = "Simplified Chinese"
        case .auto:              languageName = "English" // unreachable
        }

        let core = """
        Translate the following text to \(languageName). Preserve meaning and tone. Reply with only the translated text, with no preamble.

        \(text)
        """
        let prompt = decoratePrompt(core, ctx: ctx)
        if isFoundationModelsAvailable {
            let response = try await runFoundationModels(prompt: prompt)
            return AIResult(text: response, backend: .foundationModels)
        }
        // Heuristic fallback: real translation is impossible without a model.
        let message = "[Translation requires Apple Intelligence (macOS 26+).]\n\n\(text)"
        return AIResult(text: message, backend: .heuristic)
    }

    private static func runSummarize(text: String,
                                     length: SummaryLength,
                                     ctx: SettingsStore.AIPromptContext) async throws -> AIResult {
        let instruction: String
        switch length {
        case .short:  instruction = "Summarize the following text in 1 concise sentence."
        case .medium: instruction = "Summarize the following text in 2-3 sentences."
        case .long:   instruction = "Summarize the following text in detail, in at most 5 sentences."
        }
        let core = """
        \(instruction) Preserve the original language. Reply with only the summary, with no preamble.

        \(text)
        """
        let prompt = decoratePrompt(core, ctx: ctx)
        if isFoundationModelsAvailable {
            let response = try await runFoundationModels(prompt: prompt)
            return AIResult(text: response, backend: .foundationModels)
        }
        // Heuristic fallback: longest-sentence picker.
        let limit: Int
        switch length {
        case .short:  limit = 140
        case .medium: limit = 280
        case .long:   limit = 560
        }
        let summary = quickSummary(text, limit: limit)
        return AIResult(text: summary, backend: .heuristic)
    }

    private static func runReformat(text: String,
                                    target: ReformatTarget,
                                    ctx: SettingsStore.AIPromptContext) async throws -> AIResult {
        switch target {
        case .jsonPretty:
            return AIResult(text: prettyPrintJSON(text) ?? text, backend: .heuristic)
        case .slugify:
            return AIResult(text: slugify(text), backend: .heuristic)
        case .plainText:
            return AIResult(text: stripFormatting(text), backend: .heuristic)
        case .markdownToHTML, .htmlToMarkdown:
            let core: String
            if target == .markdownToHTML {
                core = """
                Convert the following Markdown to clean, valid HTML. Reply with only the HTML, with no preamble.

                \(text)
                """
            } else {
                core = """
                Convert the following HTML to clean Markdown. Reply with only the Markdown, with no preamble.

                \(text)
                """
            }
            let prompt = decoratePrompt(core, ctx: ctx)
            if isFoundationModelsAvailable {
                let response = try await runFoundationModels(prompt: prompt)
                return AIResult(text: response, backend: .foundationModels)
            }
            // Heuristic fallback: best-effort.
            if target == .markdownToHTML {
                return AIResult(text: naiveMarkdownToHTML(text), backend: .heuristic)
            } else {
                return AIResult(text: stripFormatting(text), backend: .heuristic)
            }
        }
    }

    private static func runEmailify(text: String,
                                    ctx: SettingsStore.AIPromptContext) async throws -> AIResult {
        let core = """
        Format the following text as a polite, professional email. Include a greeting, body, and sign-off. Preserve the original language. Reply with only the email body, with no preamble.

        \(text)
        """
        let prompt = decoratePrompt(core, ctx: ctx, includeEmailTemplate: true)
        if isFoundationModelsAvailable {
            let response = try await runFoundationModels(prompt: prompt)
            return AIResult(text: response, backend: .foundationModels)
        }
        // Heuristic: ユーザーが email template を持っていればそれを最低限尊重する。
        if !ctx.emailTemplate.isEmpty {
            let filled = ctx.emailTemplate.replacingOccurrences(of: "{{body}}", with: text)
            return AIResult(text: filled, backend: .heuristic)
        }
        let template = "Dear ,\n\n\(text)\n\nBest regards,\n"
        return AIResult(text: template, backend: .heuristic)
    }

    // MARK: - Foundation Models bridge

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func runFoundationModelsImpl(prompt: String) async throws -> String {
        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: prompt)
            let raw = response.content
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw AIEngineError.requestFailed(underlying: error)
        }
    }
    #endif

    /// Version-gated wrapper. Callers should check ``isFoundationModelsAvailable``
    /// before reaching here; if reached on an older OS, we throw `.modelUnavailable`.
    private static func runFoundationModels(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await runFoundationModelsImpl(prompt: prompt)
        }
        #endif
        throw AIEngineError.modelUnavailable
    }

    // MARK: - Heuristic helpers

    private static func prettyPrintJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        var buffer = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                buffer.append(Character(scalar))
                lastWasDash = false
            } else if !lastWasDash, !buffer.isEmpty {
                buffer.append("-")
                lastWasDash = true
            }
        }
        while buffer.hasSuffix("-") { buffer.removeLast() }
        return buffer
    }

    /// Strip a best-effort superset of HTML / Markdown decoration.
    private static func stripFormatting(_ text: String) -> String {
        // Strip HTML tags.
        var output = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        // Common Markdown markers.
        let markers = ["**", "__", "*", "_", "`", "~~"]
        for marker in markers {
            output = output.replacingOccurrences(of: marker, with: "")
        }
        // Markdown headings / list markers at line starts.
        output = output.replacingOccurrences(
            of: "(?m)^[ \\t]*(#{1,6}\\s+|[-*+]\\s+|\\d+\\.\\s+|>\\s+)",
            with: "",
            options: .regularExpression
        )
        // Decode a few common HTML entities.
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Minimal Markdown to HTML for the heuristic fallback. Handles
    /// headings, bold, italics, inline code, and paragraphs.
    private static func naiveMarkdownToHTML(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            // Headings.
            if let match = line.range(of: "^(#{1,6})\\s+(.+)$", options: .regularExpression) {
                let header = String(line[match])
                let hashes = header.prefix(while: { $0 == "#" })
                let level = min(6, hashes.count)
                let content = header.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                line = "<h\(level)>\(content)</h\(level)>"
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                line = ""
            } else {
                line = "<p>\(line)</p>"
            }
            lines.append(line)
        }
        var html = lines.joined(separator: "\n")
        // Inline replacements.
        html = html.replacingOccurrences(
            of: "\\*\\*(.+?)\\*\\*",
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: "\\*(.+?)\\*",
            with: "<em>$1</em>",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: "`(.+?)`",
            with: "<code>$1</code>",
            options: .regularExpression
        )
        return html
    }
}
