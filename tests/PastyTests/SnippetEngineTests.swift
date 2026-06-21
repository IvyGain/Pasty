import XCTest
@testable import Pasty

/// v0.9.5-beta B9: counter / if-block coverage for SnippetEngine.
/// Counter state lives in `SettingsStore.snippetCounters` (UserDefaults),
/// so each test resets the counters it touches to keep ordering independent.
@MainActor
final class SnippetEngineTests: XCTestCase {

    private func resetCounter(_ name: String) {
        var c = SettingsStore.shared.snippetCounters
        c.removeValue(forKey: name)
        SettingsStore.shared.snippetCounters = c
    }

    /// Counter names must be `[a-zA-Z_][a-zA-Z0-9_]*` per the parser, so
    /// generate identifier-safe unique names instead of using `UUID()`.
    private static var counterUniqueSeq = 0
    private func uniqueCounterName(_ prefix: String) -> String {
        Self.counterUniqueSeq += 1
        return "tc_\(prefix)_\(Self.counterUniqueSeq)"
    }

    // MARK: counter

    func testCounterIncrementsOnEachExpansion() {
        let key = uniqueCounterName("inc")
        resetCounter(key)
        defer { resetCounter(key) }

        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)}}").text, "1")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)}}").text, "2")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)}}").text, "3")
    }

    func testCounterFormatModifier() {
        let key = uniqueCounterName("fmt")
        resetCounter(key)
        defer { resetCounter(key) }

        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)|format:%04d}}").text, "0001")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)|format:%04d}}").text, "0002")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)|format:%05d}}").text, "00003")
    }

    func testCounterResetReturnsEmptyAndZeroes() {
        let key = uniqueCounterName("rst")
        resetCounter(key)
        defer { resetCounter(key) }

        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)}}").text, "1")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)}}").text, "2")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)|reset}}").text, "")
        // After reset, next read should start at 1 again.
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(key)}}").text, "1")
    }

    func testCounterIndependentNames() {
        let a = uniqueCounterName("ia")
        let b = uniqueCounterName("ib")
        resetCounter(a)
        resetCounter(b)
        defer { resetCounter(a); resetCounter(b) }

        XCTAssertEqual(SnippetEngine.expand("{{counter:\(a)}}").text, "1")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(a)}}").text, "2")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(b)}}").text, "1")
        XCTAssertEqual(SnippetEngine.expand("{{counter:\(a)}}").text, "3")
    }

    // MARK: if hasField

    func testIfHasFieldTruthy() {
        let result = SnippetEngine.expand(
            "{{if hasField name}}Hi {{name}}{{endif}}",
            fields: ["name": "taro"]
        ).text
        XCTAssertEqual(result, "Hi taro")
    }

    func testIfHasFieldFalsy() {
        let result = SnippetEngine.expand(
            "{{if hasField name}}Hi {{name}}{{endif}}",
            fields: [:]
        ).text
        XCTAssertEqual(result, "")
    }

    func testIfHasFieldEmptyStringIsFalsy() {
        let result = SnippetEngine.expand(
            "{{if hasField name}}Hi {{name}}{{endif}}",
            fields: ["name": "   "]
        ).text
        XCTAssertEqual(result, "")
    }

    // MARK: if equals

    func testIfEqualsMatch() {
        let result = SnippetEngine.expand(
            "{{if equals lang \"en\"}}Hello{{endif}}",
            fields: ["lang": "en"]
        ).text
        XCTAssertEqual(result, "Hello")
    }

    func testIfEqualsMismatch() {
        let result = SnippetEngine.expand(
            "{{if equals lang \"en\"}}Hello{{endif}}",
            fields: ["lang": "ja"]
        ).text
        XCTAssertEqual(result, "")
    }

    // MARK: regressions on existing functionality

    func testExistingExpansionStillWorks() {
        // Without fields the old API surface must keep working.
        let r = SnippetEngine.expand("hello {{user}}")
        XCTAssertTrue(r.text.hasPrefix("hello "))
        XCTAssertFalse(r.text.contains("{{user}}"))
    }

    func testPipelineModifierStillWorks() {
        let r = SnippetEngine.expand("{{user | uppercase}}").text
        XCTAssertEqual(r, NSUserName().uppercased())
    }
}
