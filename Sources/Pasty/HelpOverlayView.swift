import AppKit
import SwiftUI

// MARK: - Shortcut Model

/// 1 つのキーボードショートカット行を表現するモデル。
private struct ShortcutEntry: Identifiable {
    let id = UUID()
    /// キーキャップ列。複数キーの組み合わせは配列で並べる（例: ["⇧", "⌘", "V"]）。
    /// ノッチホバーのような非キー説明はラベル付きキャップとして表示する。
    let keys: [String]
    /// 説明テキスト。
    let detail: String
    /// キャップ表示ではなく自由テキストとして描画したい場合に使う（例: "ノッチホバー"）。
    let isFreeformLeading: Bool

    init(keys: [String], detail: String, isFreeformLeading: Bool = false) {
        self.keys = keys
        self.detail = detail
        self.isFreeformLeading = isFreeformLeading
    }
}

/// カテゴリ単位のショートカット集。
private struct ShortcutCategory: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let entries: [ShortcutEntry]
}

// MARK: - Help Overlay View

@MainActor
struct HelpOverlayView: View {
    let onDismiss: () -> Void

    @State private var appeared = false

    private let categories: [ShortcutCategory] = HelpOverlayView.makeCategories()

    var body: some View {
        ZStack {
            // 半透明の暗幕：クリックで閉じる
            Color.black
                .opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            // 中央カード
            card
                .frame(maxWidth: 920, maxHeight: 640)
                .scaleEffect(appeared ? 1.0 : 0.97)
                .opacity(appeared ? 1.0 : 0.0)
                .animation(.easeOut(duration: 0.18), value: appeared)
        }
        .onAppear { appeared = true }
        .background(KeyCatcher(onEscape: onDismiss))
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            ScrollView(.vertical, showsIndicators: false) {
                gridContent
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
            }
        }
        .background(VisualEffectBackground(material: .hudWindow, blending: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 40, x: 0, y: 18)
        .padding(40)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pasty キーボードショートカット")
                    .font(.system(size: 18, weight: .semibold))
                Text("どこからでも素早く呼び出せる主要アクション一覧")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                KeyCap(text: "⎋", size: .small)
                Text("で閉じる")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var gridContent: some View {
        let columns = [
            GridItem(.flexible(minimum: 320), spacing: 28, alignment: .topLeading),
            GridItem(.flexible(minimum: 320), spacing: 28, alignment: .topLeading)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(categories) { category in
                categoryBlock(category)
            }
        }
    }

    private func categoryBlock(_ category: ShortcutCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(category.entries) { entry in
                    shortcutRow(entry)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func shortcutRow(_ entry: ShortcutEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                if entry.isFreeformLeading, let label = entry.keys.first {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                } else {
                    ForEach(entry.keys, id: \.self) { key in
                        KeyCap(text: key)
                    }
                }
            }
            .frame(minWidth: 110, alignment: .leading)

            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Text(entry.detail)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Data

    private static func makeCategories() -> [ShortcutCategory] {
        [
            ShortcutCategory(
                title: "呼び出し",
                symbol: "sparkles",
                entries: [
                    ShortcutEntry(keys: ["⇧", "⌘", "V"], detail: "プライマリサーフェスを開く / 閉じる"),
                    ShortcutEntry(keys: ["⌥", "⇧", "V"], detail: "セカンダリサーフェスを開く"),
                    ShortcutEntry(keys: ["⌃", "⇧", "P"], detail: "キャプチャを 60 秒一時停止"),
                    ShortcutEntry(keys: ["⌃", "⇧", "Z"], detail: "直前の貼付を取り消し"),
                    ShortcutEntry(keys: ["ノッチホバー"], detail: "上から降りてくる", isFreeformLeading: true)
                ]
            ),
            ShortcutCategory(
                title: "ナビゲーション",
                symbol: "arrow.up.and.down.and.arrow.left.and.right",
                entries: [
                    ShortcutEntry(keys: ["↑", "↓", "←", "→"], detail: "カーソル移動"),
                    ShortcutEntry(keys: ["⇧", "↑"], detail: "範囲選択（上方向）"),
                    ShortcutEntry(keys: ["⇧", "↓"], detail: "範囲選択（下方向）"),
                    ShortcutEntry(keys: ["⌘", "A"], detail: "全件選択"),
                    ShortcutEntry(keys: ["⌘", "1〜9"], detail: "N 番目を直接貼付")
                ]
            ),
            ShortcutCategory(
                title: "選択 & 貼付",
                symbol: "doc.on.clipboard",
                entries: [
                    ShortcutEntry(keys: ["↩"], detail: "選択中を貼付（複数選択時は順次）"),
                    ShortcutEntry(keys: ["⇧", "↩"], detail: "プレーンテキストで貼付"),
                    ShortcutEntry(keys: ["⌥", "↩"], detail: "結合して 1 ブロックで貼付"),
                    ShortcutEntry(keys: ["⌘", "Space"], detail: "現在のカードを選択トグル")
                ]
            ),
            ShortcutCategory(
                title: "プレビュー & 編集",
                symbol: "eye",
                entries: [
                    ShortcutEntry(keys: ["Space"], detail: "Quick Look 全画面"),
                    ShortcutEntry(keys: ["⌘", "E"], detail: "インライン編集"),
                    ShortcutEntry(keys: ["⌘", "P"], detail: "Explorer モード切替"),
                    ShortcutEntry(keys: ["⌘", "N"], detail: "新しい定型文を作成"),
                    ShortcutEntry(keys: ["⌘", "D"], detail: "Diff 表示（2 件選択時）")
                ]
            ),
            ShortcutCategory(
                title: "AI アクション",
                symbol: "wand.and.stars",
                entries: [
                    ShortcutEntry(keys: ["⌘", "I"], detail: "AI アクションメニュー"),
                    ShortcutEntry(keys: ["⌃", "⇧", "R"], detail: "書き直し"),
                    ShortcutEntry(keys: ["⌃", "⇧", "T"], detail: "翻訳"),
                    ShortcutEntry(keys: ["⌃", "⇧", "S"], detail: "要約"),
                    ShortcutEntry(keys: ["⌃", "⇧", "J"], detail: "フォーマット変換"),
                    ShortcutEntry(keys: ["⌃", "⇧", "E"], detail: "メール風整形")
                ]
            ),
            ShortcutCategory(
                title: "その他",
                symbol: "ellipsis.circle",
                entries: [
                    ShortcutEntry(keys: ["⌘", "F"], detail: "検索フィールドにフォーカス"),
                    ShortcutEntry(keys: ["⌘", "M"], detail: "フォルダへ移動"),
                    // v0.9.9-beta (Cluster G): キーボードでフォルダ並び替え
                    ShortcutEntry(keys: ["⌥", "↑/↓"], detail: "フォルダを並び替え"),
                    ShortcutEntry(keys: ["⌥", "⇧", "↑/↓"], detail: "フォルダを先頭/末尾へ"),
                    ShortcutEntry(keys: ["⌘", ","], detail: "設定を開く"),
                    ShortcutEntry(keys: ["⌘", "?"], detail: "このヘルプ"),
                    ShortcutEntry(keys: ["⌫"], detail: "削除"),
                    ShortcutEntry(keys: ["⎋"], detail: "パネル / ヘルプを閉じる")
                ]
            )
        ]
    }
}

// MARK: - KeyCap

/// 角丸でくくった 1 キー分の小さなキーキャップ。
private struct KeyCap: View {
    enum Size { case small, regular }

    let text: String
    var size: Size = .regular

    var body: some View {
        let fontSize: CGFloat = (size == .small) ? 10 : 11
        let horizontalPadding: CGFloat = (size == .small) ? 6 : 8
        let verticalPadding: CGFloat = (size == .small) ? 2 : 3
        let minWidth: CGFloat = (size == .small) ? 18 : 22

        return Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minWidth: minWidth)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
    }
}

// MARK: - Escape Key Catcher

/// オーバーレイ用に Esc キーを捕まえる NSView ブリッジ。
private struct KeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = EscapeCatchingView()
        view.onEscape = onEscape
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EscapeCatchingView)?.onEscape = onEscape
    }

    private final class EscapeCatchingView: NSView {
        var onEscape: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Escape
                onEscape?()
            } else {
                super.keyDown(with: event)
            }
        }

        override func cancelOperation(_ sender: Any?) {
            onEscape?()
        }
    }
}

// MARK: - Help Overlay Panel

/// 画面全体を覆うボーダーレスパネル。
@MainActor
final class HelpOverlayPanel: NSPanel {
    init() {
        let rect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        HelpOverlayPresenter.shared.hide()
    }
}

// MARK: - Presenter

@MainActor
final class HelpOverlayPresenter {
    static let shared = HelpOverlayPresenter()

    private var panel: HelpOverlayPanel?
    private(set) var isVisible: Bool = false

    private init() {}

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        if isVisible { return }

        let panel = panel ?? makePanel()
        self.panel = panel

        // 画面サイズに合わせて毎回リサイズ
        if let frame = NSScreen.main?.frame {
            panel.setFrame(frame, display: false)
        }

        // フェードイン
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        isVisible = true
    }

    func hide() {
        guard isVisible, let panel = panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.isVisible = false
        })
    }

    private func makePanel() -> HelpOverlayPanel {
        let panel = HelpOverlayPanel()
        let host = NSHostingController(
            rootView: HelpOverlayView(onDismiss: { [weak self] in
                self?.hide()
            })
        )
        host.view.frame = panel.contentRect(forFrameRect: panel.frame)
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view
        return panel
    }
}
