import AppKit
import SwiftUI

/// 貼付直後に右下に出る一瞬のトースト。
/// 「貼ったぞ」というフィードバックを Pasty 自身が前面化せずに伝えるための最小UI。
@MainActor
final class PasteToast {
    static let shared = PasteToast()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<ToastContent>?
    private var hideTask: Task<Void, Never>?

    private init() {}

    /// `targetApp` には `PreviousAppTracker.shared.previous?.localizedName` を渡す想定。
    /// `customMessage` を指定するとそれが優先される。
    /// `near` を指定するとそのスクリーン座標 (左下原点) の近くにトーストを表示する。
    /// 省略時は従来通りメインスクリーンの右下。
    func show(targetApp: String?,
              customMessage: String? = nil,
              durationSeconds: TimeInterval = 0.8,
              near anchor: NSPoint? = nil) {
        let message: String
        if let customMessage, !customMessage.isEmpty {
            message = customMessage
        } else if let app = targetApp, !app.isEmpty {
            message = "📋 \(app) に貼付"
        } else {
            message = "📋 貼付完了"
        }

        let panel = ensurePanel()
        hostingView?.rootView = ToastContent(text: message)

        // Hosting のレイアウトを確定させてから位置を決める。
        panel.layoutIfNeeded()
        let fitting = hostingView?.fittingSize ?? CGSize(width: 240, height: 44)
        let width = min(max(fitting.width, 220), 320)
        let height: CGFloat = 44

        // 位置決め: anchor が与えられていればその近く (ちょっと上 + 中央寄せ)。
        // なければアンカーがあるカーソル位置のスクリーン or メインスクリーンの
        // 右下フォールバック。
        let origin: CGPoint
        if let anchor = anchor {
            // anchor を含むスクリーンを優先
            let targetScreen = NSScreen.screens.first(where: { NSPointInRect(anchor, $0.frame) })
                ?? NSScreen.main
            let visible = targetScreen?.visibleFrame ?? NSScreen.main!.visibleFrame
            // アンカー位置のちょっと上、横方向は中央寄せ、画面端でクランプ
            var x = anchor.x - width / 2
            var y = anchor.y + 28
            x = max(visible.minX + 8, min(visible.maxX - width - 8, x))
            y = max(visible.minY + 8, min(visible.maxY - height - 8, y))
            origin = CGPoint(x: x, y: y)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            origin = CGPoint(
                x: visible.maxX - 24 - width,
                y: visible.minY + 24
            )
        } else {
            origin = .zero
        }
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)),
                       display: false)

        // 連続呼び出し時は古いタイマーを破棄し、フェードを最新化。
        hideTask?.cancel()
        hideTask = nil

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, let panel = self.panel else { return }
            // 完了時にまだ alpha が 0 のままなら隠す（途中で show が来ていたら触らない）。
            if panel.alphaValue <= 0.01 {
                panel.orderOut(nil)
            }
        })
    }

    // MARK: - Panel setup

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.alphaValue = 0

        let host = NSHostingView(rootView: ToastContent(text: ""))
        host.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container

        self.panel = panel
        self.hostingView = host
        return panel
    }
}

// MARK: - Override key/main behavior on NSPanel

// NSPanel はサブクラスを作らずプロパティで挙動を制御できるため、
// `canBecomeKey` をブロックしたい場合はカテゴリで上書きする。
extension NSPanel {
    // `nonactivatingPanel` + `canBecomeKey == false` でフォーカス奪取を防ぐ。
    // ただし既存パネル（SpotlightPanel 等）が key を必要としているので、
    // ここでは override せずスタイルマスクのみで制御する。
}

// MARK: - SwiftUI content

private struct ToastContent: View {
    let text: String

    var body: some View {
        HStack(spacing: PastyDesign.Spacing.sm + 2) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PastyDesign.Color.accent)
            Text(text)
                .font(PastyDesign.TypeRamp.bodyMedium)
                .foregroundStyle(PastyDesign.Color.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, PastyDesign.Spacing.md + 2)
        .padding(.vertical, PastyDesign.Spacing.sm + 2)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: PastyDesign.Radius.md, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PastyDesign.Radius.md, style: .continuous)
                .strokeBorder(PastyDesign.Color.border, lineWidth: 0.5)
        )
        .pastyShadow(PastyDesign.Shadow.soft)
    }
}
