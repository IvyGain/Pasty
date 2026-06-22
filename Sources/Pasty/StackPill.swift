import AppKit
import Combine
import SwiftUI

// MARK: - Panel

/// Floating, always-on-top pill that sits in the bottom-right corner of the
/// active screen and surfaces the current `PasteStack` count. It auto-hides
/// when the stack is empty and click-toggles between a compact badge and an
/// expanded list of recent items.
@MainActor
final class StackPillPanel: NSPanel {
    init() {
        let rect = NSRect(x: 0, y: 0, width: 96, height: 56)
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        titleVisibility = .hidden
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
    }

    // Pillはフォーカスを奪わない。直前アプリのキャレットを保つために key/main
    // にはならない。クリックは ignoresMouseEvents=false で受けられる。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View Model

/// SwiftUI 側から監視する軽量ビューモデル。`PasteStack` の `@Published items`
/// を Combine で購読し、件数と直近アイテムだけを公開する。
@MainActor
final class StackPillModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var expanded: Bool = false
}

// MARK: - Controller

@MainActor
final class StackPillController {
    static let shared = StackPillController()

    private var panel: StackPillPanel?
    private let model = StackPillModel()
    private var stack: PasteStack?
    private weak var coordinator: PanelCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserverToken: NSObjectProtocol?
    /// Coalesces rapid-fire clicks into a single paste at the controller level.
    /// SwiftUI Button taps can fire twice in quick succession on first activate;
    /// without this guard we observed the Pill repeatedly pasting into the host
    /// app. Reset on the main queue after a short cooldown.
    private var pasteInFlight: Bool = false

    private let collapsedSize = CGSize(width: 96, height: 56)
    private let expandedWidth: CGFloat = 320
    private let expandedHeaderHeight: CGFloat = 88
    private let expandedFooterHeight: CGFloat = 44
    private let expandedRowHeight: CGFloat = 52
    private let maxExpandedRows = 5
    private let edgeMargin: CGFloat = 24

    private init() {}

    deinit {
        if let token = screenObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: API

    /// `PasteStack` を購読開始する。複数回呼ばれても安全（既存購読は破棄）。
    func install(stack: PasteStack, coordinator: PanelCoordinator?) {
        self.stack = stack
        self.coordinator = coordinator

        cancellables.removeAll()
        stack.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.model.items = items
                if items.isEmpty {
                    self.model.expanded = false
                    self.hide()
                } else {
                    self.show()
                }
            }
            .store(in: &cancellables)

        // 画面構成が変わったら追従。マルチモニタやノッチ表示で位置がずれるのを防ぐ。
        if screenObserverToken == nil {
            screenObserverToken = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.repositionIfVisible() }
            }
        }

        // 初期状態の反映
        model.items = stack.items
        if stack.items.isEmpty {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = ensurePanel()
        layoutPanel(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Internals

    private func ensurePanel() -> StackPillPanel {
        if let panel { return panel }
        let panel = StackPillPanel()
        let root = StackPillRootView(
            model: model,
            onToggle: { [weak self] in self?.toggleExpanded() },
            onPaste: { [weak self] clip in self?.handlePaste(clip) },
            onPasteAll: { [weak self] in self?.handlePasteAll() },
            onClear: { [weak self] in self?.handleClear() }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.minSize]
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        panel.contentViewController = hosting
        self.panel = panel
        return panel
    }

    private func toggleExpanded() {
        model.expanded.toggle()
        if let panel { layoutPanel(panel) }
    }

    private func handlePaste(_ clip: ClipItem) {
        guard coordinator != nil else { return }
        guard !pasteInFlight else { return }
        pasteInFlight = true
        PasteAutomator.shared.paste(clip)
        // Pop the clip so the Stack reflects the consumed state immediately
        // and the same item can't be re-fired by a stray repeat tap.
        stack?.pop(clip)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pasteInFlight = false
        }
    }

    private func handlePasteAll() {
        guard coordinator != nil, let stack else { return }
        guard !pasteInFlight else { return }
        pasteInFlight = true
        stack.pasteAsDocument()   // pasteAsDocument() already clears the stack
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pasteInFlight = false
        }
    }

    private func handleClear() {
        stack?.clear()
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        layoutPanel(panel)
    }

    private func layoutPanel(_ panel: StackPillPanel) {
        let size = currentSize()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.setContentSize(size)
            return
        }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.maxX - edgeMargin - size.width,
            y: visible.minY + edgeMargin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func currentSize() -> CGSize {
        guard model.expanded else { return collapsedSize }
        let rows = min(maxExpandedRows, max(1, model.items.count))
        let height = CGFloat(rows) * expandedRowHeight
            + expandedHeaderHeight
            + expandedFooterHeight
        return CGSize(width: expandedWidth, height: height)
    }
}

// MARK: - SwiftUI

