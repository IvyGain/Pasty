import XCTest
@testable import Pasty

/// v0.9.6-beta P0 #9: SensitiveDataFilter unit tests.
/// 全パターン (CARD / SSN / MYNUMBER / PHONE / TOKEN / IBAN / EMAIL) を網羅し、
/// Luhn 検証で実カードと「単なる 16 桁数字列」が弁別されることを確認する。
final class SensitiveDataFilterTests: XCTestCase {

    // MARK: - Credit card / Luhn

    func testCardLuhnPassRedacted() {
        // 4111 1111 1111 1111 は Visa の典型テスト番号で Luhn を通る。
        let input = "Card: 4111 1111 1111 1111"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "Card: [CARD]")
        XCTAssertEqual(count, 1)
    }

    func testCardLuhnFailUntouched() {
        // 1234 5678 9012 3456 は Luhn を通らないので CARD としては redact されない。
        // ただしマイナンバー (12 桁連続) 等にも当てはまらないので、最終的に
        // どこにもヒットしないこともある。ここでは "[CARD]" を含まないことだけ確認する。
        let input = "Number: 1234 5678 9012 3456"
        let (out, _) = SensitiveDataFilter.redact(input)
        XCTAssertFalse(out.contains("[CARD]"), "Non-Luhn 16-digit run should not become [CARD]; got: \(out)")
    }

    // MARK: - SSN

    func testSSNRedacted() {
        let input = "SSN is 123-45-6789 today"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "SSN is [SSN] today")
        XCTAssertEqual(count, 1)
    }

    // MARK: - 日本マイナンバー

    func testMyNumber12Digit() {
        // Luhn を通らない 12 桁。123456789012 の Luhn sum は奇数なので通らない。
        // (1+4+3+8+5+(1+2)+9+(0+2)+1+(0+4)+0+(1+2) = 計算済みで非倍数10)
        let input = "MyNumber: 123456789012"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "MyNumber: [MYNUMBER]")
        XCTAssertEqual(count, 1)
    }

    // MARK: - Phone

    func testPhoneE164() {
        let input = "Call +15551234567 anytime"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "Call [PHONE] anytime")
        XCTAssertEqual(count, 1)
    }

    func testPhoneJapan() {
        let input = "Tel: 03-1234-5678"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "Tel: [PHONE]")
        XCTAssertEqual(count, 1)
    }

    // MARK: - Tokens

    func testTokenSk() {
        let input = "key=sk-abcdef1234567890ghij rest"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "key=[TOKEN] rest")
        XCTAssertEqual(count, 1)
    }

    func testTokenGhp() {
        let input = "pat=ghp_abcdefghij1234567890klmn rest"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "pat=[TOKEN] rest")
        XCTAssertEqual(count, 1)
    }

    func testTokenBearer() {
        let input = "Authorization: Bearer abcdefghij1234567890klmn"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "Authorization: [TOKEN]")
        XCTAssertEqual(count, 1)
    }

    // MARK: - IBAN

    func testIBAN() {
        let input = "IBAN: GB82WEST12345698765432 ok"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "IBAN: [IBAN] ok")
        XCTAssertEqual(count, 1)
    }

    // MARK: - Email (kept as-is)

    func testEmailKept() {
        let input = "Contact me at foo@bar.com"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "Contact me at foo@bar.com")
        XCTAssertEqual(count, 0)
    }

    // MARK: - Clean text

    func testCleanTextUnchanged() {
        let input = "Hello world"
        let (out, count) = SensitiveDataFilter.redact(input)
        XCTAssertEqual(out, "Hello world")
        XCTAssertEqual(count, 0)
    }
}
