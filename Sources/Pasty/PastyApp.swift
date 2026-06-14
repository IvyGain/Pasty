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
    @StateObject private var selection: SelectionModel

    init() {
        let store: ClipStore
        do { store = try ClipStore.shared() }
        catch { fatalError("Failed to open ClipStore: \(error)") }

        // PasteHistory など ClipStore を持たないシングルトンから
        // 貼付イベントを永続化できるよう、共有コンテナにも差し込んでおく。
        ClipStoreContainer.shared.store = store

        let pinboards = PinboardStore(dbWriter: store.dbWriter)
        PinboardStoreContainer.shared.pinboards = pinboards
        let stack = PasteStack()
        let selection = SelectionModel()
        let coordinator = PanelCoordinator(store: store, pinboards: pinboards,
                                           stack: stack, selection: selection)
        let observer = PasteboardObserver(store: store)

        // 直前アプリの追跡を起動。Pastyが召喚されても元のアプリを記憶し続ける。
        _ = PreviousAppTracker.shared

        _store = StateObject(wrappedValue: store)
        _pinboards = StateObject(wrappedValue: pinboards)
        _stack = StateObject(wrappedValue: stack)
        _coordinator = StateObject(wrappedValue: coordinator)
        _observer = StateObject(wrappedValue: observer)
        _settings = StateObject(wrappedValue: .shared)
        _selection = StateObject(wrappedValue: selection)

        // Defer hotkey & notch install until after the run loop is alive.
        let installable = coordinator
        let store2 = store
        DispatchQueue.main.async {
            installable.installHotkeys()
            installable.installNotchHover()
            installable.prewarmStrip()
            _ = PasteAutomator.shared.ensureAccessibilityPermission(prompt: true)

            // Subscribe to settings notifications.
            NotificationCenter.default.addObserver(forName: .pastyWipeAll,
                                                   object: nil, queue: .main) { _ in
                Task { try? await store2.deleteAll() }
            }
            NotificationCenter.default.addObserver(forName: .pastyOpenSettings,
                                                   object: nil, queue: .main) { _ in
                openSettingsWindowRobustly()
            }

            // 初回起動時のオンボーディング
            OnboardingPresenter.shared.presentIfNeeded {
                SettingsStore.shared.hasCompletedOnboarding = true
            }

            // フローティング Stack ピル（Stack に積まれている時だけ表示）
            if SettingsStore.shared.stackPillEnabled {
                StackPillController.shared.install(stack: stack, coordinator: coordinator)
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
                settings: settings,
                selection: selection
            )
        } label: {
            MenuBarLabel(isPaused: settings.isPaused)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, pinboards: pinboards, store: store)
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

/// 設定画面は SwiftUI の `Settings { }` シーンが accessory アプリだと
/// 信頼性低く開かない/閉じても残骸が残るので、自前で NSWindow を管理する。
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?
    private var policyObserver: NSObjectProtocol?

    private init() {}

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // SettingsView を NSHostingController でラップ
        let view = SettingsView(
            settings: .shared,
            pinboards: PinboardStoreContainer.shared.pinboards
                ?? PinboardStore(dbWriter: ClipStoreContainer.shared.store!.dbWriter),
            store: ClipStoreContainer.shared.store
        )
        let host = NSHostingController(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Pasty 設定"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.contentViewController = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)

        // 閉じたら accessory に戻す
        policyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w, queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }

        self.window = w
    }
}

/// 互換ヘルパ。既存呼び出し箇所はこの関数を通る。
@MainActor
func openSettingsWindowRobustly() {
    SettingsWindowManager.shared.show()
}

/// PinboardStore を SettingsWindowManager から取得できるようにするコンテナ。
@MainActor
final class PinboardStoreContainer {
    static let shared = PinboardStoreContainer()
    var pinboards: PinboardStore?
}
