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
    private var pendingClose: DispatchWorkItem?
    /// マウスがパネルの矩形に「最低 1 回入った」フラグ。入る前に範囲外と
    /// 判断するとアニメーション最中に閉じてしまうので、ガードとして使う。
    private var pointerEnteredOnce: Bool = false

    init(store: ClipStore, pinboards: PinboardStore, stack: PasteStack) {
        self.store = store
        self.pinboards = pinboards
        self.stack = stack
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
    }

    @objc private func screensChanged() { install() }

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
        let frame = screen.frame
        let targetWidth: CGFloat = min(frame.width - 32, 1280)
        let collapsed = NSRect(x: frame.midX - targetWidth / 2,
                               y: frame.maxY,
                               width: targetWidth, height: 0)
        let expanded = NSRect(x: collapsed.origin.x,
                              y: frame.maxY - 220,
                              width: targetWidth, height: 220)

        let panel = NotchPanel(contentRect: collapsed)
        let hosting = NSHostingController(rootView:
            NotchDropdownView(
                store: store,
                pinboards: pinboards,
                stack: stack,
                onDismiss: { [weak self] in self?.dismiss() }
            )
        )
        panel.contentViewController = hosting
        panel.orderFrontRegardless()
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
            Task { @MainActor [weak self] in self?.dropdownPanel = nil }
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
        let p = NSEvent.mouseLocation
        let inside = NSPointInRect(p, zone)
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
        globalMouseMonitor = nil
        localMouseMonitor = nil
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private struct NotchDropdownView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var pinboards: PinboardStore
    @ObservedObject var stack: PasteStack
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.tint)
                Text("Pasty · drag a clip downward")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(pinboards.boards.prefix(4)) { board in
                    HStack(spacing: 3) {
                        Circle().fill(Color(hex: board.colorHex)).frame(width: 7, height: 7)
                        Text(board.name).font(.caption2)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.recent.prefix(20)) { clip in
                        NotchCard(clip: clip)
                            .draggable(clip.content ?? clip.preview) {
                                NotchCard(clip: clip)
                                    .frame(width: 120, height: 120)
                            }
                            .onTapGesture {
                                onDismiss()
                                PasteAutomator.shared.paste(clip)
                            }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 14)
            }
        }
        .background(VisualEffectBackground())
        .clipShape(.rect(
            topLeadingRadius: 0,
            bottomLeadingRadius: PastyTheme.cornerRadius,
            bottomTrailingRadius: PastyTheme.cornerRadius,
            topTrailingRadius: 0
        ))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: PastyTheme.cornerRadius,
                bottomTrailingRadius: PastyTheme.cornerRadius,
                topTrailingRadius: 0
            )
            .strokeBorder(Color.white.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
        )
    }
}

private struct NotchCard: View {
    let clip: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: clip.kind.iconName)
                    .foregroundStyle(.tint)
                Text(clip.sourceAppName ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(clip.preview)
                .font(.caption)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(8)
        .frame(width: 150, height: 130, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }
}
