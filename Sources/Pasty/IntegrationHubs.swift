import AppKit
import SwiftUI

// MARK: - Template Field Runtime
// `[[name]]` プレースホルダの値を「貼付直前のフォーム入力」→「貼付処理」へ
// 1 ホップで渡すための一時バッファ。

@MainActor
enum TemplateFieldRuntime {
    private static var pendingValues: [String: String] = [:]

    static func setPending(_ values: [String: String]) {
        pendingValues = values
    }

    static func clearPending() {
        pendingValues.removeAll()
    }

    /// `[[name]]` を pendingValues で置換した結果を返す。空なら原文。
    static func applyPendingValues(to template: String) -> String {
        guard !pendingValues.isEmpty else { return template }
        let result = SnippetEngine.applyMailMergeValues(template, values: pendingValues)
        // 1 回限りの使用にする。
        pendingValues.removeAll()
        return result
    }
}

// MARK: - Template Field Presenter
// `[[name]]` を含むテンプレートを貼付しようとした時、ダイアログを出して
// 値を集めるユーティリティ。
@MainActor
enum TemplateFieldPresenter {
    /// テンプレ本文を見て `[[name]]` が含まれていれば、ダイアログを出し、
    /// ユーザが値を入れて確定したら `then` を呼ぶ。プレースホルダがなければ
    /// 即 `then` を呼ぶ。
    static func presentIfNeeded(for raw: String, then: @escaping () -> Void) {
        let fieldNames = SnippetEngine.parseMailMergeFields(raw)
        guard !fieldNames.isEmpty else {
            TemplateFieldRuntime.clearPending()
            then()
            return
        }

        let fields = fieldNames.map {
            TemplateField(id: $0, label: $0, value: "", suggestions: [])
        }
        let view = TemplateFieldDialog(
            template: raw,
            fields: fields,
            onCancel: {
                TemplateFieldRuntime.clearPending()
                dismissPanel()
            },
            onConfirm: { _, values in
                TemplateFieldRuntime.setPending(values)
                dismissPanel()
                then()
            }
        )
        showPanel(view: view)
    }

    private static var panel: NSPanel?

    private static func showPanel<V: View>(view: V) {
        dismissPanel()
        let hosting = NSHostingController(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        p.title = "テンプレート入力"
        p.contentViewController = hosting
        p.isFloatingPanel = true
        p.level = .floating
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    private static func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - AI Action Coordinator
// パネルから ⌘I / ⌃⇧R-E で呼ばれる AI アクションの実行と、結果の新クリップ
// 化、エラーハンドリングまで面倒を見るハブ。

@MainActor
final class AIActionCoordinator {
    static let shared = AIActionCoordinator()
    private init() {}

    private var activePanel: NSPanel?

    func presentMenu(for clip: ClipItem,
                     store: ClipStore,
                     onPick: ((AIAction) -> Void)? = nil) {
        let view = AIActionMenu(clip: clip,
                                onSelect: { [weak self] action in
                                    self?.dismissMenu()
                                    self?.execute(action, on: clip, store: store)
                                    onPick?(action)
                                },
                                onDismiss: { [weak self] in self?.dismissMenu() })
        let hosting = NSHostingController(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentViewController = hosting
        p.isFloatingPanel = true
        p.level = .modalPanel
        p.center()
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        activePanel = p
    }

    func dismissMenu() {
        activePanel?.orderOut(nil)
        activePanel = nil
    }

    func execute(_ action: AIAction, on clip: ClipItem, store: ClipStore) {
        let source = clip.content ?? clip.preview
        Task {
            do {
                let result = try await AIEngine.perform(action, on: source)
                let newClip = try await store.createTextClip(
                    content: result.text,
                    sourceAppName: "Pasty AI"
                )
                PasteToast.shared.show(targetApp: nil,
                                       customMessage: actionLabel(for: action) + " 完了")
                _ = newClip
            } catch {
                PasteToast.shared.show(targetApp: nil,
                                       customMessage: "AI 失敗: \(error.localizedDescription)")
            }
        }
    }

    private func actionLabel(for action: AIAction) -> String {
        switch action {
        case .rewrite:   return "書き直し"
        case .translate: return "翻訳"
        case .summarize: return "要約"
        case .reformat:  return "変換"
        case .emailify:  return "メール整形"
        }
    }
}

// MARK: - Paste history (再貼付 + paste_count)

@MainActor
final class PasteHistory {
    static let shared = PasteHistory()
    private init() {}

    private(set) var lastPastedClip: ClipItem?
    private(set) var lastPastedAt: Date?

    /// `pasteCount: [clipId: count]` をメモリ上で簡易追跡。
    /// 永続化は v0.5 で paste_events テーブルとして再設計予定。
    private(set) var pasteCount: [Int64: Int] = [:]

    func record(_ clip: ClipItem) {
        lastPastedClip = clip
        lastPastedAt = Date()
        if let id = clip.id {
            pasteCount[id, default: 0] += 1
        }
    }

    func repasteLast() {
        guard let last = lastPastedClip else {
            NSSound(named: "Funk")?.play()
            PasteToast.shared.show(targetApp: nil, customMessage: "再貼付する履歴がありません")
            return
        }
        PasteAutomator.shared.paste(last)
    }

    /// Undo Paste — 直前の貼付先アプリに ⌘Z を送出。
    func undoLast() {
        Task { @MainActor in
            await PreviousAppTracker.shared.restoreFocus()
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x06, keyDown: true) // kVK_ANSI_Z
            down?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0x06, keyDown: false)
            up?.flags = .maskCommand
            up?.post(tap: .cghidEventTap)
            PasteToast.shared.show(targetApp: nil, customMessage: "直前の貼付を取り消し")
        }
    }
}
