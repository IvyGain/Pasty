import AppKit
import SwiftUI

/// 画面端をフラッシュさせる視覚フィードバック。Raycast の Focus 完了通知を
/// イメージ。透明な NSPanel を画面全体に被せ、4 辺に内向きグラデーションを
/// 描く。クリックは素通り (`ignoresMouseEvents = true`)。
///
/// 用途:
///   - 実行中 (`showRunning`) : 青の緩やかなパルス。明確な完了通知が来るまで継続。
///   - 成功    (`showSuccess`) : 緑を 1 回フラッシュ → 0.6 秒で fade out。
///   - 失敗    (`showFailure`) : 赤を 1 回フラッシュ → 0.8 秒で fade out。
@MainActor
final class ScreenGlowController {
    static let shared = ScreenGlowController()
    private init() {}

    private var panel: NSPanel?
    private var stateModel = GlowStateModel()
    private var dismissTask: Task<Void, Never>?

    func showRunning() {
        ensurePanel()
        dismissTask?.cancel()
        stateModel.state = .running
    }

    func showSuccess() {
        ensurePanel()
        dismissTask?.cancel()
        stateModel.state = .success
        // 短いフラッシュ → 自動で消す。
        scheduleDismiss(after: 0.7)
    }

    func showFailure() {
        ensurePanel()
        dismissTask?.cancel()
        stateModel.state = .failure
        scheduleDismiss(after: 0.9)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        stateModel.state = .hidden
        // フェード時間を待ってから panel を実際に閉じる。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.panel?.orderOut(nil)
        }
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func ensurePanel() {
        // パネルが残っていてもスクリーンが変わっている可能性があるので、
        // 現在のメインスクリーンの frame に毎回合わせる。
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame

        if let p = panel {
            p.setFrame(frame, display: false)
            p.orderFrontRegardless()
            return
        }

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isFloatingPanel = true
        // メニューバーよりは下、通常ウィンドウより上。statusBar 直下の階層。
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: GlowOverlay(model: stateModel))
        host.view.frame = NSRect(origin: .zero, size: frame.size)
        p.contentViewController = host
        p.orderFrontRegardless()
        panel = p
    }
}

// MARK: - State model + SwiftUI view

@MainActor
private final class GlowStateModel: ObservableObject {
    enum State { case hidden, running, success, failure }
    @Published var state: State = .hidden
}

private struct GlowOverlay: View {
    @ObservedObject var model: GlowStateModel

    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            // 4 辺にだけ色が乗る radial→edge グラデーション。中央は完全透明。
            edgeGradient
                .opacity(opacityForState)
                .scaleEffect(scaleForState)
                .animation(animationForState, value: model.state)
                .animation(.easeInOut(duration: 0.35), value: pulse)
        }
        .allowsHitTesting(false)
        .onChange(of: model.state) { _, new in
            if new == .running {
                // パルスを開始。
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse.toggle()
                }
            } else {
                pulse = false
            }
        }
    }

    // 中央透明 → 端だけ色が乗るマスク。実際の色は state ごとに切り替え。
    private var edgeGradient: some View {
        GeometryReader { geo in
            let color = colorForState
            // 内向き矩形のソフトフレーム。中央は透明。
            ZStack {
                LinearGradient(
                    colors: [color.opacity(0.65), .clear],
                    startPoint: .top, endPoint: .center
                )
                LinearGradient(
                    colors: [color.opacity(0.65), .clear],
                    startPoint: .bottom, endPoint: .center
                )
                LinearGradient(
                    colors: [color.opacity(0.55), .clear],
                    startPoint: .leading, endPoint: .center
                )
                LinearGradient(
                    colors: [color.opacity(0.55), .clear],
                    startPoint: .trailing, endPoint: .center
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .blendMode(.screen)
        }
    }

    private var colorForState: Color {
        switch model.state {
        case .hidden:  return .clear
        case .running: return Color(red: 0.30, green: 0.55, blue: 1.0)
        case .success: return Color(red: 0.30, green: 0.85, blue: 0.45)
        case .failure: return Color(red: 1.0, green: 0.35, blue: 0.35)
        }
    }

    private var opacityForState: Double {
        switch model.state {
        case .hidden:  return 0
        case .running: return pulse ? 0.55 : 0.25
        case .success: return 0.9
        case .failure: return 0.9
        }
    }

    private var scaleForState: CGFloat {
        switch model.state {
        case .hidden:  return 1.05
        case .running: return pulse ? 1.0 : 0.98
        case .success: return 1.0
        case .failure: return 1.0
        }
    }

    private var animationForState: Animation {
        switch model.state {
        case .hidden:  return .easeOut(duration: 0.25)
        case .running: return .easeInOut(duration: 0.6)
        case .success: return .easeOut(duration: 0.35)
        case .failure: return .easeOut(duration: 0.35)
        }
    }
}
