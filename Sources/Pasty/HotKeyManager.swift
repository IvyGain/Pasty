import Foundation
import Carbon.HIToolbox
import AppKit

/// Lightweight Carbon-based global hotkey manager.
/// In-tree to avoid pulling another SPM dependency for ~80 lines of code.
final class HotKeyManager {
    typealias Action = () -> Void

    enum Modifier {
        case command, option, control, shift

        var carbonValue: UInt32 {
            switch self {
            case .command: return UInt32(cmdKey)
            case .option:  return UInt32(optionKey)
            case .control: return UInt32(controlKey)
            case .shift:   return UInt32(shiftKey)
            }
        }
    }

    struct Combo: Hashable {
        let keyCode: UInt32        // Carbon key code, e.g. kVK_ANSI_V == 9
        let modifiers: Set<Modifier>
        var carbonModifiers: UInt32 { modifiers.reduce(0) { $0 | $1.carbonValue } }
    }

    static let shared = HotKeyManager()

    private var registrations: [UInt32: (EventHotKeyRef, Action)] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    @discardableResult
    func register(_ combo: Combo, action: @escaping Action) -> UInt32? {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x50415354 /* 'PAST' */), id: id)

        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let ref = hotKeyRef else {
            NSLog("Pasty: failed to register hotkey (status=\(status))")
            return nil
        }
        registrations[id] = (ref, action)
        return id
    }

    func unregister(id: UInt32) {
        if let (ref, _) = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    /// Tear down every registered hotkey. Used when the user changes a
    /// binding so we can wipe the slate and re-register the full set.
    func unregisterAll() {
        for (_, value) in registrations {
            UnregisterEventHotKey(value.0)
        }
        registrations.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                guard let eventRef = eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    HotKeyManager.shared.registrations[hotKeyID.id]?.1()
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            nil
        )
    }
}

/// Common key code constants for clarity.
enum KeyCode {
    static let v: UInt32 = UInt32(kVK_ANSI_V)
    static let p: UInt32 = UInt32(kVK_ANSI_P)
    static let space: UInt32 = UInt32(kVK_Space)
}
