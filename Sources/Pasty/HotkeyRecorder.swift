import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - HotkeyDescriptor

/// A serializable description of a global hotkey: a Carbon key code plus
/// a stable list of modifier names. Decoupled from `HotKeyManager.Combo`
/// so it can round-trip through `UserDefaults` JSON cleanly.
public struct HotkeyDescriptor: Codable, Hashable {
    public let keyCode: UInt32        // Carbon kVK_*
    public let modifiers: [String]    // ["command", "shift", "option", "control"]

    public init(keyCode: UInt32, modifiers: [String]) {
        self.keyCode = keyCode
        // Normalize order so equal descriptors are always Equal/Hashable-equal
        // regardless of the order callers passed them in.
        let order = ["control", "option", "shift", "command"]
        self.modifiers = modifiers
            .map { $0.lowercased() }
            .filter { order.contains($0) }
            .sorted { (a, b) in
                (order.firstIndex(of: a) ?? Int.max) < (order.firstIndex(of: b) ?? Int.max)
            }
    }

    /// "⇧⌘V" style label. Returns "未設定" when keyCode == 0.
    public var display: String {
        if keyCode == 0 && modifiers.isEmpty { return "未設定" }
        var out = ""
        for mod in modifiers {
            switch mod {
            case "control": out += "⌃"
            case "option":  out += "⌥"
            case "shift":   out += "⇧"
            case "command": out += "⌘"
            default: break
            }
        }
        if keyCode == 0 {
            return out.isEmpty ? "未設定" : out
        }
        out += Self.keyCodeSymbol(keyCode)
        return out
    }

    /// Convert to the lower-level Carbon combo consumed by `HotKeyManager`.
    var carbonCombo: HotKeyManager.Combo {
        var mods: Set<HotKeyManager.Modifier> = []
        for mod in modifiers {
            switch mod {
            case "command": mods.insert(.command)
            case "option":  mods.insert(.option)
            case "control": mods.insert(.control)
            case "shift":   mods.insert(.shift)
            default: break
            }
        }
        return HotKeyManager.Combo(keyCode: keyCode, modifiers: mods)
    }

    /// True when the descriptor represents "no hotkey assigned".
    public var isUnset: Bool { keyCode == 0 && modifiers.isEmpty }

    // MARK: - Key code → symbol

    /// Maps Carbon key codes to a display symbol. Falls back to "keyN".
    static func keyCodeSymbol(_ code: UInt32) -> String {
        switch Int(code) {
        // Letters
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        // Digits
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        // Function keys
        case kVK_F1:  return "F1"
        case kVK_F2:  return "F2"
        case kVK_F3:  return "F3"
        case kVK_F4:  return "F4"
        case kVK_F5:  return "F5"
        case kVK_F6:  return "F6"
        case kVK_F7:  return "F7"
        case kVK_F8:  return "F8"
        case kVK_F9:  return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        // Whitespace / control
        case kVK_Space:    return "␣"
        case kVK_Return:   return "↩"
        case kVK_Tab:      return "⇥"
        case kVK_Escape:   return "⎋"
        case kVK_Delete:   return "⌫"
        case kVK_ForwardDelete: return "⌦"
        // Arrows
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        default:
            return "key\(code)"
        }
    }
}

// MARK: - HotkeyAction

/// User-facing actions that can have a hotkey bound to them.
public enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case primarySurface      // ⇧⌘V
    case secondarySurface    // ⌥⇧V
    case pauseCapture        // ⌃⇧P
    case undoPaste           // ⌃⇧Z
    case aiRewrite           // ⌃⇧R
    case aiTranslate         // ⌃⇧T
    case aiSummarize         // ⌃⇧S
    case aiReformat          // ⌃⇧J
    case aiEmailify          // ⌃⇧E

    public var id: String { rawValue }

    public var japaneseLabel: String {
        switch self {
        case .primarySurface:   return "メインパネルを開く"
        case .secondarySurface: return "サブパネルを開く"
        case .pauseCapture:     return "キャプチャを一時停止"
        case .undoPaste:        return "ペーストを取り消し"
        case .aiRewrite:        return "AI: 書き換え"
        case .aiTranslate:      return "AI: 翻訳"
        case .aiSummarize:      return "AI: 要約"
        case .aiReformat:       return "AI: 整形"
        case .aiEmailify:       return "AI: メール調"
        }
    }

    public var defaultDescriptor: HotkeyDescriptor {
        switch self {
        case .primarySurface:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_V), modifiers: ["shift", "command"])
        case .secondarySurface:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_V), modifiers: ["option", "shift"])
        case .pauseCapture:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_P), modifiers: ["control", "shift"])
        case .undoPaste:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Z), modifiers: ["control", "shift"])
        case .aiRewrite:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_R), modifiers: ["control", "shift"])
        case .aiTranslate:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_T), modifiers: ["control", "shift"])
        case .aiSummarize:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_S), modifiers: ["control", "shift"])
        case .aiReformat:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_J), modifiers: ["control", "shift"])
        case .aiEmailify:
            return HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_E), modifiers: ["control", "shift"])
        }
    }
}

