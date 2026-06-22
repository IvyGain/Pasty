import Foundation

/// v0.9.6-beta P0 #9: 機密データ自動マスク。
///
/// OCR で抽出された文字列に含まれるクレジットカード番号 / SSN / マイナンバー
/// 12 桁 / 電話番号 / API トークン / IBAN を `[CARD]` `[SSN]` `[MYNUMBER]`
/// `[PHONE]` `[TOKEN]` `[IBAN]` に置換する。Email アドレスは検索性のために
/// 残す (置換しない)。
///
/// 適用順 (最長一致が先に当たるよう CARD → SSN → MYNUMBER → PHONE → TOKEN
/// → IBAN の順に適用する):
///   1. Credit card: 13-19 桁、空白 / ハイフン区切り許容、Luhn 検証通ったもののみ。
///   2. SSN: `\b\d{3}-\d{2}-\d{4}\b`
///   3. 日本マイナンバー: `\b\d{12}\b` (Luhn を通過した 12 桁は既に CARD で
///      消費されているので、ここに来るのは非 Luhn の 12 桁のみ)
///   4. Phone: E.164 / 日本ハイフン区切り / 日本 10-11 桁連続
///   5. API tokens: `sk-...` / `ghp_...` / `Bearer ...`
///   6. IBAN: 国コード 2 + チェック 2 + 残り 11-30
///   7. Email: そのまま (検索ヒットを潰さないため残す)
enum SensitiveDataFilter {

    /// 置換後の文字列と、置換が発生した回数を返す。
    /// 呼び出し側は redactedCount > 0 をログ出力 / メトリクスに使用できる。
    static func redact(_ text: String) -> (output: String, redactedCount: Int) {
        var output = text
        var total = 0

        // 1. Credit card: 13-19 digits、空白 / ハイフン区切り許容。
        //    パターンとしてヒットしたあと、数字だけ抜き出して Luhn 検証。
        //    Luhn 通過したものだけを `[CARD]` に置換。失敗したものはそのまま
        //    残して、後段の MYNUMBER / PHONE が拾えるようにする。
        let cardPattern = #"\b(?:\d[ -]?){12,18}\d\b"#
        total += replaceMatches(in: &output, pattern: cardPattern, replacement: "[CARD]") { match in
            let digits = match.filter { $0.isNumber }
            guard (13...19).contains(digits.count) else { return false }
            return luhnValid(digits)
        }

        // 2. SSN: 米国社会保障番号。`123-45-6789` 形式のみ。
        let ssnPattern = #"\b\d{3}-\d{2}-\d{4}\b"#
        total += replaceMatches(in: &output, pattern: ssnPattern, replacement: "[SSN]")

        // 3. 日本マイナンバー: 区切りなし 12 桁。Luhn を通った 12 桁は既に
        //    CARD として消費済みなので、残るのは非 Luhn の 12 桁のみ。
        let myNumberPattern = #"\b\d{12}\b"#
        total += replaceMatches(in: &output, pattern: myNumberPattern, replacement: "[MYNUMBER]")

        // 4. Phone: E.164 (`+15551234567`) と日本ハイフン区切り (`03-1234-5678`)
        //    と日本 10-11 桁連続 (`09012345678`)。
        let phonePatterns: [String] = [
            #"\+\d{7,15}\b"#,
            #"\b0\d{1,4}-\d{1,4}-\d{3,4}\b"#,
            #"\b0\d{9,10}\b"#
        ]
        for pat in phonePatterns {
            total += replaceMatches(in: &output, pattern: pat, replacement: "[PHONE]")
        }

        // 5. API tokens: OpenAI `sk-...` / GitHub PAT `ghp_...` / `Bearer ...`。
        //    順序は長いプレフィックスから順に当てる。
        let tokenPatterns: [String] = [
            #"\bsk-[A-Za-z0-9]{16,}\b"#,
            #"\bghp_[A-Za-z0-9]{20,}\b"#,
            #"Bearer\s+[A-Za-z0-9\-_]{20,}"#
        ]
        for pat in tokenPatterns {
            total += replaceMatches(in: &output, pattern: pat, replacement: "[TOKEN]")
        }

        // 6. IBAN: ISO 13616。国コード 2 + チェック数字 2 + BBAN 11-30。
        let ibanPattern = #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#
        total += replaceMatches(in: &output, pattern: ibanPattern, replacement: "[IBAN]")

        // 7. Email: 検索性のために残す。意図的に redact しない。

        return (output, total)
    }

    // MARK: - Private helpers

    /// 正規表現マッチを一括で置換する。`shouldReplace` がない (= 常に true)
    /// 場合と、callback で個別に判定する場合の両方をサポート。
    /// 文字列を後ろから前へ書き換えるので、range が破壊されない。
    @discardableResult
    private static func replaceMatches(
        in text: inout String,
        pattern: String,
        replacement: String,
        shouldReplace: ((String) -> Bool)? = nil
    ) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return 0
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return 0 }

        var replaced = 0
        // Iterate in reverse so that earlier ranges remain valid as we mutate
        // the underlying NSMutableString.
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let r = match.range
            guard r.location != NSNotFound else { continue }
            let segment = ns.substring(with: r)
            if let predicate = shouldReplace, !predicate(segment) { continue }
            mutable.replaceCharacters(in: r, with: replacement)
            replaced += 1
        }
        text = mutable as String
        return replaced
    }

    /// Luhn (mod 10) checksum 検証。クレジットカード番号は Luhn を通る
    /// 前提なので、これで「単なる 16 桁数字列」と「実カード番号」を弁別する。
    private static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var alt = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            if alt {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
            alt.toggle()
        }
        return sum % 10 == 0
    }
}
