import AppKit
import SwiftUI

/// **Pasty's signature interaction.**
/// A 4-pixel transparent panel hugs the top edge of the screen with the
/// cursor on it. Hovering the notch (or, on non-notched Macs, the central
/// 20% strip) triggers a Liquid-Glass strip to slide down. The strip
/// supports drag-and-drop, so you can grab a clip and drop it directly
/// onto the editor below without a keyboard at all.
@MainActor
final class NotchHoverController: NSObject {
    private let store: ClipStore
    private let pinboards: PinboardStore
    private let stack: PasteStack
    private let selection: SelectionModel
    var onOpenSettings: () -> Void = {}

    private var triggerPanels: [NSPanel] = []
    private var dropdownPanel: NSPanel?
    /// `show()` で構築した SwiftUI ホスティング + パネルを **再利用** するための
    /// キャッシュ。最初の 1 度だけ構築コスト (~150ms) を払い、以降は
    /// `orderFrontRegardless` + `setFrame` だけで瞬時に表示できる。
    private var cachedPanel: NSPanel?
    private var hoverWorkItem: DispatchWorkItem?
    /// v0.8.5 以降は `SettingsStore.notchDwellMs` (default 0) を毎回読みに行く
    /// ので、ここではフォールバック専用。値 0 のとき `scheduleShow` は
    /// `dispatchAsyncAfter` を経由せず同期的に `show()` を叩き、知覚遅延を
    /// ゼロに近づける。
    private var dwellDelay: TimeInterval {
        TimeInterval(SettingsStore.shared.notchDwellMs) / 1000.0
    }
    /// `mouseExited` 後の閉じ判定を遅延させて、ホットゾーン直外を「ピクッ」と
    /// 横切ったときに即座に cancelShow されないようにする。50ms の grace。
    private var pendingCancellation: DispatchWorkItem?

    /// パネルが開いている間だけ動くマウス位置の見張り役。`NSPanel` の
    /// `mouseExited` は、プログラマティックに `NSHostingController` を
    /// 流し込んだケースでは安定して発火しない（`awakeFromNib` が走らない
    /// ためトラッキング登録のタイミングを逃す）。なので最後の砦として
    /// グローバルイベントとローカルイベントの両方を観測する。
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// パネル内でカーソルが Tab/Shift+Tab を押した時に、StripView のフォルダ
    /// 切替を発火させるためのキーイベントモニタ。NotchPanel は key にならない
    /// ので、通常の KeyHandlingView では拾えない。
    private var keyEventMonitor: Any?
    private var localKeyEventMonitor: Any?
    /// v0.8.5 N-5: モニタは prewarm 時に install して show 時には付け替え無し。
    /// `currentActiveFrame` が nil の間 (= dropdownPanel == nil) はモニタが
    /// 無効化と同等になる (closure 側で guard する)。
    private var currentActiveZone: NSRect?
    private var pointerInsidePanel: Bool = false
    private var pendingClose: DispatchWorkItem?
    /// マウスがパネルの矩形に「最低 1 回入った」フラグ。入る前に範囲外と
    /// 判断するとアニメーション最中に閉じてしまうので、ガードとして使う。
    private var pointerEnteredOnce: Bool = false
    /// 右クリックで開いた NSMenu が tracking 中は dismissal を完全に停止する。
    /// メニュー項目はパネル矩形の外に出るので、これを抑止しないと
    /// メニューを辿った瞬間にパネルが閉じてしまう。
    private var isContextMenuOpen: Bool = false
    /// クリップ編集 sheet が開いている間も同様に自動 dismissal を抑止する。
    private var isClipEditOpen: Bool = false
    /// `installContextMenuNotifications` を 1 回だけ呼ぶための idempotency フラグ。
    private var contextMenuObserverInstalled: Bool = false

    init(store: ClipStore,
         pinboards: PinboardStore,
         stack: PasteStack,
         selection: SelectionModel) {
        self.store = store
        self.pinboards = pinboards
        self.stack = stack
        self.selection = selection
        super.init()
    }

