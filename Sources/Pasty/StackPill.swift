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
    private var screenObserver: NSObjectProtocol?

    private let collapsedSize = CGSize(width: 96, height: 56)
    private let expandedWidth: CGFloat = 320
    private let expandedHeaderHeight: CGFloat = 88
    private let expandedRowHeight: CGFloat = 52
    private let maxExpandedRows = 5
    private let edgeMargin: CGFloat = 24

    private init() {}

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
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
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
            onPaste: { [weak self] clip in self?.handlePaste(clip) }
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
        PasteAutomator.shared.paste(clip)
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
        let height = CGFloat(rows) * expandedRowHeight + expandedHeaderHeight
        return CGSize(width: expandedWidth, height: height)
    }
}

// MARK: - SwiftUI

@MainActor
private struct StackPillRootView: View {
    @ObservedObject var model: StackPillModel
    let onToggle: () -> Void
    let onPaste: (ClipItem) -> Void

    var body: some View {
        Group {
            if model.expanded {
                StackPillExpandedView(
                    items: Array(model.items.prefix(5)),
                    onToggle: onToggle,
                    onPaste: onPaste
                )
            } else {
                StackPillBadgeView(count: model.items.count, onToggle: onToggle)
            }
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(PastyTheme.strokeOpacity), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
    }
}

@MainActor
private struct StackPillBadgeView: View {
    let count: Int
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("\(count)")
                    .font(PastyTheme.titleFont)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
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
    let onToggle: () -> Void
    let onPaste: (ClipItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            list
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Stack")
                .font(PastyTheme.titleFont)
            Spacer()
            Text("\(items.count)")
                .font(PastyTheme.subtitleFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
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

    var body: some View {
        Button(action: onPaste) {
            HStack(spacing: 10) {
                ClipThumbnail(clip: item, size: 24, corner: 6)
                Text(previewText)
                    .font(PastyTheme.subtitleFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("⌘V")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var previewText: String {
        let raw = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "(空のクリップ)" : raw
    }
}
