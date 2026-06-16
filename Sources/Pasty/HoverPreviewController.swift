import AppKit
import SwiftUI

/// Floating preview pill that appears after the user lingers on a clip card.
///
/// The controller is intentionally lightweight — it owns a single transparent
/// `NSPanel` that is reused across hovers. Hover scheduling is funneled through
/// a `DispatchWorkItem` so rapid mouse traversal across cards does not produce
/// a flicker of panels.
@MainActor
final class HoverPreviewController {

    // MARK: - Singleton

    static let shared = HoverPreviewController()

    // MARK: - Tunables

    /// Delay between `scheduleShow` and actual presentation.
    private let showDelay: TimeInterval = 0.5
    /// Auto dismiss safety net. ホバー解除は `cancel()` 側で即時消すので、
    /// これは「もしホバー終了通知を取り逃した場合の保険」。長めの 30 秒。
    private let autoDismissAfter: TimeInterval = 30
    /// Fade in / fade out duration.
    private let fadeDuration: TimeInterval = 0.16
    /// Offset applied to the cursor point. Positive X moves right, positive Y moves up
    /// (AppKit's screen coordinate system has Y growing upward).
    private let cursorOffset = NSSize(width: 16, height: 16)
    /// Safe margin from the screen edges.
    private let edgeInset: CGFloat = 8

    // MARK: - State

    private var panel: HoverPreviewPanel?
    private var pendingWork: DispatchWorkItem?
    private var autoDismissWork: DispatchWorkItem?
    /// The clip that is currently scheduled or showing. Used to avoid no-op
    /// reschedules for the same item.
    private var currentClipID: ClipItem.ID?

    private init() {}

    // MARK: - Public API

    /// Schedule a preview to appear after `showDelay` seconds for `clip`,
    /// anchored near `point` on `screen`. Calling again cancels any in-flight
    /// schedule and starts a fresh one — except when the same clip is already
    /// showing, in which case the call is ignored.
    func scheduleShow(for clip: ClipItem, near point: NSPoint, on screen: NSScreen?) {
        // If we're already showing this exact clip, just refresh the auto-dismiss
        // timer and bail — avoid the fade-out / fade-in flicker.
        if let panel, panel.isVisible, currentClipID == clip.id {
            scheduleAutoDismiss()
            return
        }

        cancelPending()
        // Dismiss any currently-visible (different) preview immediately so the
        // user always sees at most one floating pill.
        if let panel, panel.isVisible {
            fadeOutAndClose(panel: panel)
        }

        currentClipID = clip.id
        let targetScreen = screen ?? NSScreen.cursorScreen() ?? NSScreen.main

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.present(clip: clip, near: point, on: targetScreen)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    /// Cancel a pending presentation without disturbing an already-visible panel.
    func cancel() {
        cancelPending()
        // Active panel: fade it out as part of cancel — the typical caller
        // pattern is "mouse left the card", which means the preview is no
        // longer wanted.
        if let panel, panel.isVisible {
            fadeOutAndClose(panel: panel)
        }
        currentClipID = nil
    }

    /// Tear down everything synchronously. Use this for ESC keys or other
    /// "kill it now" pathways where a fade would feel laggy.
    func dismissNow() {
        cancelPending()
        autoDismissWork?.cancel()
        autoDismissWork = nil
        if let panel {
            panel.orderOut(nil)
            panel.alphaValue = 0
        }
        currentClipID = nil
    }

    // MARK: - Presentation

    private func present(clip: ClipItem, near point: NSPoint, on screen: NSScreen?) {
        let panel = ensurePanel()
        panel.setHostedClip(clip)
        panel.layoutIfNeeded()

        let size = panel.preferredContentSize()
        let origin = computeOrigin(for: size, near: point, on: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }

        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        autoDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.fadeOutAndClose(panel: panel)
            self.currentClipID = nil
        }
        autoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfter, execute: work)
    }

    private func fadeOutAndClose(panel: HoverPreviewPanel) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    // MARK: - Panel lifecycle

    private func ensurePanel() -> HoverPreviewPanel {
        if let panel { return panel }
        let panel = HoverPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0
        self.panel = panel
        return panel
    }

    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
    }

    private func computeOrigin(for size: NSSize, near point: NSPoint, on screen: NSScreen?) -> NSPoint {
        // AppKit screen Y grows upward. "Right-upper" means +X and +Y.
        var origin = NSPoint(
            x: point.x + cursorOffset.width,
            y: point.y + cursorOffset.height
        )
        guard let frame = screen?.visibleFrame else { return origin }

        if origin.x + size.width > frame.maxX - edgeInset {
            // Flip to the left of the cursor if we'd clip the right edge.
            origin.x = max(frame.minX + edgeInset, point.x - cursorOffset.width - size.width)
        }
        if origin.x < frame.minX + edgeInset {
            origin.x = frame.minX + edgeInset
        }
        if origin.y + size.height > frame.maxY - edgeInset {
            origin.y = frame.maxY - edgeInset - size.height
        }
        if origin.y < frame.minY + edgeInset {
            origin.y = frame.minY + edgeInset
        }
        return origin
    }
}

// MARK: - Panel

/// Borderless nonactivating panel that hosts the preview content. We subclass
/// only so we can override `canBecomeKey` / `canBecomeMain` and stash a
/// reusable hosting view.
private final class HoverPreviewPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var hosting: NSHostingView<HoverPreviewHost>?

    func setHostedClip(_ clip: ClipItem) {
        if let hosting {
            hosting.rootView = HoverPreviewHost(clip: clip)
        } else {
            let host = NSHostingView(rootView: HoverPreviewHost(clip: clip))
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.frame = contentView?.bounds ?? .zero
            contentView?.addSubview(host)
            hosting = host
        }
    }

    /// Ask SwiftUI what size it'd prefer, clamped to a reasonable pill range.
    /// 「一発で全文を見せる」優先のため大きく取る。クリップが極端に大きくても
    /// 画面外に出ない安全範囲だけ残す。
    func preferredContentSize() -> NSSize {
        guard let hosting else { return NSSize(width: 480, height: 280) }
        let fitting = hosting.fittingSize
        let width = min(max(fitting.width, 320), 760)
        let height = min(max(fitting.height, 120), 620)
        return NSSize(width: width, height: height)
    }

    func ensureLayout() {
        contentView?.layoutSubtreeIfNeeded()
    }
}

// MARK: - SwiftUI host

/// Tiny wrapper so the panel can swap clips without recreating the hosting view.
private struct HoverPreviewHost: View {
    let clip: ClipItem

    var body: some View {
        ClipPreviewView(clip: clip, isCompact: true)
            .padding(10)
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}
