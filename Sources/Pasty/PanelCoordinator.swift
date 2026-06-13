import AppKit
import SwiftUI

@MainActor
final class PanelCoordinator: ObservableObject {
    private let store: ClipStore
    private let pinboards: PinboardStore
    private let stack: PasteStack
    private let selection: SelectionModel

    private var spotlight: SpotlightPanel?
    private var strip: StripPanel?
    let notch: NotchHoverController

    init(store: ClipStore,
         pinboards: PinboardStore,
         stack: PasteStack,
         selection: SelectionModel) {
        self.store = store
        self.pinboards = pinboards
        self.stack = stack
        self.selection = selection
        let notch = NotchHoverController(
            store: store, pinboards: pinboards, stack: stack,
            selection: selection
        )
        self.notch = notch
        // 初期化後に self を参照できるようになるので、ここで設定ハンドラを接続。
        notch.onOpenSettings = { [weak self] in self?.openSettings() }
    }

    func installHotkeys() {
        // ⇧⌘V → 設定で選んだプライマリサーフェスを開く（デフォルト Spotlight）
        HotKeyManager.shared.register(.init(keyCode: KeyCode.v, modifiers: [.command, .shift])) {
            [weak self] in self?.togglePrimary()
        }
        // ⌥⇧V → セカンダリサーフェス（プライマリの逆側）を開く
        HotKeyManager.shared.register(.init(keyCode: KeyCode.v, modifiers: [.option, .shift])) {
            [weak self] in self?.toggleSecondary()
        }
        HotKeyManager.shared.register(.init(keyCode: KeyCode.p, modifiers: [.control, .shift])) {
            SettingsStore.shared.pause(forSeconds: 60)
            NSSound(named: "Tink")?.play()
        }
    }

    func togglePrimary() {
        switch SettingsStore.shared.primarySurface {
        case .spotlight: toggleSpotlight()
        case .strip:     toggleStrip()
        }
    }

    func toggleSecondary() {
        switch SettingsStore.shared.primarySurface {
        case .spotlight: toggleStrip()
        case .strip:     toggleSpotlight()
        }
    }

    func installNotchHover() {
        if SettingsStore.shared.notchHoverEnabled {
            notch.install()
        }
    }

    // MARK: - Spotlight

    func toggleSpotlight() {
        if let s = spotlight, s.isVisible { dismissSpotlight() }
        else { showSpotlight() }
    }

    func showSpotlight() {
        let panel = spotlight ?? makeSpotlight()
        spotlight = panel
        positionAtCursorScreen(panel: panel, fractionFromTop: 0.30)
        // NSApp.activate(...) は呼ばない。直前アプリのフォーカスを温存することで
        // 「Pastyに戻ってから貼付」の遷移時に元アプリのキャレット位置が消えない。
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissSpotlight() {
        spotlight?.orderOut(nil)
    }

    private func makeSpotlight() -> SpotlightPanel {
        let panel = SpotlightPanel()
        let view = SpotlightView(
            store: store,
            pinboards: pinboards,
            stack: stack,
            selection: selection,
            onDismiss: { [weak self] in self?.dismissSpotlight() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        let hosting = NSHostingController(rootView: view)
        // パネルのサイズに追随させる。明示サイズなしだと SwiftUI の intrinsic
        // が極端に細長くなり日本語で縦書きのように崩れる。
        hosting.sizingOptions = [.minSize, .intrinsicContentSize]
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        panel.contentViewController = hosting
        return panel
    }

    // MARK: - Strip

    func toggleStrip() {
        guard SettingsStore.shared.stripPanelEnabled else { return }
        if let s = strip, s.isVisible { dismissStrip() }
        else { showStrip() }
    }

    func showStrip() {
        let panel = strip ?? makeStrip()
        strip = panel
        if let screen = NSScreen.cursorScreen() {
            panel.position(onScreen: screen)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissStrip() {
        strip?.orderOut(nil)
    }

    private func makeStrip() -> StripPanel {
        let panel = StripPanel()
        let view = StripView(
            store: store,
            pinboards: pinboards,
            stack: stack,
            selection: selection,
            onDismiss: { [weak self] in self?.dismissStrip() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.minSize]
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        panel.contentViewController = hosting
        return panel
    }

    /// 各サーフェスから設定画面を開くための共通ヘルパー。
    /// メニューバーの "Settings…" と同じ振る舞いをパネルから呼べる。
    func openSettings() {
        // パネルを片付けてから設定画面を出す（重なり防止）
        dismissSpotlight()
        dismissStrip()
        NotificationCenter.default.post(name: .pastyOpenSettings, object: nil)
    }

    // MARK: - Positioning

    private func positionAtCursorScreen(panel: NSPanel, fractionFromTop: CGFloat) {
        guard let screen = NSScreen.cursorScreen() else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - (visible.height * fractionFromTop)
        )
        panel.setFrameOrigin(origin)
    }
}

extension NSScreen {
    static func cursorScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) ?? .main
    }
}