    /// Re-create trigger panels for every connected screen. Call once on
    /// launch and whenever the screen list changes.
    func install() {
        for p in triggerPanels { p.orderOut(nil) }
        triggerPanels.removeAll()

        for screen in NSScreen.screens {
            let panel = makeTriggerPanel(for: screen)
            triggerPanels.append(panel)
            panel.orderFrontRegardless()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        installContextMenuNotifications()
    }

    @objc private func screensChanged() { install() }

    /// NSMenu の tracking 開始 / 終了を観測して `isContextMenuOpen` を切り替える。
    /// `install()` から idempotent に 1 度だけ呼ばれる。
    private func installContextMenuNotifications() {
        guard !contextMenuObserverInstalled else { return }
        contextMenuObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isContextMenuOpen = true }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // 終了は少し遅延して、メニュー操作完了直後の pointer 判定を救う
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.isContextMenuOpen = false
            }
        }
        // 編集 sheet open/close 通知も同じく購読 → dismissal 抑止
        NotificationCenter.default.addObserver(
            forName: .pastyClipEditOpen, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isClipEditOpen = true }
        }
        NotificationCenter.default.addObserver(
            forName: .pastyClipEditClose, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isClipEditOpen = false }
        }
    }

    private func makeTriggerPanel(for screen: NSScreen) -> NSPanel {
        let zone = notchHotZone(on: screen)
        let panel = TriggerPanel(zone: zone)
        panel.onHoverEnter = { [weak self] in self?.scheduleShow(on: screen) }
        panel.onHoverExit  = { [weak self] in self?.scheduleCancelShow() }
        return panel
    }

    /// The rect we treat as the "notch" hot zone. On notched MacBooks the
    /// system advertises `safeAreaInsets.top`; we narrow the panel to the
    /// likely notch width. On other Macs we treat the central 20 % strip
    /// at the very top of the screen as a "virtual notch".
    private func notchHotZone(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let inset = screen.safeAreaInsets.top
        let height: CGFloat = max(inset > 0 ? min(inset, 14) : 24, 24)
        let topY = frame.maxY - height

        if inset > 0 {
            // Notched. Concentrate around the centre, ~220 pt wide.
            let width: CGFloat = 240
            return NSRect(x: frame.midX - width / 2,
                          y: topY,
                          width: width, height: height)
        } else {
            // Virtual notch: central 20 % of the top edge.
            let width = frame.width * 0.2
            return NSRect(x: frame.midX - width / 2,
                          y: topY,
                          width: width, height: height)
        }
    }

    private func scheduleShow(on screen: NSScreen) {
        guard SettingsStore.shared.notchHoverEnabled else { return }
        // mouseExited 直後の grace 期間中に再 enter したケースを救う。
        pendingCancellation?.cancel()
        pendingCancellation = nil
        cancelShow()
        // v0.8.5 N-3: dwellMs == 0 のときは dispatchAsyncAfter を一切経由せず
        // 同じ run-loop tick で show() を叩く。RunLoop 1 周分 (~1ms) と
        // DispatchWorkItem 生成コストを丸ごと飛ばし「mouseEntered → 即表示」を
        // 達成する。0 以外の時だけ従来通り asyncAfter で待つ。
        let dwell = dwellDelay
        if dwell <= 0 {
            show(on: screen)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.show(on: screen)
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    /// mouseExited 時の cancelShow を 50ms 遅延させる。ホットゾーンの縁を
    /// 「ピクッ」と横切っただけで開きかけのドロップダウンが消えないようにする。
    private func scheduleCancelShow() {
        pendingCancellation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.cancelShow()
        }
        pendingCancellation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func cancelShow() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
    }

    /// パネルと SwiftUI を 1 度だけ構築して使い回す。`install()` 直後に呼ぶと
    /// 起動時に投資できる (約 150ms の SwiftUI 初期化コスト)。
    func prewarm() {
        guard cachedPanel == nil else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = buildPanel(on: screen)
        // SwiftUI の `body` は最初に view が画面上に追加されるまで評価されない。
        // 初回 hover で `orderFrontRegardless` した瞬間に走ると一拍引っかかるので、
        // ここで一度オフスクリーンに表示 → layout → 退避 して `body` の初期評価を
        // 起動時に償却しておく。
        panel.setFrame(NSRect(x: -10000, y: -10000, width: 1, height: 1), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if let hosting = panel.contentViewController as? NSHostingController<StripView> {
            hosting.view.layoutSubtreeIfNeeded()
        } else {
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        // v0.8.5 N-4: panel.makeKey() のコストも起動時に償却する。
        // .nonactivatingPanel なので、現在のアプリのフォーカスは奪わない。
        // 直後に orderOut + alpha=1 戻しでユーザーには一切見えない。
        panel.makeKey()
        panel.orderOut(nil)
        panel.alphaValue = 1
        cachedPanel = panel
        // v0.8.5 N-5: マウス / キー モニタを起動時に install しておき、show()
        // でのコールを消す。currentActiveZone == nil の間はガードで no-op。
        installPersistentMonitors()
    }

    private func buildPanel(on screen: NSScreen) -> NSPanel {
        let visible = screen.visibleFrame
        let targetWidth: CGFloat = min(visible.width - 32, 1320)
        let panelHeight: CGFloat = 280
        let collapsed = NSRect(x: visible.midX - targetWidth / 2,
                               y: visible.maxY,
                               width: targetWidth, height: 0)
        let panel = NotchPanel(contentRect: collapsed)
        let view = StripView(
            store: store,
            pinboards: pinboards,
            stack: stack,
            selection: selection,
            mode: .notch,
            onDismiss: { [weak self] in self?.dismiss() },
            onOpenSettings: { [weak self] in self?.onOpenSettings() }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        return panel
    }

    func show(on screen: NSScreen) {
        if dropdownPanel != nil { return }
        // メニューバー直下に張り付ける。
        let visible = screen.visibleFrame
        let targetWidth: CGFloat = min(visible.width - 32, 1320)
        let panelHeight: CGFloat = 280
        let collapsed = NSRect(x: visible.midX - targetWidth / 2,
                               y: visible.maxY,
                               width: targetWidth, height: 0)
        let expanded = NSRect(x: collapsed.origin.x,
                              y: visible.maxY - panelHeight,
                              width: targetWidth, height: panelHeight)

        // キャッシュ済みパネルを優先的に再利用。初回 hover 時のみ
        // ビルドコスト (~150ms) が発生する。
        let panel: NSPanel
        if let cached = cachedPanel {
            panel = cached
        } else {
            panel = buildPanel(on: screen)
            cachedPanel = panel
        }
        // v0.8.5 N-2: anim==0 のときは折り畳み frame を経由せず最終位置に
        // 直接 setFrame する (1 描画で展開済みとして表示)。anim>0 の時だけ
        // collapsed → expanded の補間を走らせる。
        let animMs = SettingsStore.shared.notchAnimMs
        if animMs <= 0 {
            panel.setFrame(expanded, display: false)
        } else {
            panel.setFrame(collapsed, display: false)
        }

        // v0.8.5 N-6: orderFrontRegardless の直前にもう一度 layoutSubtreeIfNeeded を
        // 回しておくことで、初回 real show 時の SwiftUI 再評価コストを潰す。
        if let hosting = panel.contentViewController as? NSHostingController<StripView> {
            hosting.view.layoutSubtreeIfNeeded()
        }
        panel.orderFrontRegardless()
        // v0.8.5 N-4: makeKey() は prewarm() で既に 1 度払い済み。再度呼ぶのは
        // canBecomeKey=true の panel に対してフォーカスを戻すだけなので極めて安価。
        panel.makeKey()
        // ドロップダウン中は trigger panel が statusBar レベルで
        // ヘッダー上の操作 (フォルダタブクリック等) を奪うので一旦退避させる。
        for tp in triggerPanels { tp.orderOut(nil) }
        dropdownPanel = panel
        pointerEnteredOnce = false

        if animMs > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = TimeInterval(animMs) / 1000.0
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(expanded, display: true)
            }
        }

        // パネルが固定矩形になったあとの位置を「閉じる判定」の母集合にする。
        let activeFrame = expanded
        activateMonitors(activeFrame: activeFrame)
    }

    func dismiss() {
        guard let panel = dropdownPanel else { return }
        deactivateMonitors()
        let animMs = SettingsStore.shared.notchAnimMs
        if animMs <= 0 {
            // v0.8.5 N-2: 閉じる方向も即時化。setFrame を経由せず orderOut のみ。
            panel.orderOut(nil)
            self.dropdownPanel = nil
            for tp in self.triggerPanels { tp.orderFrontRegardless() }
            return
        }
        let frame = panel.frame
        let collapsed = NSRect(x: frame.origin.x,
                               y: frame.origin.y + frame.size.height,
                               width: frame.size.width, height: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = TimeInterval(animMs) / 1000.0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(collapsed, display: true)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // パネルは `cachedPanel` に保持したまま、`dropdownPanel` だけ
                // クリアする。次回 show() で同じ panel が即時再表示される。
                self.dropdownPanel = nil
                // ドロップダウン終了後に trigger panel を復活させて
                // 次のホバー検出を再開できるようにする。
                for tp in self.triggerPanels { tp.orderFrontRegardless() }
            }
        })
    }

    // MARK: - Mouse monitoring

    /// v0.8.5 N-5: マウス / キー モニタは **prewarm() の時点で 1 度だけ**
    /// install しておき、show / dismiss では `currentActiveZone` の更新と
    /// heartbeat の停止/再開だけを担当する。これで初回 show 時に発生していた
    /// `addGlobalMonitorForEvents` ×3 のコスト (数 ms) が完全に消える。
    /// closure 側は `dropdownPanel == nil` (= currentActiveZone == nil) の間は
    /// 何もしないので、パネル非表示時に外で動いていることによる害は無い。
    private func installPersistentMonitors() {
        // 既に install 済みなら no-op (multi-screen 等で複数回呼ばれる保険)。
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let zone = self.currentActiveZone else { return }
                self.evaluatePointer(against: zone)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in
                guard let zone = self.currentActiveZone else { return }
                self.evaluatePointer(against: zone)
            }
            return event
        }
        keyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                guard self.dropdownPanel != nil else { return }
                self.handleNotchKey(event)
            }
        }
        localKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Tab だけは Pasty 内でも横取りしてノッチ循環として消費する。
            // ただしパネルが表示されていないときは何もしない。
            if event.keyCode == 48, self.dropdownPanel != nil {
                Task { @MainActor in self.handleNotchKey(event) }
                if self.pointerInsidePanel {
                    return nil
                }
            }
            return event
        }
    }

    /// show() から呼ばれて、現在のパネル位置を判定母集合として登録する。
    /// モニタ本体は既に install 済み。
    private func activateMonitors(activeFrame: NSRect) {
        let inflate: CGFloat = 12     // 1〜2 px の縁を超えただけで閉じないように
        currentActiveZone = activeFrame.insetBy(dx: -inflate, dy: -inflate)
        // マウスが動かない場合の保険として 0.18 s 毎に判定を回す。
        if let zone = currentActiveZone {
            scheduleHeartbeat(against: zone)
        }
    }

    /// dismiss() から呼ばれて、判定母集合をクリアする。モニタは生かしたまま。
    private func deactivateMonitors() {
        currentActiveZone = nil
        pointerInsidePanel = false
        pendingClose?.cancel()
        pendingClose = nil
    }

    private func handleNotchKey(_ event: NSEvent) {
        guard pointerInsidePanel, dropdownPanel != nil else { return }
        // Tab キーコード = 48
        guard event.keyCode == 48 else { return }
        let shift = event.modifierFlags.contains(.shift)
        NotificationCenter.default.post(
            name: shift ? .pastyNotchCycleFolderBackward
                        : .pastyNotchCycleFolderForward,
            object: nil
        )
    }

    private func scheduleHeartbeat(against zone: NSRect) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluatePointer(against: zone)
            if self.dropdownPanel != nil {
                self.scheduleHeartbeat(against: zone)
            }
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func evaluatePointer(against zone: NSRect) {
        guard dropdownPanel != nil else { return }
        // コンテキストメニュー操作中は dismissal を完全スキップ。
        // メニュー項目はパネル矩形の外に出るので、これを抑止しないと
        // メニューを辿った瞬間にパネルが閉じてしまう。
        if isContextMenuOpen { return }
        if isClipEditOpen { return }
        let p = NSEvent.mouseLocation
        let inside = NSPointInRect(p, zone)
        pointerInsidePanel = inside
        if inside {
            pointerEnteredOnce = true
            return
        }
        // まだ一度も入っていない場合は猶予。
        // （スライドダウン中にユーザのカーソルがノッチから少し離れているケース）
        guard pointerEnteredOnce else { return }
        dismiss()
    }

    private func removeMouseMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor  { NSEvent.removeMonitor(m) }
        if let m = keyEventMonitor    { NSEvent.removeMonitor(m) }
        if let m = localKeyEventMonitor { NSEvent.removeMonitor(m) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        keyEventMonitor = nil
        localKeyEventMonitor = nil
        pointerInsidePanel = false
        pendingClose?.cancel()
        pendingClose = nil
    }
}

/// Thin transparent strip pinned to the top of the screen. Forwards
/// mouse enter/exit to the coordinator without ever stealing focus.
private final class TriggerPanel: NSPanel {
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?
    private let trackingView: HoverView

    init(zone: NSRect) {
        self.trackingView = HoverView(frame: NSRect(origin: .zero, size: zone.size))
        super.init(
            contentRect: zone,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = trackingView
        trackingView.onEnter = { [weak self] in self?.onHoverEnter?() }
        trackingView.onExit  = { [weak self] in self?.onHoverExit?() }
        setFrame(zone, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let new = NSTrackingArea(rect: bounds,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self,
                                 userInfo: nil)
        addTrackingArea(new)
        tracking = new
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
}

private final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        titleVisibility = .hidden
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
    }

    // Tab / 矢印 / Enter を直に届けるため key になれる。nonactivatingPanel と
    // 組み合わせると、見かけ上のフォーカスは元アプリのままになる。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

