import AppKit
import Combine
import SwiftUI

@MainActor
final class PanelCoordinator: ObservableObject {
    private let store: ClipStore
    private let pinboards: PinboardStore
    private let stack: PasteStack
    private let selection: SelectionModel

    // SpotlightPanel は Raycast 拡張に責務移譲済み。Pasty 本体には残らない。
    private var strip: StripPanel?
    let notch: NotchHoverController

    /// IDs returned by HotKeyManager so we can wipe + rebuild whenever
    /// the user changes a binding in Settings.
    private var installedHotkeyIDs: [UInt32] = []
    /// Subscription on `HotkeyStore.shared.$bindings`. Held so the Combine
    /// pipeline lives as long as the coordinator does.
    private var hotkeyBindingsCancellable: AnyCancellable?

    /// パネルが召喚された瞬間のマウス位置（全画面座標、左下原点）。
    /// 貼付時にこの位置へ合成クリックを送って「マウスがあった場所」へ
    /// テキストキャレットを移してから ⌘V を撃つために使う。
    private(set) var summonPoint: NSPoint?

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
        // 1) 初回の登録
        rebuildHotkeys()

        // 2) HotkeyStore のバインディング変更を購読し、変更があれば全部
        //    unregister → 再登録。dropFirst() で「現在値」での即時発火は
        //    避け、ユーザーの編集操作のみに反応する。SwiftUI が一度の
        //    キーストロークで複数 didSet を撃ち込んでも RunLoop.main 経由で
        //    1 サイクルにまとめてから再登録する。
        hotkeyBindingsCancellable = HotkeyStore.shared.$bindings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildHotkeys()
            }
    }

    /// Read the current `HotkeyStore` bindings and (re)register them all
    /// with `HotKeyManager`. Always called on the main thread because the
    /// underlying Carbon API installs handlers against the main run loop.
    private func rebuildHotkeys() {
        // Tear down any previously installed registrations. We use the
        // generic `unregisterAll` rather than tracked IDs to also catch
        // anything a future call site might add outside this method.
        HotKeyManager.shared.unregisterAll()
        installedHotkeyIDs.removeAll()

        let hotkeys = HotkeyStore.shared
        for action in HotkeyAction.allCases {
            let descriptor = hotkeys.descriptor(for: action)
            // keyCode == 0 means "unbound" — skip silently.
            if descriptor.isUnset || descriptor.keyCode == 0 { continue }
            if let id = HotKeyManager.shared.register(descriptor.carbonCombo,
                                                     action: handler(for: action)) {
                installedHotkeyIDs.append(id)
            }
        }
    }

    /// Maps a `HotkeyAction` to the closure HotKeyManager should fire.
    /// Returning a fresh closure keeps `[weak self]` captures localized to
    /// the actions that actually touch the coordinator's mutable state.
    private func handler(for action: HotkeyAction) -> () -> Void {
        switch action {
        case .primarySurface:
            return { [weak self] in self?.togglePrimary() }
        case .secondarySurface:
            return { [weak self] in self?.toggleSecondary() }
        case .pauseCapture:
            return {
                SettingsStore.shared.pause(forSeconds: 60)
                NSSound(named: "Tink")?.play()
            }
        case .undoPaste:
            return { PasteHistory.shared.undoLast() }
        case .aiRewrite:
            return { [weak self] in self?.runAIActionFromGlobalHotkey(.rewrite(tone: .formal)) }
        case .aiTranslate:
            return { [weak self] in self?.runAIActionFromGlobalHotkey(.translate(target: .auto)) }
        case .aiSummarize:
            return { [weak self] in self?.runAIActionFromGlobalHotkey(.summarize(length: .medium)) }
        case .aiReformat:
            return { [weak self] in self?.runAIActionFromGlobalHotkey(.reformat(to: .plainText)) }
        case .aiEmailify:
            return { [weak self] in self?.runAIActionFromGlobalHotkey(.emailify) }
        }
    }

    /// Global-hotkey entry point for AI actions. We pick the "current"
    /// clip by inspecting whichever Pasty panel is on screen and using
    /// the shared `SelectionModel.cursorIndex`; if no panel is open we
    /// surface a toast asking the user to open Pasty first.
    func runAIActionFromGlobalHotkey(_ action: AIAction) {
        let items = store.recent
        let panelOpen = (strip?.isVisible == true)

        let target: ClipItem?
        if panelOpen, items.indices.contains(selection.cursorIndex) {
            target = items[selection.cursorIndex]
        } else if panelOpen, let first = items.first {
            // Panel is open but selection somehow out of range — fall
            // back to the top of the list rather than refusing.
            target = first
        } else {
            target = nil
        }

        guard let clip = target else {
            PasteToast.shared.show(targetApp: nil,
                                   customMessage: "Pasty を開いてください")
            NSSound(named: "Funk")?.play()
            return
        }

        AIActionCoordinator.shared.execute(action, on: clip, store: store)
    }

    func togglePrimary() {
        toggleStrip()
    }

    /// `⌥⇧V` 用のセカンダリ。Spotlight モーダルが Raycast 拡張に移ったため、
    /// セカンダリも Strip トグルにする (ユーザーが既存のキーを温存しても困らない)。
    func toggleSecondary() {
        toggleStrip()
    }

    func installNotchHover() {
        if SettingsStore.shared.notchHoverEnabled {
            notch.install()
        }
    }

    /// ⇧⌘V を押した瞬間の体感を「ほぼゼロ」にするため、Strip パネルと
    /// SwiftUI ホスティングを **起動時に裏で生成しておく**。初回呼び出しの
    /// 200〜500ms の初期化コストが消える。
    func prewarmStrip() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.strip == nil {
                let panel = self.makeStrip()
                self.strip = panel
                // 一度 visibilityOff のまま位置だけ仕込んでおく
                if let screen = NSScreen.cursorScreen() {
                    panel.position(onScreen: screen)
                }
                // orderOut のままにして実画面には出さない
            }
        }
    }

    /// Esc 時の共通ハンドラ。Strip / Notch ドロップダウンを全部畳んで、
    /// フォーカスを直前アプリに返す。Spotlight は Raycast 拡張に移行済み。
    func dismissAll() {
        strip?.orderOut(nil)
        notch.dismiss()
    }

    // MARK: - Strip

    func toggleStrip() {
        guard SettingsStore.shared.stripPanelEnabled else { return }
        if let s = strip, s.isVisible { dismissStrip() }
        else { showStrip() }
    }

    func showStrip() {
        recordSummonPoint()
        let panel = strip ?? makeStrip()
        strip = panel
        if let screen = NSScreen.cursorScreen() {
            panel.position(onScreen: screen)
        }
        // orderFrontRegardless で「キー取得 + 順序昇格」のコストを節約。
        // makeKey はその後に呼んで KeyHandlingView が動作する状態にする。
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// パネルを召喚した瞬間のマウス座標を記録。`PasteAutomator` が貼付
    /// 直前にここへ合成クリックを送ることで、ユーザがカーソルを置いて
    /// いた場所にテキストキャレットを移してから ⌘V を撃てる。
    private func recordSummonPoint() {
        summonPoint = NSEvent.mouseLocation
        PasteAutomator.shared.summonMouseLocation = NSEvent.mouseLocation
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
            onDismiss: { [weak self] in self?.dismissAll() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        let hosting = NSHostingController(rootView: view)
        // sizingOptions を [] にして「コンテンツの minSize が変わってもパネルが
        // 動かない」挙動に。フォルダ切替や複数選択 bar 出現でパネルが上下に
        // ジャンプする現象を防ぐ。
        hosting.sizingOptions = []
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        panel.contentViewController = hosting
        return panel
    }

    /// 各サーフェスから設定画面を開くための共通ヘルパー。
    /// メニューバーの "Settings…" と同じ振る舞いをパネルから呼べる。
    func openSettings() {
        // パネルを片付けてから設定画面を出す（重なり防止）
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
