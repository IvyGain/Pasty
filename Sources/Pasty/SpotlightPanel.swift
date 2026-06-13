import AppKit
import SwiftUI

/// Spotlight / Raycast-style center modal. Owned by `PanelCoordinator`,
/// shown by ⇧⌘V, dismissed by Esc or by pasting an item.
@MainActor
final class SpotlightPanel: NSPanel {
    init() {
        let rect = NSRect(x: 0, y: 0, width: 720, height: 460)
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
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
struct SpotlightView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var pinboards: PinboardStore
    @ObservedObject var stack: PasteStack
    @State private var query: String = ""
    @State private var results: [ClipItem] = []
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.3)
            content
            Divider().opacity(0.3)
            footer
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
        )
        .onAppear {
            searchFocused = true
            reload(initial: true)
        }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: store.recent) { _, _ in reload() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Search clipboard…  try type:link  source:Safari  /regex/", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { paste(plain: false) }
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PastyTheme.rowSpacing) {
                    if results.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, clip in
                            SpotlightRow(
                                clip: clip,
                                isSelected: idx == selectedIndex,
                                index: idx + 1
                            )
                            .id(idx)
                            .onTapGesture { selectedIndex = idx; paste(plain: false) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: 340)
            .onChange(of: selectedIndex) { _, new in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .background(KeyHandlingView(
                onUp: { move(-1) },
                onDown: { move(1) },
                onReturn: { paste(plain: false) },
                onShiftReturn: { paste(plain: true) },
                onEsc: { onDismiss() },
                onNumber: { n in pasteByIndex(n) },
                onTab: { /* form-switch hook – P2 */ },
                onCmdE: { /* edit hook – P3 */ }
            ))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "Copy something to begin" : "No matches")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            shortcutLabel("↩", "Paste")
            shortcutLabel("⇧↩", "Plain")
            shortcutLabel("⌘1-9", "Quick")
            shortcutLabel("␣", "Preview")
            shortcutLabel("⌘E", "Edit")
            Spacer()
            Text("\(results.count) shown · \(store.totalCount) total")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func shortcutLabel(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func reload(initial: Bool = false) {
        let q = query
        Task { @MainActor in
            do {
                let parsed = SearchQuery.parse(q)
                let items = try await SearchEngine.run(parsed, store: store)
                self.results = items
                if initial || selectedIndex >= items.count {
                    self.selectedIndex = items.isEmpty ? 0 : 0
                }
            } catch {
                NSLog("Search failed: \(error)")
            }
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let next = (selectedIndex + delta).clamped(to: 0...(results.count - 1))
        selectedIndex = next
    }

    private func paste(plain: Bool) {
        guard !results.isEmpty else { return }
        let clip = results[selectedIndex]
        onDismiss()
        PasteAutomator.shared.paste(clip, asPlainText: plain)
    }

    private func pasteByIndex(_ n: Int) {
        let idx = n - 1
        guard results.indices.contains(idx) else { return }
        selectedIndex = idx
        paste(plain: false)
    }
}

@MainActor
private struct SpotlightRow: View {
    let clip: ClipItem
    let isSelected: Bool
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? 0.25 : 0.12))
                    .frame(width: 22, height: 22)
                Text(index <= 9 ? "\(index)" : "•")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Image(systemName: clip.kind.iconName)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.preview)
                    .font(PastyTheme.titleFont)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(clip.kind.rawValue.uppercased())
                        .font(PastyTheme.subtitleFont)
                        .foregroundStyle(.secondary)
                    if let app = clip.sourceAppName {
                        Text("· \(app)")
                            .font(PastyTheme.subtitleFont)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(clip.createdAt, style: .relative)
                        .font(PastyTheme.subtitleFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.2 : 0))
        )
        .contentShape(Rectangle())
    }
}

extension ClipKind {
    var iconName: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .color: return "paintpalette"
        case .other: return "questionmark.square"
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
