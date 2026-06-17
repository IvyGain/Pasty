import Foundation

// MARK: - AIActionRef
// Codable な AIAction の参照表現。AIAction は enum with associated values で
// 既存のコードベースは `action.id` を "rewrite.formal" 形式で生成しているため、
// この文字列をそのまま保存し、復元時に "head.tail" にパースしてケースを再構築する。

public struct AIActionRef: Codable, Hashable, Identifiable {
    public var id: String  // = AIAction.id ("rewrite.formal" など)

    public init(id: String) {
        self.id = id
    }

    /// 既存の AIAction から ref を作る。associated value を含む id を採用。
    public init(_ action: AIAction) {
        self.id = action.id
    }

    /// 文字列 id から AIAction を復元する。未知の id は nil。
    public func resolved() -> AIAction? {
        let parts = id.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first else { return nil }
        let tail = parts.count >= 2 ? String(parts[1]) : ""
        switch head {
        case "rewrite":
            return RewriteTone(rawValue: tail).map { .rewrite(tone: $0) }
        case "translate":
            return TranslateTarget(rawValue: tail).map { .translate(target: $0) }
        case "summarize":
            return SummaryLength(rawValue: tail).map { .summarize(length: $0) }
        case "reformat":
            return ReformatTarget(rawValue: tail).map { .reformat(to: $0) }
        case "emailify":
            return .emailify
        default:
            return nil
        }
    }

    /// UI 表示用ラベル。未解決なら id をそのまま返す。
    public var displayLabel: String {
        resolved()?.label ?? id
    }
}

// MARK: - AIMacro

public struct AIMacro: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var actions: [AIActionRef]

    public init(id: UUID = UUID(), name: String, actions: [AIActionRef]) {
        self.id = id
        self.name = name
        self.actions = actions
    }

    /// UI に出す手順サマリ。例: 「翻訳（英語） → メール風に整形」。
    public var stepSummary: String {
        actions.map { $0.displayLabel }.joined(separator: " → ")
    }
}

extension AIMacro {
    /// 初回起動時に SettingsStore が seed として使うプリセット 4 種。
    public static let defaultMacros: [AIMacro] = [
        AIMacro(name: "英訳 → メール風",
                actions: [
                    AIActionRef(.translate(target: .english)),
                    AIActionRef(.emailify),
                ]),
        AIMacro(name: "要約 → メール風",
                actions: [
                    AIActionRef(.summarize(length: .short)),
                    AIActionRef(.emailify),
                ]),
        AIMacro(name: "校正 (フォーマル) → 翻訳",
                actions: [
                    AIActionRef(.rewrite(tone: .formal)),
                    AIActionRef(.translate(target: .english)),
                ]),
        AIMacro(name: "校正 (カジュアル) → 短く要約",
                actions: [
                    AIActionRef(.rewrite(tone: .casual)),
                    AIActionRef(.summarize(length: .short)),
                ]),
    ]
}
