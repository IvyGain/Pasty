import Foundation

// MARK: - FieldHistoryStore
//
// `TemplateFieldDialog` で `[[name]]` / `[[topic]]` などのプレースホルダに
// ユーザが入れた値をフィールド名ごとに記憶しておくための薄い永続層。
//
// 「次回貼付時に過去の入力をサジェスト」がユースケース。重い検索 / 統計用途
// では使わないので UserDefaults に JSON でぶら下げる素朴な実装で十分。
@MainActor
final class FieldHistoryStore: ObservableObject {

    // MARK: Singleton

    static let shared = FieldHistoryStore()

    // MARK: Tunables

    /// フィールドごとに保持する上限。`suggestions(for:)` が返すのは先頭 5 件
    /// だけだが、ユーザが似た値を入れ替えながら使うことを想定して内部では
    /// 少し余裕を持って保管する。
    private let perFieldLimit: Int = 20

    /// `suggestions(for:)` が呼び出し側に見せる件数。仕様で 5 件固定。
    private let suggestionLimit: Int = 5

    /// UserDefaults キー。スキーマが変わったら `.v2` などにする。
    private let storageKey: String = "pasty.fieldHistory.v1"

    // MARK: State

    /// fieldName → 値配列 (新しいものが先頭)。
    private var histories: [String: [String]] = [:]

    private let defaults: UserDefaults

    // MARK: Init

    /// テスト用に UserDefaults を差し替えられるよう internal init を残す。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.histories = Self.load(from: defaults, key: storageKey)
    }

    // MARK: Public API

    /// 指定フィールド名の過去入力候補。新しい順、最大 5 件。
    func suggestions(for fieldName: String) -> [String] {
        guard let list = histories[fieldName] else { return [] }
        if list.count <= suggestionLimit { return list }
        return Array(list.prefix(suggestionLimit))
    }

    /// ユーザが値を確定したときに記録する。
    /// 空文字 / 空白だけの値は無視し、重複は先頭に押し出す。
    func record(fieldName: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var list = histories[fieldName] ?? []
        // 同じ値があったら一度抜いて、必ず先頭に積み直す。
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > perFieldLimit {
            list = Array(list.prefix(perFieldLimit))
        }
        histories[fieldName] = list
        persist()
    }

    /// 全削除。設定画面の「履歴をクリア」相当。
    func clearAll() {
        histories.removeAll()
        persist()
    }

    // MARK: Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(histories)
            defaults.set(data, forKey: storageKey)
        } catch {
            // 永続化に失敗してもアプリは動かしたい — メモリ上の状態だけ生き残る。
            #if DEBUG
            NSLog("[FieldHistoryStore] persist failed: \(error)")
            #endif
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> [String: [String]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: [String]].self, from: data)
        } catch {
            // スキーマズレや破損は黙って捨てて再スタート。
            #if DEBUG
            NSLog("[FieldHistoryStore] load failed, resetting: \(error)")
            #endif
            return [:]
        }
    }
}
