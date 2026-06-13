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
        // ユーザー要望 (v0.4):
        //  - **横幅は画面いっぱい** (左右に申し訳程度の 8pt マージンだけ)
        //  - **縦位置は Dock の真上** にぴたっと吸着 (visible.minY)
        // `visibleFrame` は Dock とメニューバーを除いた領域なので、その
        // 最下端 = Dock の上端。そこに底面を合わせれば一番下にくる。
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        let width = max(visible.width - margin * 2, 480)
        // Explorer モード（⌘P トグル）では分割ペイン構成で縦方向の情報量が
        // 増えるので、パネル全体を背高くする。通常カルーセル時は 360。
        let height: CGFloat = SettingsStore.shared.explorerMode ? 520 : 360
        let origin = CGPoint(
            x: visible.minX + margin,
            y: visible.minY                  // ← Dock の真上
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
    // Explorer モード切替を監視するため SettingsStore も購読。
    // ⌘P で `explorerMode` がトグルされると body が再評価され、
    // カルーセル ↔ 分割ペインのレイアウトが切り替わる。
    @ObservedObject private var settings = SettingsStore.shared
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
            Divider().opacity(0.25)
            if settings.explorerMode {
                explorerLayout
            } else {
                carousel
            }
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
            // 初期表示は常に履歴 (= folderID == nil) から始める
            folderID = nil
            reload()
            // ノッチパネル経由の Tab/Shift+Tab 通知を購読。
            NotificationCenter.default.addObserver(
                forName: .pastyNotchCycleFolderForward,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in cycleFolder(by: 1) }
            }
            NotificationCenter.default.addObserver(
                forName: .pastyNotchCycleFolderBackward,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in cycleFolder(by: -1) }
            }
        }
        .onChange(of: store.recent) { _, _ in reload() }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: filterKind) { _, _ in reload() }
        .onChange(of: folderID) { _, _ in reload() }
        .onChange(of: pinboards.boards.count) { _, _ in reload() }
        .background(keyHandler)
        .sheet(isPresented: $showingNewFolder) { newFolderSheet }
        .sheet(isPresented: $showingNewSnippet) { newSnippetSheet }
        .onDisappear { HoverPreviewController.shared.dismissNow() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            // 折り畳み式の検索バー (アイコンのみ → クリック/フォーカスで展開)
            ModernSearchField(text: $query, collapsible: true, expandedWidth: 280)

            // 履歴タブ + フォルダタブを同じ行に統合 (横スクロール可能)
            // 右側の他要素を押し出さないよう layoutPriority 0 + frame(minWidth) で柔軟に縮める。
            inlineFolderStrip
                .layoutPriority(0)
                .frame(minWidth: 0)

            Spacer(minLength: 8)

            // 種類フィルタ — コンパクトなセグメント
            HStack(spacing: 2) {
                kindChip(nil,    label: "All")
                kindChip(.text,  label: "Aa", systemImage: "textformat")
                kindChip(.image, label: "画像", systemImage: "photo")
                kindChip(.link,  label: "リンク", systemImage: "link")
                kindChip(.file,  label: "ファイル", systemImage: "doc")
            }
            .padding(2)
            .background(
                Capsule(style: .continuous).fill(ModernTokens.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(ModernTokens.hairline, lineWidth: 0.5)
            )

            // 「+ 定型文」プライマリ CTA
            ModernPrimaryButton(action: {
                showingNewSnippet = true
                newSnippetText = ""
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("定型文")
                        .font(.system(size: 11.5, weight: .semibold))
                        .tracking(-0.1)
                }
            }
            .help("選択中のフォルダに定型文を追加  ⌘N")

            ModernIconButton(systemImage: "gearshape",
                             help: "設定…  ⌘,",
                             action: onOpenSettings)
                .accessibilityLabel("設定")

            ModernIconButton(systemImage: "xmark",
                             help: "閉じる",
                             action: onDismiss)
                .accessibilityLabel("閉じる")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    // ヘッダー内の横スクロール式フォルダタブストリップ (履歴 + ピンボード + 新規)
    private var inlineFolderStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 5) {
                ModernFolderTab(
                    name: "履歴",
                    colorHex: nil,
                    systemImage: "clock.arrow.circlepath",
                    count: nil,
                    isSelected: folderID == nil,
                    action: { folderID = nil }
                )
                .acceptClipReferenceDrop(pinboardId: nil,
                                         pinboards: pinboards, store: store)

                if !pinboards.boards.isEmpty {
                    Rectangle()
                        .fill(ModernTokens.hairlineStrong)
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 1)
                }

                ForEach(pinboards.boards) { board in
                    ModernFolderTab(
                        name: board.name,
                        colorHex: board.colorHex,
                        systemImage: nil,
                        count: nil,
                        isSelected: folderID == board.id,
                        action: { folderID = board.id }
                    )
                    .contextMenu {
                        Button("中身を順次貼付") { pasteAllInFolder(board, join: false) }
                        Button("中身を結合して貼付") { pasteAllInFolder(board, join: true) }
                        Divider()
                        Button("フォルダ名を変更…") { promptRename(board) }
                        Button("削除", role: .destructive) { promptDelete(board) }
                    }
                    .acceptClipReferenceDrop(pinboardId: board.id,
                                             pinboards: pinboards, store: store)
                }

                Button {
                    showingNewFolder = true
                    newFolderName = ""
                    newFolderColor = randomFolderColor()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(Color.accentColor.opacity(0.08))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.accentColor.opacity(0.32),
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                }
                .buttonStyle(.plain)
                .help("新しいフォルダ")
            }
            .padding(.horizontal, 2)
        }
        // scrollClipDisabled() / maxWidth は撤去。ScrollView の clip 内に
        // 全タブが収まり、HStack の親フレーム内でヒットテストされる。
    }

    /// shadcn セグメント風の種類フィルタチップ。
    /// アイコンとラベルの両方を表示するが、幅優先でテキストは折り畳まれる。
    @ViewBuilder
    private func kindChip(_ kind: ClipKind?, label: String,
                          systemImage: String? = nil) -> some View {
        KindChip(label: label, systemImage: systemImage,
                 isOn: filterKind == kind) {
            filterKind = (filterKind == kind) ? nil : kind
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
                            isSelected: selection.isSelected(clip.id ?? -1),
                            selectionOrder: selection.order(of: clip.id ?? -1)
                        )
                        .id(idx)
                        // ダブルクリック = 貼付 / シングルクリック = 選択。
                        // SwiftUI の onTapGesture は count 大きい方を先に書く。
                        .onTapGesture(count: 2) { handleDoubleTap(at: idx) }
                        .onTapGesture { handleTap(at: idx, modifiers: CurrentInput.modifierFlags) }
                        .draggableClip(clip, additionalSelected: selection.isSelected(clip.id ?? -1) ? selection.selectedItems(from: items).filter { $0.id != clip.id } : [])
                        .contextMenu {
                            // 「フォルダ内表示中」ならその場で名前変更が可能
                            if let bid = folderID {
                                Button("このフォルダでの名前を変更…") {
                                    promptRenameClipInFolder(clip: clip, pinboardId: bid)
                                }
                                Divider()
                            }
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

    // MARK: - Explorer split pane

    /// `SettingsStore.explorerMode` が ON のときに使う 2 ペイン構成。
    /// 左: クリップの縦リスト (約 280pt 幅)、右: 選択中クリップの `ClipPreviewView`。
    /// カルーセルより縦長で全体を把握しやすく、長文プレビューに強い。
    private var explorerLayout: some View {
        HStack(spacing: 0) {
            explorerList
                .frame(width: 280)
            Divider()
            explorerPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explorerList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    if items.isEmpty {
                        explorerEmptyRow
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, clip in
                            explorerRow(clip: clip, index: idx)
                                .id(idx)
                                .onTapGesture(count: 2) { handleDoubleTap(at: idx) }
                                .onTapGesture {
                                    handleTap(at: idx, modifiers: CurrentInput.modifierFlags)
                                }
                                .draggableClip(clip, additionalSelected: selection.isSelected(clip.id ?? -1) ? selection.selectedItems(from: items).filter { $0.id != clip.id } : [])
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
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
            .onChange(of: selection.cursorIndex) { _, n in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(n, anchor: .center)
                }
            }
        }
    }

    private func explorerRow(clip: ClipItem, index: Int) -> some View {
        let isCursor = index == selection.cursorIndex
        let isSelected = selection.isSelected(clip.id ?? -1)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : clip.kind.iconName)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.preview)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(clip.kind.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    if let app = clip.sourceAppName, !app.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(app).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(clip.createdAt, style: .relative)
                        .font(.system(size: 9))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground(isCursor: isCursor, isSelected: isSelected))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isCursor ? Color.accentColor.opacity(0.9) : .clear,
                    lineWidth: isCursor ? 1.5 : 0
                )
        )
        .contentShape(Rectangle())
    }

    private func rowBackground(isCursor: Bool, isSelected: Bool) -> Color {
        if isCursor   { return Color.accentColor.opacity(0.18) }
        if isSelected { return Color.accentColor.opacity(0.10) }
        return Color.primary.opacity(0.04)
    }

    private var explorerEmptyRow: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("クリップがありません")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    @ViewBuilder
    private var explorerPreview: some View {
        if items.indices.contains(selection.cursorIndex) {
            ClipPreviewView(clip: items[selection.cursorIndex], isCompact: false)
                .padding(12)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("クリップを選択してください")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
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
            // Explorer モードは縦リスト主体なので ↑/↓ もカーソル移動に振る。
            // カルーセル時は ←/→ と併用しても無害（同じ axis を動かすだけ）。
            onUp:           { selection.moveCursor(by: -1, in: items) },
            onDown:         { selection.moveCursor(by:  1, in: items) },
            onLeft:         { selection.moveCursor(by: -1, in: items) },
            onRight:        { selection.moveCursor(by:  1, in: items) },
            onReturn:       { onReturn(plain: false) },
            onShiftReturn:  { onReturn(plain: true) },
            onOptionReturn: { pasteSelected(join: true) },
            onCmdReturn:    { pasteSelected(join: true) },
            onEsc:          { onEsc() },
            onNumber:       { n in pasteByIndex(n) },
            onSpace:        { selection.toggleCursor(in: items) },
            onTab:          { cycleFolder(by: 1) },
            onShiftTab:     { cycleFolder(by: -1) },
            onShiftUp:      { selection.extend(by: -1, in: items) },
            onShiftDown:    { selection.extend(by:  1, in: items) },
            onShiftLeft:    { selection.extend(by: -1, in: items) },
            onShiftRight:   { selection.extend(by:  1, in: items) },
            onCmdA:         { selection.selectAll(in: items) },
            onCmdN:         { showingNewSnippet = true; newSnippetText = "" },
            onCmdD:         { selection.clearAll() },
            onCmdI:         { showAIMenu() },
            onCmdComma:     { onOpenSettings() },
            onCmdP:         { SettingsStore.shared.explorerMode.toggle() },
            onCmdY:         { showQuickLook() },
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

    /// Tab / Shift+Tab で「履歴 → 各フォルダ → 履歴 …」を循環。
    /// `direction` は +1 (Tab) または -1 (Shift+Tab)。
    private func cycleFolder(by direction: Int) {
        // 並び：履歴(nil) → ピンボード一覧
        var ids: [Int64?] = [nil]
        ids.append(contentsOf: pinboards.boards.compactMap { $0.id })
        guard ids.count > 1 else { return }
        let currentIdx = ids.firstIndex(of: folderID) ?? 0
        let nextIdx = ((currentIdx + direction) % ids.count + ids.count) % ids.count
        folderID = ids[nextIdx]
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

    /// シングルクリック: 単にカーソルを移動 / 選択（貼付はしない）。
    /// AI アクションやプレビューを使う前段なので、誤って貼付しないように
    /// 「クリック ≠ 即貼付」のメンタルモデルに揃える。
    private func handleTap(at index: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            selection.shiftTap(at: index, in: items); return
        }
        if modifiers.contains(.command) {
            selection.commandTap(at: index, in: items); return
        }
        // 通常クリック: カーソル位置を移すだけ、複数選択モード時はトグル。
        if selection.multiMode {
            _ = selection.tap(at: index, in: items)
        } else {
            selection.cursorIndex = index
        }
    }

    /// ダブルクリック: 即時貼付（従来のシングルクリックの挙動）。
    private func handleDoubleTap(at index: Int) {
        guard items.indices.contains(index) else { return }
        let clip = items[index]
        // dismiss → paste の順。PasteAutomator 側で 60ms 待ってからクリックを
        // 撃つので、パネルが完全に消えるまでの猶予がある。
        onDismiss()
        PasteAutomator.shared.paste(clip)
    }

    private func onReturn(plain: Bool) {
        // 動的 Enter: 選択が 2 件以上なら結合貼付 (改行で繋いで末尾改行)、
        // 0 または 1 件なら通常の単体貼付。Raycast 拡張側と挙動を揃える。
        if selection.count >= 2 { pasteSelected(join: true, plain: plain) }
        else if selection.hasSelection { pasteSelected(join: false, plain: plain) }
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

    /// フォルダ内クリップの「このフォルダでの表示名」をユーザーに入力させて保存。
    private func promptRenameClipInFolder(clip: ClipItem, pinboardId: Int64) {
        guard let cid = clip.id else { return }
        let alert = NSAlert()
        alert.messageText = "フォルダ内での名前"
        alert.informativeText = "このフォルダで表示する名前を入力してください。空にすると元のプレビューだけ表示します。"
        // 既に名前が付いていればそれを初期値に。
        let initial = clip.pinDisplayTitle ?? ""
        let field = NSTextField(string: initial)
        field.placeholderString = "例: 営業挨拶、テンプレート 1 ……"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            let newTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                try? await pinboards.renameItem(clipId: cid, in: pinboardId, to: newTitle)
                reload()
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

/// **Paste 風だが Pasty 流の Liquid Glass ニュアンス** を加えた v0.4.5 のカード。
/// 構成:
///   ┌────────────────────────┐
///   │ ▮ TEXT  5 days ago   │ Safari │ ← 上部カラーバンド + 相対時刻 + ソースアプリアイコン
///   ├────────────────────────┤
///   │                        │
///   │   コンテンツプレビュー │ ← 画像 / コード / Markdown / リッチテキストを最適化
///   │                        │
///   ├────────────────────────┤
///   │ kvellhome.com/lookbook │ ← URL ドメインやファイル名
///   │             175 chars  │
///   └────────────────────────┘
private struct StripCard: View {
    let clip: ClipItem
    let index: Int
    let isCursor: Bool
    let isSelected: Bool
    var selectionOrder: Int? = nil

    // Linear / Things 系の「カード = 240×260, 上下 4pt グリッド」を踏襲。
    // 上部バンドは少し背を低くしてシャープに、フッタはゆったり余白を取る。
    private static let cardSize = CGSize(width: 240, height: 264)
    private static let bannerHeight: CGFloat = 42
    private static let footerHeight: CGFloat = 38

    var body: some View {
        ZStack(alignment: .topLeading) {
            // === ベース：ガラス + 3 層シャドウ（Apple HIG / Linear / Vercel 系）===
            // 3 層シャドウで「机に置いた紙」を表現:
            //   Layer 1: 接地影（縁を引き締める、極めて近い）
            //   Layer 2: 中距離影（カード本体の "浮き" を作る）
            //   Layer 3: アンビエント影（遠くに広がる柔らかい光の落ち込み）
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                // 内側のかすかな天井ハイライト（ガラスの反射）
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(LinearGradient(
                            colors: [Color.white.opacity(0.28),
                                     Color.white.opacity(0.06),
                                     Color.white.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        ), lineWidth: 0.5)
                )
                // Layer 1: 接地影 — 縁の境界を引き締める
                .shadow(color: .black.opacity(0.16),
                        radius: 1.5, x: 0, y: 1)
                // Layer 2: 中距離影 — カードの "浮き" を作る
                .shadow(color: .black.opacity(isCursor ? 0.22 : 0.14),
                        radius: isCursor ? 14 : 8,
                        x: 0, y: isCursor ? 8 : 4)
                // Layer 3: アンビエント影 — 遠くに広がる柔らかい影、空気感
                .shadow(color: .black.opacity(isCursor ? 0.28 : 0.16),
                        radius: isCursor ? 36 : 20,
                        x: 0, y: isCursor ? 18 : 10)

            VStack(spacing: 0) {
                banner
                content
                footer
            }

            // === 番号バッジ ⌘N（左下）===
            if index <= 9 {
                HStack(spacing: 2) {
                    Text("⌘")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                    Text("\(index)")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(ModernTokens.hairline, lineWidth: 0.5)
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            // === 選択チェック（右下）===
            if isSelected {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .shadow(color: Color.accentColor.opacity(0.4),
                                radius: 6, x: 0, y: 2)
                    // 選択順番号を優先表示、無ければ checkmark フォールバック
                    if let order = selectionOrder {
                        Text("\(order)")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomTrailing)
                .accessibilityHidden(true)
            }
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isCursor ? 1.5 : 0.5)
        )
        // Linear 風スプリング微小モーション
        .scaleEffect(isCursor ? 1.025 : 1.0)
        .offset(y: isCursor ? -2 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isCursor)
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

    // MARK: - Banner

    private var banner: some View {
        let kindColor = KindPalette.detectedColor(for: clip)
        let kindLabel = KindPalette.detectedLabel(for: clip)
        let displayTitle = clip.pinDisplayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = (displayTitle?.isEmpty == false)
        return ZStack(alignment: .leading) {
            // 多層グラデーション: 立体感を出すために左上に光、右下に影
            LinearGradient(
                colors: [
                    kindColor.opacity(1.0),
                    kindColor.opacity(0.92),
                    kindColor.opacity(0.78)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // 上端のかすかなハイライト（Linear 風）
            VStack {
                LinearGradient(
                    colors: [Color.white.opacity(0.18), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 14)
                Spacer()
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if hasTitle, let t = displayTitle {
                        // タイトル: 大きく、明瞭に。SF Pro Display 系。
                        Text(t)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .tracking(-0.1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
                        // サブテキスト: kind ・ time の組み合わせ
                        HStack(spacing: 5) {
                            Text(kindLabel)
                                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(0.9))
                            Circle()
                                .fill(.white.opacity(0.55))
                                .frame(width: 2, height: 2)
                            Text(RelativeTimeFormatter.string(from: clip.createdAt))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    } else {
                        // タイトル無しの場合は kind を主役に
                        Text(kindLabel)
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
                        Text(RelativeTimeFormatter.string(from: clip.createdAt))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.86))
                    }
                }
                Spacer(minLength: 4)
                // ソースアプリアイコン: ドロップシャドウ付き
                Group {
                    if let bid = clip.sourceBundleId,
                       let icon = SourceAppIconCache.shared.icon(forBundleID: bid) {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: clip.kind.iconName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white.opacity(0.18))
                            )
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1.5)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: Self.bannerHeight)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            if clip.kind == .image, let p = clip.dataPath,
               let img = ImageBlobCache.shared.image(for: p) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
            } else if clip.kind == .file,
                      let img = FileImageThumbnailCache.shared.image(for: clip) {
                // 画像ファイル (CleanShot 等のスクショ、png/jpg/heic 等) を実プレビュー表示
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
            } else if clip.kind == .file, let bid = clip.sourceBundleId,
                      let icon = SourceAppIconCache.shared.icon(forBundleID: bid) {
                VStack(spacing: 8) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                    Text(URL(string: clip.content ?? "")?.lastPathComponent
                         ?? clip.preview)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
            } else {
                // テキスト系。コードならモノスペース、それ以外は標準。
                let isCodeLike = KindPalette.detectedLabel(for: clip)
                    .matches(["CODE", "JSON", "HTML"])
                Text(clip.preview)
                    .font(isCodeLike
                          ? .system(size: 11.5, weight: .medium, design: .monospaced)
                          : .system(size: 12.5, weight: .regular))
                    .tracking(isCodeLike ? 0 : -0.05)
                    .lineSpacing(2)
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(9)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
        .frame(maxHeight: Self.cardSize.height - Self.bannerHeight - Self.footerHeight)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            // 左：URL ドメイン or ファイル名 (シャドウなしで上品に)
            if let s = DomainShortener.short(for: clip) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text(s)
                        .font(.system(size: 11, weight: .medium))
                        .tracking(-0.05)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if let app = clip.sourceAppName {
                Text(app)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(-0.05)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // 右：文字数 or サイズ — トーキュラフォントで数字を整える
            Text(rightMeta)
                .font(.system(size: 10.5, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.footerHeight)
        .background(
            ZStack {
                // ヘアラインの上枠で区切る (shadcn流)
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.5)
                    LinearGradient(
                        colors: [Color.clear, Color.primary.opacity(0.025)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
        )
    }

    private var rightMeta: String {
        switch clip.kind {
        case .image:
            return ByteCountFormatter.string(fromByteCount: clip.byteSize, countStyle: .file)
        case .file:
            return ByteCountFormatter.string(fromByteCount: clip.byteSize, countStyle: .file)
        default:
            return "\((clip.content ?? clip.preview).count) chars"
        }
    }

    private var accessibilityHintText: String {
        let kind = clip.kind.rawValue
        let source = clip.sourceAppName ?? ""
        return source.isEmpty ? kind : "\(kind), \(source)"
    }

    private var borderColor: Color {
        if isCursor   { return Color.accentColor.opacity(0.9) }
        if isSelected { return Color.accentColor.opacity(0.55) }
        return Color.primary.opacity(0.06)
    }
}
