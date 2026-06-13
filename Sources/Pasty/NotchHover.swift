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
        panel.onMouseExit = { [weak self] in
            // Small grace period so users moving downward can drop onto an
            // editor without the panel snapping shut beneath them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.dismiss()
            }
        }
        panel.orderFrontRegardless()
        dropdownPanel = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(expanded, display: true)
        }
    }

    func dismiss() {
        guard let panel = dropdownPanel else { return }
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
    var onMouseExit: (() -> Void)?
    private var tracking: NSTrackingArea?

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

    override func awakeFromNib() {
        super.awakeFromNib()
        addExitTracking()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }

    private func addExitTracking() {
        guard let view = contentView else { return }
        let area = NSTrackingArea(rect: view.bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        view.addTrackingArea(area)
        tracking = area
    }
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
