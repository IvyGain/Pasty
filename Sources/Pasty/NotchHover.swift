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
    private var hoverWorkItem: DispatchWorkItem?
    private var dwellDelay: TimeInterval = 0.22

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
    private var pointerInsidePanel: Bool = false
    private var pendingClose: DispatchWorkItem?
    /// マウスがパネルの矩形に「最低 1 回入った」フラグ。入る前に範囲外と
    /// 判断するとアニメーション最中に閉じてしまうので、ガードとして使う。
    private var pointerEnteredOnce: Bool = false
    /// 右クリックで開いた NSMenu が tracking 中は dismissal を完全に停止する。
    /// メニュー項目はパネル矩形の外に出るので、これを抑止しないと
    /// メニューを辿った瞬間にパネルが閉じてしまう。
    private var isContextMenuOpen: Bool = false
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
    }

    private func makeTriggerPanel(for screen: NSScreen) -> NSPanel {
        let zone = notchHotZone(on: screen)
        let panel = TriggerPanel(zone: zone)
        panel.onHoverEnter = { [weak self] in self?.scheduleShow(on: screen) }
        panel.onHoverExit  = { [weak self] in self?.cancelShow() }
        return panel
    }

    /// The rect we treat as the "notch" hot zone. On notched MacBooks the
    /// system advertises `safeAreaInsets.top`; we narrow the panel to the
    /// likely notch width. On other Macs we treat the central 20 % strip
    /// at the very top of the screen as a "virtual notch".
    private func notchHotZone(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let inset = screen.safeAreaInsets.top
        let height: CGFloat = max(inset > 0 ? min(inset, 14) : 4, 4)
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
        cancelShow()
        let work = DispatchWorkItem { [weak self] in
            self?.show(on: screen)
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellDelay, execute: work)
    }

    private func cancelShow() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
    }

    func show(on screen: NSScreen) {
        if dropdownPanel != nil { return }
        // メニューバー直下に張り付ける。screen.frame (物理上端) だと NotchPanel が
        // .floating level なので statusBar level のメニューバーに隠されて、ユーザー
        // 視点では 24pt 下にズレて見える。visibleFrame の上端 = メニューバー直下
        // に origin.y を合わせれば「謎の上余白」が消える。
        let visible = screen.visibleFrame
        let targetWidth: CGFloat = min(visible.width - 32, 1320)
        let panelHeight: CGFloat = 280
        let collapsed = NSRect(x: visible.midX - targetWidth / 2,
                               y: visible.maxY,
                               width: targetWidth, height: 0)
        let expanded = NSRect(x: collapsed.origin.x,
                              y: visible.maxY - panelHeight,
                              width: targetWidth, height: panelHeight)

        let panel = NotchPanel(contentRect: collapsed)
        // Strip と同じカルーセル/フォルダ UI を再利用。表示位置が違うだけで、
        // 操作感は完全に同じ。
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
        // sizingOptions を空にして「コンテンツが SwiftUI 内で変化してもパネルは
        // 動かさない」挙動に固定する。これがないとフォルダ切替や複数選択 bar の
        // 出現で SwiftUI コンテンツの minSize が変わり、その都度パネルが上下に
        // 動いてしまう。
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.orderFrontRegardless()
        // .nonactivatingPanel なので、makeKey しても直前のフォーカスアプリは
        // 入れ替わらない (ユーザー視点では元のアプリがアクティブのまま)。
        panel.makeKey()
        // ドロップダウン中は trigger panel が statusBar レベルで
        // ヘッダー上の操作 (フォルダタブクリック等) を奪うので一旦退避させる。
        for tp in triggerPanels { tp.orderOut(nil) }
        dropdownPanel = panel
        pointerEnteredOnce = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(expanded, display: true)
        }

        // パネルが固定矩形になったあとの位置を「閉じる判定」の母集合にする。
        let activeFrame = expanded
        installMouseMonitors(activeFrame: activeFrame)
    }

    func dismiss() {
        guard let panel = dropdownPanel else { return }
        removeMouseMonitors()
        let frame = panel.frame
        let collapsed = NSRect(x: frame.origin.x,
                               y: frame.origin.y + frame.size.height,
                               width: frame.size.width, height: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(collapsed, display: true)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dropdownPanel = nil
                // ドロップダウン終了後に trigger panel を復活させて
                // 次のホバー検出を再開できるようにする。
                for tp in self.triggerPanels { tp.orderFrontRegardless() }
            }
        })
    }

    // MARK: - Mouse monitoring

    /// マウスが `activeFrame`（パネルが完全に降りた時の矩形）の外に出たら
    /// 自動で閉じる。`mouseMoved` をグローバルに観測することで、別アプリ上
    /// にカーソルがあっても判定が止まらない。
    private func installMouseMonitors(activeFrame: NSRect) {
        removeMouseMonitors()
        let inflate: CGFloat = 12     // 1〜2 px の縁を超えただけで閉じないように
        let zone = activeFrame.insetBy(dx: -inflate, dy: -inflate)

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.evaluatePointer(against: zone) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in self.evaluatePointer(against: zone) }
            return event
        }
        globalMouseMonitor = global
        localMouseMonitor = local

        // モニタは move があった時しか発火しないので、マウスがそもそも
        // 動かない場合の保険として 0.18 s 毎にも判定を回す。
        scheduleHeartbeat(against: zone)

        // Tab/Shift+Tab を NSPanel が key になれないまま捕捉するための
        // グローバル keyDown モニタ。マウスがパネル上にある時だけ反応。
        installKeyMonitor()
    }

    /// ノッチパネルは canBecomeKey = false なので、SwiftUI 内の
    /// `KeyHandlingView` でも keyDown は届かない。グローバル keyDown を
    /// 監視して、マウスがパネル内にある時の Tab / Shift+Tab だけを横取りし、
    /// 通知センター経由で StripView のフォルダ循環を発火する。
    private func installKeyMonitor() {
        // グローバル (= 他アプリがフォーカス時) と local (= Pasty 自身がフォーカス時)
        // の両方を仕込んでおく。グローバルは Accessibility 権限がいるので、
        // 権限が無くても local だけは動く保険にもなる。
        keyEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handleNotchKey(event) }
        }
        localKeyEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            // Tab だけは Pasty 内でも横取りしてノッチ循環として消費する
            if event.keyCode == 48 {
                Task { @MainActor in self.handleNotchKey(event) }
                if self.pointerInsidePanel && self.dropdownPanel != nil {
                    return nil
                }
            }
            return event
        }
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

