import Foundation
import AppKit

/// Expands `{{var}}` placeholders inside a clip's content before pasting.
/// Built-in variables: `date`, `time`, `iso`, `user`, `host`, `uuid`,
/// `clipboard`, `cursor`. Custom variables can be added via SettingsStore.
enum SnippetEngine {
    static let pattern = try! NSRegularExpression(
        pattern: #"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)(?::([^}]*))?\s*\}\}"#,
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

        let ns = output as NSString
        let matches = pattern.matches(in: output, range: NSRange(location: 0, length: ns.length))

        // Walk matches back-to-front so ranges remain stable as we mutate.
        for m in matches.reversed() {
            let nameRange = m.range(at: 1)
            let argRange = m.range(at: 2)
            let name = ns.substring(with: nameRange)
            let arg: String? = argRange.location != NSNotFound ? ns.substring(with: argRange) : nil
            let value = resolve(variable: name, argument: arg, custom: customVariables)
            output = (output as NSString).replacingCharacters(in: m.range, with: value)
        }

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

struct ExpansionResult: Equatable {
    let text: String
    let cursorIndex: Int?
}