@MainActor
private struct StackPillRootView: View {
    @ObservedObject var model: StackPillModel
    let onToggle: () -> Void
    let onPaste: (ClipItem) -> Void
    let onPasteAll: () -> Void
    let onClear: () -> Void

    var body: some View {
        Group {
            if model.expanded {
                StackPillExpandedView(
                    items: Array(model.items.prefix(5)),
                    totalCount: model.items.count,
                    onToggle: onToggle,
                    onPaste: onPaste,
                    onPasteAll: onPasteAll,
                    onClear: onClear
                )
            } else {
                StackPillBadgeView(count: model.items.count, onToggle: onToggle)
            }
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: PastyDesign.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PastyDesign.Radius.lg, style: .continuous)
                .strokeBorder(PastyDesign.Color.border, lineWidth: 0.5)
        )
        .pastyShadow(PastyDesign.Shadow.lifted)
    }
}

@MainActor
private struct StackPillBadgeView: View {
    let count: Int
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: PastyDesign.Spacing.sm) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PastyDesign.Color.accent)
                Text("\(count)")
                    .font(PastyDesign.TypeRamp.title)
                    .monospacedDigit()
                    .foregroundStyle(PastyDesign.Color.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pasty Stack — クリックで展開")
    }
}

@MainActor
private struct StackPillExpandedView: View {
    let items: [ClipItem]
    let totalCount: Int
    let onToggle: () -> Void
    let onPaste: (ClipItem) -> Void
    let onPasteAll: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            list
            Divider().opacity(0.25)
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onPasteAll) {
                HStack(spacing: PastyDesign.Spacing.xs + 2) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 11, weight: .semibold))
                    Text("すべて貼付")
                        .font(PastyDesign.TypeRamp.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, PastyDesign.Spacing.md - 2)
                .padding(.vertical, PastyDesign.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: PastyDesign.Radius.sm, style: .continuous)
                        .fill(LinearGradient(
                            colors: [PastyDesign.Color.accent, PastyDesign.Color.secondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                )
                .pastyShadow(PastyDesign.Shadow.subtle)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(totalCount == 0)
            .help("Stack の全アイテムを連結して貼付")

            Spacer(minLength: 0)

            Button(action: onClear) {
                Text("クリア")
                    .font(PastyDesign.TypeRamp.caption)
                    .foregroundStyle(PastyDesign.Color.textSecondary)
                    .padding(.horizontal, PastyDesign.Spacing.md - 2)
                    .padding(.vertical, PastyDesign.Spacing.xs + 2)
                    .background(
                        RoundedRectangle(cornerRadius: PastyDesign.Radius.sm, style: .continuous)
                            .fill(PastyDesign.Color.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PastyDesign.Radius.sm, style: .continuous)
                            .strokeBorder(PastyDesign.Color.border, lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(totalCount == 0)
            .help("Stack を空にする")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: PastyDesign.Spacing.sm) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PastyDesign.Color.accent)
            Text("Stack")
                .font(PastyDesign.TypeRamp.title)
                .foregroundStyle(PastyDesign.Color.textPrimary)
            Spacer()
            Text("\(items.count)")
                .font(PastyDesign.TypeRamp.caption)
                .monospacedDigit()
                .foregroundStyle(PastyDesign.Color.textSecondary)
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("折り畳む")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 44)
    }

    private var list: some View {
        VStack(spacing: PastyTheme.rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                StackPillRow(item: item) { onPaste(item) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

@MainActor
private struct StackPillRow: View {
    let item: ClipItem
    let onPaste: () -> Void
    /// Local in-flight guard. Belt-and-suspenders with the controller-level
    /// `pasteInFlight`: even if SwiftUI re-fires the Button action, the row
    /// won't dispatch a second paste for the same item.
    @State private var pasteInFlight: Bool = false

    var body: some View {
        Button {
            guard !pasteInFlight else { return }
            pasteInFlight = true
            onPaste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pasteInFlight = false
            }
        } label: {
            HStack(spacing: PastyDesign.Spacing.sm + 2) {
                ClipThumbnail(clip: item, size: 24, corner: PastyDesign.Radius.sm)
                Text(previewText)
                    .font(PastyDesign.TypeRamp.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(PastyDesign.Color.textPrimary)
                Spacer(minLength: 0)
                Text("⌘V")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(PastyDesign.Color.textSecondary)
                    .padding(.horizontal, PastyDesign.Spacing.xs + 2)
                    .padding(.vertical, PastyDesign.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: PastyDesign.Radius.xs, style: .continuous)
                            .fill(PastyDesign.Color.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PastyDesign.Radius.xs, style: .continuous)
                            .strokeBorder(PastyDesign.Color.border, lineWidth: 0.5)
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pasteInFlight)
    }

    private var previewText: String {
        let raw = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "(空のクリップ)" : raw
    }
}
