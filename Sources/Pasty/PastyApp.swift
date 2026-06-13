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

/// accessory app では設定画面を **複数の経路** で粘り強く呼ばないと
/// 単発で開かないことがあるので、堅牢に開くヘルパ。
@MainActor
func openSettingsWindowRobustly() {
    // accessory のままだとフォーカスが安定しない時があるので、一時的に
    // regular に切り替えてから設定を呼び、Dock アイコンが出るタイミングを
    // 与える。最後に accessory に戻す（Dock から消える）。
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    let selectors = [
        Selector(("showSettingsWindow:")),
        Selector(("showPreferencesWindow:")),
        Selector(("orderFrontPreferencesPanel:"))
    ]
    var fired = false
    for sel in selectors {
        if NSApp.sendAction(sel, to: nil, from: nil) {
            fired = true
            break
        }
    }
    if !fired {
        // それでもダメな場合、既に開かれている Settings ウィンドウを探して前面化。
        for w in NSApp.windows where w.title.localizedCaseInsensitiveContains("settings")
            || w.title.localizedCaseInsensitiveContains("preferences")
            || w.title.localizedCaseInsensitiveContains("設定") {
            w.makeKeyAndOrderFront(nil)
            fired = true
            break
        }
    }
    // 500ms 後に accessory に戻して Dock アイコンを片付ける。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if NSApp.windows.contains(where: { $0.isVisible
            && ($0.title.localizedCaseInsensitiveContains("settings")
            || $0.title.localizedCaseInsensitiveContains("preferences")
            || $0.title.localizedCaseInsensitiveContains("設定")) }) {
            // 設定が見えているなら、その間は regular のままにしておく
            return
        }
        NSApp.setActivationPolicy(.accessory)
    }
}
