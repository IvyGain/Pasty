import Foundation
import NaturalLanguage

// MARK: - AutoCategory

/// Auto-classified category for an incoming clipboard item.
public enum AutoCategory: String, CaseIterable, Identifiable, Codable {
    case code
    case url
    case email
    case json
    case image
    case ja
    case en
    case other

    public var id: String { rawValue }

    /// 日本語ラベル（UI 表示用）
    public var japaneseLabel: String {
        switch self {
        case .code:  return "コード"
        case .url:   return "URL"
        case .email: return "メール"
        case .json:  return "JSON"
        case .image: return "画像"
        case .ja:    return "日本語"
        case .en:    return "英語"
        case .other: return "その他"
        }
    }

    /// SF Symbols 名（UI 表示用）
    public var systemImage: String {
        switch self {
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .url:   return "link"
        case .email: return "envelope"
        case .json:  return "curlybraces"
        case .image: return "photo"
        case .ja:    return "character.book.closed"
        case .en:    return "textformat"
        case .other: return "questionmark.square.dashed"
        }
    }
}

// MARK: - AutoCategorizer

/// クリップボード項目を heuristic + NaturalLanguage で自動分類し、
/// ユーザーが設定したカテゴリ→Pinboard マッピングに従って振分先を解決する。
@MainActor
final class AutoCategorizer {

    /// シングルトン
    static let shared = AutoCategorizer()

    // MARK: Persistence

    private let defaultsKey = "pasty.autoCategoryMapping"
    private let defaults: UserDefaults

    /// カテゴリ → Pinboard ID のマッピング。setter は即時に UserDefaults に保存する。
    var mapping: [AutoCategory: Int64] {
        get { _mapping }
        set {
            _mapping = newValue
            persist(newValue)
        }
    }

    private var _mapping: [AutoCategory: Int64] = [:]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._mapping = Self.load(from: defaults, key: defaultsKey)
    }

    // MARK: Public API

    /// クリップを 1 つ分類する。
    /// - Parameters:
    ///   - clip: 分類対象のクリップ
    ///   - pinboards: Pinboard ストア（現状は将来拡張のため受け取るが、判定には使わない）
    /// - Returns: 推定された `AutoCategory`
    func classify(_ clip: ClipItem, pinboards: PinboardStore) -> AutoCategory {
        // 1. 画像
        if clip.kind == .image { return .image }

        // 2. リンク種別 or http(s):// 始まりの本文
        let raw = clip.content ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clip.kind == .link { return .url }
        if isURL(trimmed) { return .url }

        // テキストが空ならその他扱い
        if trimmed.isEmpty { return .other }

        // 3. メールアドレス（本文のほぼ全体がアドレス）
        if isEmail(trimmed) { return .email }

        // 4. JSON
        if isJSON(trimmed) { return .json }

        // 5. コード
        if looksLikeCode(trimmed) { return .code }

        // 6. 言語判定
        return detectLanguageCategory(trimmed)
    }

    /// 解決済みの振分先 Pinboard を返す。マッピング未設定なら nil。
    func resolveTargetPinboard(for clip: ClipItem, pinboards: PinboardStore) -> Pinboard? {
        let category = classify(clip, pinboards: pinboards)
        guard let boardId = _mapping[category] else { return nil }
        return pinboards.boards.first { $0.id == boardId }
    }

    // MARK: - Heuristics

    private func isURL(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            // 余分な空白を含む長文ではなく、単一 URL に近いものに限定
            return !s.contains(" ") && !s.contains("\n")
        }
        return false
    }

    private func isEmail(_ s: String) -> Bool {
        // 本文がほぼメアドだけ（前後に長文が無い）
        guard !s.contains("\n"), s.count <= 254 else { return false }
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.firstMatch(in: s, options: [], range: range) != nil
    }

    private func isJSON(_ s: String) -> Bool {
        let first = s.first
        let last = s.last
        let bracketed = (first == "{" && last == "}") || (first == "[" && last == "]")
        guard bracketed, let data = s.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return true
        } catch {
            return false
        }
    }

    private func looksLikeCode(_ s: String) -> Bool {
        // コードらしき予約語・記号の出現回数で判定
        let tokens: [String] = [
            "func ", "def ", "class ", "import ", "=>", "<?php", "#include",
            "public ", "private ", "static ", "return ", "const ", "let ",
            "var ", "function ", "=> {", "println(", "print(", "console.log(",
            "struct ", "enum ", "interface ", "package ", "fn ", "extern ",
            "#!/", "namespace ", "void ", "int ", "@MainActor", "@objc"
        ]
        var hits = 0
        for t in tokens {
            if s.contains(t) {
                hits += 1
                if hits >= 2 { return true }
            }
        }
        // 中括弧 + セミコロン or インデントが多い場合もコード扱い
        let braces = s.filter { $0 == "{" || $0 == "}" }.count
        let semis = s.filter { $0 == ";" }.count
        if braces >= 2 && semis >= 2 { return true }

        return false
    }

    private func detectLanguageCategory(_ s: String) -> AutoCategory {
        let recognizer = NLLanguageRecognizer()
        // 長文では先頭の方だけで十分
        let sample = s.count > 1024 ? String(s.prefix(1024)) : s
        recognizer.processString(sample)
        guard let lang = recognizer.dominantLanguage else { return .other }
        switch lang {
        case .japanese: return .ja
        case .english:  return .en
        default:        return .other
        }
    }

    // MARK: - Persistence helpers

    private func persist(_ mapping: [AutoCategory: Int64]) {
        let raw: [String: Int64] = mapping.reduce(into: [:]) { acc, kv in
            acc[kv.key.rawValue] = kv.value
        }
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> [AutoCategory: Int64] {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Int64].self, from: data)
        else { return [:] }
        var result: [AutoCategory: Int64] = [:]
        for (k, v) in raw {
            if let cat = AutoCategory(rawValue: k) {
                result[cat] = v
            }
        }
        return result
    }
}
