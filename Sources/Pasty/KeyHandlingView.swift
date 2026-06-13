import SwiftUI
import AppKit

/// SwiftUI パネル用の不可視 NSView。⌥↩、⇧↑/↓、⌘A など、SwiftUI 標準では
/// 拾いにくいキーイベントをここで横取りして閉じたクロージャに渡す。
struct KeyHandlingView: NSViewRepresentable {
    var onUp: () -> Void = {}
    var onDown: () -> Void = {}
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    var onReturn: () -> Void = {}
    var onShiftReturn: () -> Void = {}
    var onOptionReturn: () -> Void = {}
    var onEsc: () -> Void = {}
    var onNumber: (Int) -> Void = { _ in }
    var onSpace: () -> Void = {}
    var onTab: () -> Void = {}
    var onShiftUp: () -> Void = {}
    var onShiftDown: () -> Void = {}
    var onCmdA: () -> Void = {}
    var onCmdE: () -> Void = {}
    var onCmdR: () -> Void = {}
    var onCmdF: () -> Void = {}
    var onCmdN: () -> Void = {}
    var onCmdD: () -> Void = {}
    var onCmdI: () -> Void = {}
    var onCmdM: () -> Void = {}
    var onCmdComma: () -> Void = {}
    var onDelete: () -> Void = {}

    func makeNSView(context: Context) -> KeyCatcher {
        let v = KeyCatcher()
        v.coordinator = context.coordinator
        return v
    }
    func updateNSView(_ nsView: KeyCatcher, context: Context) { nsView.coordinator = context.coordinator }
    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    final class Coordinator {
        let view: KeyHandlingView
        init(view: KeyHandlingView) { self.view = view }
    }

    final class KeyCatcher: NSView {
        weak var coordinator: Coordinator?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            guard let v = coordinator?.view else { super.keyDown(with: event); return }
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            let opt = event.modifierFlags.contains(.option)
            switch event.keyCode {
            case 126: shift ? v.onShiftUp()   : v.onUp(); return
            case 125: shift ? v.onShiftDown() : v.onDown(); return
            case 123: v.onLeft(); return
            case 124: v.onRight(); return
            case 36, 76:
                if opt   { v.onOptionReturn(); return }
                if shift { v.onShiftReturn();  return }
                v.onReturn(); return
            case 53: v.onEsc(); return
            case 49: v.onSpace(); return
            case 48: v.onTab(); return
            case 51, 117: v.onDelete(); return
            default: break
            }
            if let chars = event.charactersIgnoringModifiers {
                if cmd, chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
                    v.onNumber(digit); return
                }
                if cmd {
                    switch chars.lowercased() {
                    case "a": v.onCmdA(); return
                    case "e": v.onCmdE(); return
                    case "r": v.onCmdR(); return
                    case "f": v.onCmdF(); return
                    case "n": v.onCmdN(); return
                    case "d": v.onCmdD(); return
                    case "i": v.onCmdI(); return
                    case "m": v.onCmdM(); return
                    case ",": v.onCmdComma(); return
                    default: break
                    }
                }
            }
            super.keyDown(with: event)
        }
    }
}
