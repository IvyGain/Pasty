import AppKit
import SwiftUI

/// Pasty のメインモーダル — 下から立ち上がるカルーセル/グリッド。
/// Notch Hover でも同じ View を使うため、UI ロジックは全部 `StripView` 側へ。
@MainActor
final class StripPanel: NSPanel {
    init() {
        let rect = NSRect(x: 0, y: 0, width: 1240, height: 360)
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
        let width = min(visible.width - 32, 1320)
        let height: CGFloat = 360
        let origin = CGPoint(
            x: visible.midX - width / 2,
            y: visible.minY + 16
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)),
                 display: false)
    }
}

/// パネルの「現れ方」だけを変えるためのモード。
/// `.strip` = 下から上にスライド。キーボード操作を主に使う。
/// `.notch` = 上から下にスライド。マウスでドラッグして貼り付けるのが主。
enum CarouselMode { case strip, notch }

@MainActor
struct StripView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var pinboards: PinboardStore
    @ObservedObject var stack: PasteStack
    @ObservedObject var selection: SelectionModel
    var mode: CarouselMode = .strip
    @State private var query: String = ""
    @State private var items: [ClipItem] = []
    @State private var filterKind: ClipKind? = nil
    @State private var folderID: Int64? = nil
    @State private var showingNewFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var newFolderColor: String = "#7C8CF8"
    @State private var showingNewSnippet: Bool = false
    @State private var newSnippetText: String = ""
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            folderBar
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
        .onAppear {
            selection.clearAll()
            if folderID == nil { folderID = pinboards.boards.first?.id }
            reload()
        }
        .onChange(of: store.recent) { _, _ in reload() }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: filterKind) { _, _ in reload() }
        .onChange(of: folderID) { _, _ in reload() }
        .onChange(of: pinboards.boards.count) { _, _ in reload() }
        .background(keyHandler)
        .sheet(isPresented: $showingNewFolder) { newFolderSheet }
        .sheet(isPresented: $showingNewSnippet) { newSnippetSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("クリップを検索…", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 220)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            HStack(spacing: 4) {
                kindChip(nil,      label: "All")
                kindChip(.text,    label: "Aa")
                kindChip(.image,   label: "🖼")
                kindChip(.link,    label: "🔗")
                kindChip(.file,    label: "📄")
            }
            .font(.caption)

            Button {
                showingNewSnippet = true
                newSnippetText = ""
            } label: {
                Label("定型文", systemImage: "text.badge.plus")
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("選択中のフォルダに定型文を追加")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("設定…  ⌘,")

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

    // MARK: - Folder tab strip

    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                folderTab(id: nil, name: "履歴", colorHex: "#86868b",
                          systemImage: "clock.arrow.circlepath")
                ForEach(pinboards.boards) { board in
                    folderTab(id: board.id, name: board.name, colorHex: board.colorHex,
                              systemImage: "folder.fill")
                        .contextMenu {
                            Button("中身を順次貼付") { pasteAllInFolder(board, join: false) }
                            Button("中身を結合して貼付") { pasteAllInFolder(board, join: true) }
                            Divider()
                            Button("フォルダ名を変更…") { promptRename(board) }
                            Button("削除", role: .destructive) { promptDelete(board) }
                        }
                }
                Button {
                    showingNewFolder = true
                    newFolderName = ""
                    newFolderColor = randomFolderColor()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                        Text("新しいフォルダ").font(.caption)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor.opacity(0.5),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    private func folderTab(id: Int64?, name: String, colorHex: String, systemImage: String) -> some View {
        let selected = folderID == id
        return Button {
            folderID = id
        } label: {
            HStack(spacing: 5) {
                if id == nil {
                    Image(systemName: systemImage).foregroundStyle(.secondary).font(.caption)
                } else {
                    Circle().fill(Color(hex: colorHex)).frame(width: 8, height: 8)
                }
                Text(name)
                    .font(.callout.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Color.primary.opacity(selected ? 0.18 : 0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [.plainText, .url, .fileURL], isTargeted: nil) { providers in
            // 他のカードをフォルダタブにドロップすると、そのフォルダに pin する。
            handleDropToFolder(providers: providers, folderID: id)
            return true
        }
    }

    // MARK: - Carousel

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
                            Section("フォルダに振り分け") {
                                ForEach(pinboards.boards) { board in
                                    Button(board.name) {
                                        guard let cid = clip.id, let bid = board.id else { return }
                                        Task { try? await pinboards.pin(clipId: cid, toBoard: bid) }
                                    }
                                }
                            }
                            Divider()
                            Button("Stack に追加") { stack.push(clip) }
                            Divider()
                            Button("削除", role: .destructive) {
                                guard let cid = clip.id else { return }
                                Task { try? await store.delete(clipId: cid) }
                            }
                        }
                    }
                    if items.isEmpty { emptyFolderPlaceholder }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .onChange(of: selection.cursorIndex) { _, n in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(n, anchor: .center) }
            }
        }
    }

    private var emptyFolderPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("このフォルダは空です")
                .font(.callout).foregroundStyle(.secondary)
            Button("定型文を追加") {
                showingNewSnippet = true
                newSnippetText = ""
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(width: 220, height: 180)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Multi-select bar

    private var multiSelectBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text("\(selection.count) 件 選択中").font(.callout.weight(.medium))
            Spacer()
            // 選択中のクリップを現フォルダに移動
            if let fid = folderID {
                Button("このフォルダに保存") {
                    let items = selection.selectedItems(from: items)
                    Task {
                        for it in items {
                            guard let cid = it.id else { continue }
                            try? await pinboards.pin(clipId: cid, toBoard: fid)
                        }
                        selection.clearAll()
                    }
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
            Button("クリア") { selection.clearAll() }
                .buttonStyle(.borderless).controlSize(.small)
            Button {
                pasteSelected(join: false)
            } label: {
                Label("順次貼付", systemImage: "doc.on.doc").font(.callout)
            }
            .buttonStyle(.borderless)
            Button {
                pasteSelected(join: true)
            } label: {
                Label("まとめて貼付", systemImage: "arrow.down.doc")
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

    // MARK: - Sheets

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新しいフォルダ").font(.headline)
            TextField("名前 (例: 営業の定型文 / 画像倉庫)", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack(spacing: 8) {
                ForEach(folderColorPalette, id: \.self) { hex in
                    Button {
                        newFolderColor = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .strokeBorder(newFolderColor == hex ? Color.primary : .clear,
                                                  lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { showingNewFolder = false }
                Button("作成") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        try? await pinboards.create(name: name, colorHex: newFolderColor)
                        showingNewFolder = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var newSnippetSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("定型文を追加").font(.headline)
                Spacer()
                if let fid = folderID,
                   let board = pinboards.boards.first(where: { $0.id == fid }) {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: board.colorHex)).frame(width: 8, height: 8)
                        Text(board.name).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("履歴").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $newSnippetText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 480, height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            HStack {
                Text("{{date}} {{user}} {{uuid}} などのスニペット変数は貼付時に展開されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { showingNewSnippet = false }
                Button("保存") {
                    let text = newSnippetText
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    Task {
                        let clip = try? await store.createTextClip(content: text)
                        if let cid = clip?.id, let fid = folderID {
                            try? await pinboards.pin(clipId: cid, toBoard: fid)
                        }
                        showingNewSnippet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newSnippetText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - Actions

    private var keyHandler: some View {
        KeyHandlingView(
            onLeft:         { selection.moveCursor(by: -1, in: items) },
            onRight:        { selection.moveCursor(by:  1, in: items) },
            onReturn:       { onReturn(plain: false) },
            onShiftReturn:  { onReturn(plain: true) },
            onOptionReturn: { pasteSelected(join: true) },
            onEsc:          { onEsc() },
            onNumber:       { n in pasteByIndex(n) },
            onSpace:        { showQuickLook() },
            onShiftUp:      { selection.extend(by: -1, in: items) },
            onShiftDown:    { selection.extend(by:  1, in: items) },
            onCmdA:         { selection.selectAll(in: items) },
            onCmdN:         { showingNewSnippet = true; newSnippetText = "" },
            onCmdI:         { showAIMenu() },
            onCmdComma:     { onOpenSettings() },
            onCmdP:         { SettingsStore.shared.explorerMode.toggle() },
            onCmdSpace:     { selection.toggleCursor(in: items) },
            onCmdQuestion:  { HelpOverlayPresenter.shared.toggle() },
            onCtrlShiftR:   { runAI(.rewrite(tone: .formal)) },
            onCtrlShiftT:   { runAI(.translate(target: .auto)) },
            onCtrlShiftS:   { runAI(.summarize(length: .short)) },
            onCtrlShiftJ:   { runAI(.reformat(to: .jsonPretty)) },
            onCtrlShiftE:   { runAI(.emailify) }
        )
    }

    private func showAIMenu() {
        guard items.indices.contains(selection.cursorIndex) else { return }
        let clip = items[selection.cursorIndex]
        AIActionCoordinator.shared.presentMenu(for: clip, store: store)
    }

    private func runAI(_ action: AIAction) {
        guard items.indices.contains(selection.cursorIndex) else { return }
        let clip = items[selection.cursorIndex]
        AIActionCoordinator.shared.execute(action, on: clip, store: store)
    }

    private func showQuickLook() {
        guard !items.isEmpty else { return }
        QuickLookPreview.shared.show(items: items, at: selection.cursorIndex)
    }

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

    private func pasteAllInFolder(_ board: Pinboard, join: Bool) {
        Task {
            guard let bid = board.id,
                  let pinned = try? await pinboards.items(in: bid),
                  !pinned.isEmpty else { return }
            onDismiss()
            if join {
                PasteAutomator.shared.pasteSequence(pinned,
                    strategy: .join(separator: "\n"))
            } else {
                PasteAutomator.shared.pasteSequence(pinned,
                    strategy: .sequence(delayBetween: 0.12))
            }
        }
    }

    private func handleDropToFolder(providers: [NSItemProvider], folderID: Int64?) {
        guard let fid = folderID else { return }
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { _, _ in
                // 受領のみ。実体の移動はクリップ ID 経由が望ましいが、
                // SwiftUI .draggable の string プロバイダから ID 復元は限界が
                // あるので「現フォルダにそのクリップを pin」を選択中アイテム
                // を介して別パスで実装する（multiSelectBar の「保存」を推奨）。
            }
        }
    }

    private func promptRename(_ board: Pinboard) {
        let alert = NSAlert()
        alert.messageText = "「\(board.name)」の名前を変更"
        alert.informativeText = "新しい名前を入力してください。"
        let field = NSTextField(string: board.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty, let id = board.id else { return }
            Task { try? await pinboards.rename(id: id, to: newName) }
        }
    }

    private func promptDelete(_ board: Pinboard) {
        let alert = NSAlert()
        alert.messageText = "「\(board.name)」を削除しますか？"
        alert.informativeText = "このフォルダのクリップは元の履歴には残ります。フォルダだけが消えます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn, let id = board.id {
            Task { try? await pinboards.delete(id: id) }
        }
    }

    // MARK: - Data

    private func reload() {
        var q = SearchQuery.parse(query)
        if let f = filterKind { q.kind = f }

        if let fid = folderID,
           let board = pinboards.boards.first(where: { $0.id == fid }) {
            Task { @MainActor in
                let pinned = (try? await pinboards.items(in: board.id ?? -1)) ?? []
                self.items = applyFilters(pinned, q: q)
                if selection.cursorIndex >= self.items.count { selection.cursorIndex = 0 }
            }
            return
        }

        // 履歴タブ：全クリップを使う。
        Task { @MainActor in
            let results = (try? await SearchEngine.run(q, store: store)) ?? []
            self.items = results
            if selection.cursorIndex >= results.count { selection.cursorIndex = 0 }
        }
    }

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

    private let folderColorPalette: [String] = [
        "#7C8CF8", "#34C759", "#FF9F0A", "#BF5AF2",
        "#FF453A", "#5AC8FA", "#FFD60A", "#30D158",
        "#FF375F", "#64D2FF", "#BCBCBC"
    ]

    private func randomFolderColor() -> String {
        folderColorPalette.randomElement() ?? "#7C8CF8"
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
            if clip.kind == .image, let p = clip.dataPath,
               let img = ImageBlobCache.shared.image(for: p) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text(clip.preview)
                    .font(.caption)
                    .lineLimit(7)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
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
        .frame(width: 200, height: 200, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isCursor ? 2 : 1.5)
        )
    }

    private var borderColor: Color {
        if isCursor   { return Color.accentColor.opacity(0.9) }
        if isSelected { return Color.accentColor.opacity(0.55) }
        return .clear
    }
}
