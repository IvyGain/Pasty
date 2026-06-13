import AppKit
import SwiftUI

/// Paste 風の下部ストリップ。25% を超えない高さで横スクロールカード。
@MainActor
final class StripPanel: NSPanel {
    init() {
        let rect = NSRect(x: 0, y: 0, width: 1200, height: 260)
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
        becomesKeyOnlyIfNeeded = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func position(onScreen screen: NSScreen) {
        let visible = screen.visibleFrame
        let width = min(visible.width - 32, 1280)
        let height: CGFloat = 260
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
    @ObservedObject var selection: SelectionModel
    @State private var query: String = ""
    @State private var items: [ClipItem] = []
    @State private var filterKind: ClipKind? = nil
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            carousel
            if selection.hasSelection {
                Divider().opacity(0.25)
                multiSelectBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
        )
        .onAppear { selection.clearAll(); reload() }
        .onChange(of: store.recent) { _, _ in reload() }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: filterKind) { _, _ in reload() }
        .background(KeyHandlingView(
            onLeft:        { selection.moveCursor(by: -1, in: items) },
            onRight:       { selection.moveCursor(by:  1, in: items) },
            onReturn:      { onReturn(plain: false) },
            onShiftReturn: { onReturn(plain: true) },
            onOptionReturn:{ pasteSelected(join: true) },
            onEsc:         { onEsc() },
            onNumber:      { n in pasteByIndex(n) },
            onSpace:       { selection.toggleCursor(in: items) },
            onCmdA:        { selection.selectAll(in: items) },
            onCmdComma:    { onOpenSettings() }
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
                kindChip(nil,      label: "All")
                kindChip(.text,    label: "Aa")
                kindChip(.image,   label: "🖼")
                kindChip(.link,    label: "🔗")
                kindChip(.file,    label: "📄")
            }
            .font(.caption)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings…  ⌘,")

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
                        StripCard(
                            clip: clip,
                            index: idx + 1,
                            isCursor: idx == selection.cursorIndex,
                            isSelected: selection.isSelected(clip.id ?? -1)
                        )
                        .id(idx)
                        .onTapGesture { handleTap(at: idx, modifiers: CurrentInput.modifierFlags) }
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
            .onChange(of: selection.cursorIndex) { _, n in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(n, anchor: .center) }
            }
        }
    }

    private var multiSelectBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text("\(selection.count) selected").font(.callout.weight(.medium))
            Spacer()
            Button("Clear") { selection.clearAll() }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button {
                pasteSelected(join: false)
            } label: {
                Label("Paste each", systemImage: "doc.on.doc").font(.callout)
            }
            .buttonStyle(.borderless)
            Button {
                pasteSelected(join: true)
            } label: {
                Label("Paste joined", systemImage: "arrow.down.doc")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Actions

    private func handleTap(at index: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            selection.shiftTap(at: index, in: items); return
        }
        if modifiers.contains(.command) {
            selection.commandTap(at: index, in: items); return
        }
        let result = selection.tap(at: index, in: items)
        switch result {
        case .pasteSingle(let clip):
            onDismiss()
            PasteAutomator.shared.paste(clip)
        case .toggled, .noop: break
        }
    }

    private func onReturn(plain: Bool) {
        if selection.hasSelection { pasteSelected(join: false, plain: plain) }
        else                       { pasteCurrent(plain: plain) }
    }

    private func onEsc() {
        if selection.hasSelection { selection.clearAll() }
        else                       { onDismiss() }
    }

    private func pasteCurrent(plain: Bool) {
        guard items.indices.contains(selection.cursorIndex) else { return }
        let clip = items[selection.cursorIndex]
        onDismiss()
        PasteAutomator.shared.paste(clip, asPlainText: plain)
    }

    private func pasteByIndex(_ n: Int) {
        let idx = n - 1
        guard items.indices.contains(idx) else { return }
        selection.cursorIndex = idx
        pasteCurrent(plain: false)
    }

    private func pasteSelected(join: Bool, plain: Bool = false) {
        let selected = selection.selectedItems(from: items)
        guard !selected.isEmpty else { return }
        onDismiss()
        if join {
            PasteAutomator.shared.pasteSequence(
                selected, asPlainText: plain,
                strategy: .join(separator: "\n")
            )
        } else {
            PasteAutomator.shared.pasteSequence(
                selected, asPlainText: plain,
                strategy: .sequence(delayBetween: 0.12)
            )
        }
    }

    private func reload() {
        var q = SearchQuery.parse(query)
        // kind chip は SearchQuery 経由のものより常に優先（UIのチップ状態は
        // ユーザの明示的な意思）。
        if let f = filterKind { q.kind = f }

        // Pinboard が選ばれていて、かつ検索もフィルタも未指定なら、
        // そのピンボードの中身を表示する（最頻パターン）。
        if let selectedID = pinboards.selectedID,
           let board = pinboards.boards.first(where: { $0.id == selectedID }),
           query.isEmpty, filterKind == nil {
            Task { @MainActor in
                if let pinned = try? await pinboards.items(in: board.id ?? -1),
                   !pinned.isEmpty {
                    self.items = pinned
                    if selection.cursorIndex >= pinned.count { selection.cursorIndex = 0 }
                    return
                }
                self.items = store.recent
                if selection.cursorIndex >= self.items.count { selection.cursorIndex = 0 }
            }
            return
        }

        Task { @MainActor in
            let results = (try? await SearchEngine.run(q, store: store)) ?? []
            self.items = results
            if selection.cursorIndex >= results.count { selection.cursorIndex = 0 }
        }
    }
}

private struct StripCard: View {
    let clip: ClipItem
    let index: Int
    let isCursor: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: clip.kind.iconName).foregroundStyle(.tint)
                }
                Text(clip.sourceAppName ?? "—")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(index <= 9 ? "⌘\(index)" : "")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
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
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 180, height: 170, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isCursor ? 2 : 1.5)
        )
    }

    private var borderColor: Color {
        if isCursor   { return Color.accentColor.opacity(0.9) }
        if isSelected { return Color.accentColor.opacity(0.55) }
        return .clear
    }
}

