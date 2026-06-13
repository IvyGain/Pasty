import SwiftUI
import AppKit

@main
struct PastyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store: ClipStore
    @StateObject private var pinboards: PinboardStore
    @StateObject private var stack: PasteStack
    @StateObject private var observer: PasteboardObserver
    @StateObject private var coordinator: PanelCoordinator
    @StateObject private var settings: SettingsStore

    init() {
        let store: ClipStore
        do { store = try ClipStore.shared() }
        catch { fatalError("Failed to open ClipStore: \(error)") }

        let pinboards = PinboardStore(dbWriter: store.dbWriter)
        let stack = PasteStack()
        let coordinator = PanelCoordinator(store: store, pinboards: pinboards, stack: stack)
        let observer = PasteboardObserver(store: store)

        _store = StateObject(wrappedValue: store)
        _pinboards = StateObject(wrappedValue: pinboards)
        _stack = StateObject(wrappedValue: stack)
        _coordinator = StateObject(wrappedValue: coordinator)
        _observer = StateObject(wrappedValue: observer)
        _settings = StateObject(wrappedValue: .shared)

        // Defer hotkey & notch install until after the run loop is alive.
        let installable = coordinator
        let store2 = store
        DispatchQueue.main.async {
            installable.installHotkeys()
            installable.installNotchHover()
            _ = PasteAutomator.shared.ensureAccessibilityPermission(prompt: true)

            // Subscribe to settings notifications.
            NotificationCenter.default.addObserver(forName: .pastyWipeAll,
                                                   object: nil, queue: .main) { _ in
                Task { try? await store2.deleteAll() }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                store: store,
                pinboards: pinboards,
                observer: observer,
                coordinator: coordinator,
                settings: settings
            )
        } label: {
            MenuBarLabel(isPaused: settings.isPaused)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, pinboards: pinboards)
        }
    }
}

private struct MenuBarLabel: View {
    let isPaused: Bool
    var body: some View {
        Image(systemName: isPaused ? "doc.on.clipboard.fill" : "doc.on.clipboard")
            .symbolRenderingMode(isPaused ? .multicolor : .monochrome)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
