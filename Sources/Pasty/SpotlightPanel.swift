import AppKit
import SwiftUI

/// Spotlight / Raycast 風の中央モーダル。
@MainActor
final class SpotlightPanel: NSPanel {
    init() {
        let rect = NSRect(x: 0, y: 0, width: 720, height: 480)
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
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
struct SpotlightView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var pinboards: PinboardStore
    @ObservedObject var stack: PasteStack
    @ObservedObject var selection: SelectionModel
    @State private var query: String = ""
    @State private var results: [ClipItem] = []
    @State private var folderID: Int64? = nil       // 選択中の "フォルダ"（pinboard）
    @State private var kindFilter: ClipKind? = nil
    @FocusState private var searchFocused: Bool
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            pinboardBar
            Divider().opacity(0.3)
            content
            if selection.hasSelection {
                Divider().opacity(0.3)
                multiSelectBar
            }
            Divider().opacity(0.3)
            footer
        }
        .frame(width: 720, alignment: .topLeading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
        )
        .onAppear {
            searchFocused = true
            selection.clearAll()
            reload(initial: true)
        }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: store.recent) { _, _ in reload() }
        .onChange(of: folderID) { _, _ in reload() }
        .onChange(of: kindFilter) { _, _ in reload() }
        .onDisappear { HoverPreviewController.shared.dismissNow() }
    }

    private var pinboardBar: some View {
        HStack(spacing: 6) {
            folderChip(id: nil, name: "All", colorHex: "#86868b")
            ForEach(pinboards.boards) { board in
                folderChip(id: board.id, name: board.name, colorHex: board.colorHex)
            }
            Spacer()
            HStack(spacing: 4) {
                kindChip(nil,      label: "All")
                kindChip(.text,    label: "Aa")
                kindChip(.image,   label: "🖼")
                kindChip(.link,    label: "🔗")
                kindChip(.file,    label: "📄")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func folderChip(id: Int64?, name: String, colorHex: String) -> some View {
        Button {
            folderID = (folderID == id) ? nil : id
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: colorHex)).frame(width: 7, height: 7)
                Text(name).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Color.primary.opacity(folderID == id ? 0.16 : 0.06),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    private func kindChip(_ kind: ClipKind?, label: String) -> some View {
        Button {
            kindFilter = (kindFilter == kind) ? nil : kind
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    Color.primary.opacity(kindFilter == kind ? 0.18 : 0.06),
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search clipboard…  type:link  source:Safari  /regex/", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { pasteCurrent(plain: false) }
                .accessibilityLabel("クリップ検索")
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索クリア")
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings…  ⌘,")
            .accessibilityLabel("設定")
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
                                isCursor: idx == selection.cursorIndex,
                                isSelected: selection.isSelected(clip.id ?? -1),
                                index: idx + 1,
                                onTap: { mods in handleTap(at: idx, modifiers: mods) }
                            )
                            .id(idx)
                            .contextMenu {
                                ForEach(pinboards.boards) { board in
                                    Button("Move to \(board.name)") {
                                        guard let cid = clip.id, let bid = board.id else { return }
                                        Task { try? await pinboards.pin(clipId: cid, toBoard: bid) }
                                    }
                                }
                                Divider()
                                Button("Add to Stack") { stack.push(clip) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: 320)
            .onChange(of: selection.cursorIndex) { _, new in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .background(KeyHandlingView(
                onUp:           { selection.moveCursor(by: -1, in: results) },
                onDown:         { selection.moveCursor(by:  1, in: results) },
                onReturn:       { onReturn(plain: false) },
                onShiftReturn:  { onReturn(plain: true) },
                onOptionReturn: { pasteSelected(join: true) },
                onEsc:          { onEsc() },
                onNumber:       { n in pasteByIndex(n) },
                onSpace:        { showQuickLook() },
                onShiftUp:      { selection.extend(by: -1, in: results) },
                onShiftDown:    { selection.extend(by:  1, in: results) },
                onCmdA:         { selection.selectAll(in: results) },
                onCmdComma:     { onOpenSettings() },
                onCmdP:         { SettingsStore.shared.explorerMode.toggle() },
                onCmdSpace:     { selection.toggleCursor(in: results) },
                onCmdQuestion:  { HelpOverlayPresenter.shared.toggle() }
            ))
        }
    }

    private var multiSelectBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
            Text("\(selection.count) selected")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Clear") { selection.clearAll() }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button {
                pasteSelected(join: false)
            } label: {
                Label("Paste each (⌘V × N)", systemImage: "doc.on.doc")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            Button {
                pasteSelected(join: true)
            } label: {
                Label("Paste joined (⌥↩)", systemImage: "arrow.down.doc")
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
            shortcutLabel("↩",    selection.hasSelection ? "Paste each" : "Paste")
            shortcutLabel("⌥↩",   "Joined")
            shortcutLabel("⇧↩",  "Plain")
            shortcutLabel("␣",   "Select")
            shortcutLabel("⇧↑↓", "Range")
            shortcutLabel("⌘A",  "All")
            shortcutLabel("⌘1-9","Quick")
            Spacer()
            Text("\(results.count) shown · \(store.totalCount) total")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func shortcutLabel(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func reload(initial: Bool = false) {
        let q = query
        Task { @MainActor in
            var parsed = SearchQuery.parse(q)
            if let f = kindFilter { parsed.kind = f }
            do {
                let baseItems: [ClipItem]
                if let fid = folderID,
                   let board = pinboards.boards.first(where: { $0.id == fid }) {
                    // フォルダ（pinboard）が選ばれているときは、その中身を母集合にして
                    // 検索 DSL / kind フィルタを後段で適用する。
                    let pinned = (try? await pinboards.items(in: board.id ?? -1)) ?? []
                    baseItems = applyFilters(pinned, q: parsed)
                } else {
                    baseItems = try await SearchEngine.run(parsed, store: store)
                }
                self.results = baseItems
                if initial || selection.cursorIndex >= baseItems.count {
                    selection.cursorIndex = baseItems.isEmpty ? 0 : 0
                }
            } catch {
                NSLog("Search failed: \(error)")
            }
        }
    }

    /// pinboard 内に絞っているときの簡易フィルタ。
    private func applyFilters(_ items: [ClipItem], q: SearchQuery) -> [ClipItem] {
        var out = items
        if let k = q.kind { out = out.filter { $0.kind == k } }
        if let src = q.sourceApp?.lowercased(), !src.isEmpty {
            out = out.filter { ($0.sourceAppName ?? "").lowercased().contains(src) }
        }
        if !q.freeText.isEmpty {
            let needle = q.freeText.lowercased()
            out = out.filter { ($0.content ?? "").lowercased().contains(needle)
                || $0.preview.lowercased().contains(needle) }
        }
        return out
    }

    private func handleTap(at index: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            selection.shiftTap(at: index, in: results)
            return
        }
        if modifiers.contains(.command) {
            selection.commandTap(at: index, in: results)
            return
        }
        let result = selection.tap(at: index, in: results)
        switch result {
        case .pasteSingle(let clip):
            onDismiss()
            PasteAutomator.shared.paste(clip)
        case .toggled, .noop:
            break
        }
    }

    private func showQuickLook() {
        guard !results.isEmpty else { return }
        QuickLookPreview.shared.show(items: results, at: selection.cursorIndex)
    }

    private func onReturn(plain: Bool) {
        if selection.hasSelection {
            pasteSelected(join: false, plain: plain)
        } else {
            pasteCurrent(plain: plain)
        }
    }

    private func onEsc() {
        if selection.hasSelection {
            selection.clearAll()
        } else {
            onDismiss()
        }
    }

    private func pasteCurrent(plain: Bool) {
        guard results.indices.contains(selection.cursorIndex) else { return }
        let clip = results[selection.cursorIndex]
        onDismiss()
        PasteAutomator.shared.paste(clip, asPlainText: plain)
    }

    private func pasteByIndex(_ n: Int) {
        let idx = n - 1
        guard results.indices.contains(idx) else { return }
        selection.cursorIndex = idx
        pasteCurrent(plain: false)
    }

    private func pasteSelected(join: Bool, plain: Bool = false) {
        let items = selection.selectedItems(from: results)
        guard !items.isEmpty else { return }
        onDismiss()
        if join {
            PasteAutomator.shared.pasteSequence(
                items, asPlainText: plain,
                strategy: .join(separator: "\n")
            )
        } else {
            PasteAutomator.shared.pasteSequence(
                items, asPlainText: plain,
                strategy: .sequence(delayBetween: 0.12)
            )
        }
    }
}

@MainActor
private struct SpotlightRow: View {
    let clip: ClipItem
    let isCursor: Bool
    let isSelected: Bool
    let index: Int
    let onTap: (NSEvent.ModifierFlags) -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 選択チェック or 番号
            ZStack {
                if isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(isCursor ? 0.25 : 0.10))
                        .frame(width: 22, height: 22)
                    Text(index <= 9 ? "\(index)" : "•")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
            }
            .accessibilityHidden(true)
            ClipThumbnail(clip: clip, size: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.preview)
                    .font(PastyTheme.titleFont)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.rowCornerRadius, style: .continuous)
                .strokeBorder(isCursor ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap(CurrentInput.modifierFlags) }
        .onHover { hovering in
            guard SettingsStore.shared.hoverPreviewEnabled else { return }
            if hovering {
                HoverPreviewController.shared.scheduleShow(
                    for: clip,
                    near: NSEvent.mouseLocation,
                    on: NSScreen.main
                )
            } else {
                HoverPreviewController.shared.cancel()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(clip.preview)
        .accessibilityHint(accessibilityHintText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityHintText: String {
        let kind = clip.kind.rawValue
        let source = clip.sourceAppName ?? ""
        return source.isEmpty ? kind : "\(kind), \(source)"
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if isCursor   { return Color.accentColor.opacity(0.10) }
        return .clear
    }
}

enum CurrentInput {
    @MainActor static var modifierFlags: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? []
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
