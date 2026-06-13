import Foundation
import AppKit
#if canImport(Vision)
import Vision
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// On-device intelligence layer. Everything here runs locally and is
/// free, including:
///   • Vision Live Text OCR for image clips
///   • NaturalLanguage tagging / language ID for text clips
///   • Foundation Models hookup (macOS 15.1+) is intentionally stubbed
///     behind `#if canImport(FoundationModels)` so we can ship without
///     blocking the OSS build on a moving Apple API.
enum AIEngine {

    // MARK: - OCR

    static func ocr(image data: Data) async -> String? {
        #if canImport(Vision)
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja", "en-US"]
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

    // MARK: - Summary (heuristic, swap for FoundationModels when available)

    /// 1-line summary by picking the longest "informative" sentence.
    /// Good enough for previews; replace with FoundationModels later.
    static func quickSummary(_ text: String, limit: Int = 140) -> String {
        let sentences = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".。!?！？"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return String(text.prefix(limit)) }
        let scored = sentences.map { ($0, $0.count) }
        let best = scored.max(by: { $0.1 < $1.1 })?.0 ?? sentences[0]
        return String(best.prefix(limit))
    }
}
