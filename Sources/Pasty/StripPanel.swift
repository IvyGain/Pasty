import AppKit
import SwiftUI

/// Paste-style bottom strip. Slides up from the bottom edge of the screen
/// where the cursor is, occupies ~25% of the screen height (down from
/// Paste's 40-50%), and shows a horizontally scrolling carousel of clips.
@MainActor
final class StripPanel: NSPanel {
    init() {
        let rect = NSRect(x: 0, y: 0, width: 1200, height: 240)
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
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Position centred at the bottom of the screen containing the cursor.
    func position(onScreen screen: NSScreen) {
        let visible = screen.visibleFrame
        let width = min(visible.width - 32, 1280)
        let height: CGFloat = 240
        let origin = CGPoint(
            x: visible.midX - width / 2,
            y: visible.minY + 16
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)),
                 display: false)
    }
}

@MainActor
struct StripView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var pinboards: PinboardStore
    @ObservedObject var stack: PasteStack
    @State private var query: String = ""
    @State private var items: [ClipItem] = []
    @State private var selectedIndex: Int = 0
    @State private var filterKind: ClipKind? = nil
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            carousel
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
        )
        .onAppear(perform: reload)
        .onChange(of: store.recent) { _, _ in reload() }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: filterKind) { _, _ in reload() }
        .background(KeyHandlingView(
            onLeft: { move(-1) },
            onRight: { move(1) },
            onReturn: { paste(plain: false) },
            onShiftReturn: { paste(plain: true) },
            onEsc: { onDismiss() },
            onNumber: { n in pasteByIndex(n) },
            onSpace: { /* Quick Look – P3 */ }
        ))
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))

            ForEach(pinboards.boards) { board in
                Button {
                    pinboards.selectedID = board.id
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: board.colorHex)).frame(width: 8, height: 8)
                        Text(board.name).font(.caption)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        Color.primary.opacity(pinboards.selectedID == board.id ? 0.15 : 0.05),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 4) {
                kindChip(nil, label: "All")
                kindChip(.text, label: "Aa")
                kindChip(.image, label: "🖼")
                kindChip(.link, label: "🔗")
                kindChip(.file, label: "📄")
            }
            .font(.caption)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func kindChip(_ kind: ClipKind?, label: String) -> some View {
        Button {
            filterKind = (filterKind == kind) ? nil : kind
        } label: {
            Text(label)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    Color.primary.opacity(filterKind == kind ? 0.18 : 0.05),
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
    }

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, clip in
                        StripCard(clip: clip, index: idx + 1, isSelected: idx == selectedIndex)
                            .id(idx)
                            .onTapGesture {
                                selectedIndex = idx
                                paste(plain: false)
                            }
                            .draggable(clip.content ?? clip.preview)
                            .contextMenu {
                                ForEach(pinboards.boards) { board in
                                    Button("Pin to \(board.name)") {
                                        guard let cid = clip.id, let bid = board.id else { return }
                                        Task { try? await pinboards.pin(clipId: cid, toBoard: bid) }
                                    }
                                }
                                Divider()
                                Button("Add to Stack") { stack.push(clip) }
                            }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .onChange(of: selectedIndex) { _, n in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(n, anchor: .center) }
            }
        }
    }

    private func reload() {
        var q = SearchQuery.parse(query)
        q.kind = filterKind ?? q.kind
        if let selectedID = pinboards.selectedID,
           let board = pinboards.boards.first(where: { $0.id == selectedID }),
           query.isEmpty {
            // For empty searches, prefer the chosen pinboard.
            Task { @MainActor in
                if let items = try? await pinboards.items(in: board.id ?? -1),
                   !items.isEmpty {
                    self.items = items
                    if selectedIndex >= items.count { selectedIndex = 0 }
                    return
                }
                self.items = store.recent
                if selectedIndex >= self.items.count { selectedIndex = 0 }
            }
            return
        }
        Task { @MainActor in
            let results = (try? await SearchEngine.run(q, store: store)) ?? []
            self.items = results
            if selectedIndex >= results.count { selectedIndex = 0 }
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta).clamped(to: 0...(items.count - 1))
    }

    private func paste(plain: Bool) {
        guard !items.isEmpty else { return }
        let clip = items[selectedIndex]
        onDismiss()
        PasteAutomator.shared.paste(clip, asPlainText: plain)
    }

    private func pasteByIndex(_ n: Int) {
        let idx = n - 1
        guard items.indices.contains(idx) else { return }
        selectedIndex = idx
        paste(plain: false)
    }
}

private struct StripCard: View {
    let clip: ClipItem
    let index: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: clip.kind.iconName)
                    .foregroundStyle(.tint)
                Text(clip.sourceAppName ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(index <= 9 ? "⌘\(index)" : "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(clip.preview)
                .font(.caption)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
            Spacer()
            HStack {
                Text(clip.kind.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(clip.createdAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 180, height: 170, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
        )
    }
}