// MARK: - HotkeyStore

/// Persists the user's hotkey bindings as JSON in UserDefaults so the rest
/// of the app can subscribe and re-register on the fly.
@MainActor
public final class HotkeyStore: ObservableObject {
    public static let shared = HotkeyStore()

    private static let defaultsKey = "pasty.hotkeys.v1"

    @Published public var bindings: [HotkeyAction: HotkeyDescriptor] {
        didSet { persist() }
    }

    private init() {
        self.bindings = Self.loadFromDefaults() ?? Self.defaultBindings()
    }

    public func descriptor(for action: HotkeyAction) -> HotkeyDescriptor {
        bindings[action] ?? action.defaultDescriptor
    }

    public func update(_ action: HotkeyAction, to descriptor: HotkeyDescriptor) {
        bindings[action] = descriptor
    }

    public func resetAll() {
        bindings = Self.defaultBindings()
    }

    // MARK: Persistence

    private static func defaultBindings() -> [HotkeyAction: HotkeyDescriptor] {
        var dict: [HotkeyAction: HotkeyDescriptor] = [:]
        for action in HotkeyAction.allCases {
            dict[action] = action.defaultDescriptor
        }
        return dict
    }

    private static func loadFromDefaults() -> [HotkeyAction: HotkeyDescriptor]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        do {
            let raw = try JSONDecoder().decode([String: HotkeyDescriptor].self, from: data)
            var dict: [HotkeyAction: HotkeyDescriptor] = [:]
            for (key, value) in raw {
                if let action = HotkeyAction(rawValue: key) {
                    dict[action] = value
                }
            }
            // Backfill any new actions added since last save.
            for action in HotkeyAction.allCases where dict[action] == nil {
                dict[action] = action.defaultDescriptor
            }
            return dict
        } catch {
            NSLog("Pasty: failed to decode hotkey bindings: \(error)")
            return nil
        }
    }

    private func persist() {
        var raw: [String: HotkeyDescriptor] = [:]
        for (action, descriptor) in bindings {
            raw[action.rawValue] = descriptor
        }
        do {
            let data = try JSONEncoder().encode(raw)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            NSLog("Pasty: failed to encode hotkey bindings: \(error)")
        }
    }
}

// MARK: - HotkeyRecorderField

/// A click-to-record button that captures a single key event and writes
/// the resulting descriptor back through `@Binding`.
///
/// - Esc cancels the recording session.
/// - Backspace clears the binding (descriptor with keyCode == 0).
/// - Any other key + modifiers is captured as a new descriptor.
@MainActor
struct HotkeyRecorderField: View {
    @Binding var descriptor: HotkeyDescriptor
    var onRecord: ((HotkeyDescriptor) -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isRecording ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isRecording ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isRecording ? 1.5 : 1
                    )
                Text(isRecording ? "キーを押してください…" : descriptor.display)
                    .font(isRecording ? PastyTheme.subtitleFont : PastyTheme.monoFont)
                    .foregroundColor(isRecording ? .accentColor : .primary)
                    .padding(.horizontal, 10)
            }
            .frame(minWidth: 140, minHeight: 28)
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Esc でキャンセル / Delete で解除" : "クリックして新しいキーを記録")
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape → cancel without changing the descriptor.
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            // Backspace / Delete → clear binding.
            if event.keyCode == UInt16(kVK_Delete) {
                let cleared = HotkeyDescriptor(keyCode: 0, modifiers: [])
                descriptor = cleared
                onRecord?(cleared)
                stopRecording()
                return nil
            }

            let mods = modifierNames(from: event.modifierFlags)
            let new = HotkeyDescriptor(keyCode: UInt32(event.keyCode), modifiers: mods)
            descriptor = new
            onRecord?(new)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if flags.contains(.control)  { out.append("control") }
        if flags.contains(.option)   { out.append("option") }
        if flags.contains(.shift)    { out.append("shift") }
        if flags.contains(.command)  { out.append("command") }
        return out
    }
}
