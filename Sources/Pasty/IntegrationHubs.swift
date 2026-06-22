import AppKit
import ApplicationServices
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
            TemplateField(
                id: $0,
                label: $0,
                value: "",
                suggestions: FieldHistoryStore.shared.suggestions(for: $0)
            )
        }
        let view = TemplateFieldDialog(
            template: raw,
            fields: fields,
            onCancel: {
                TemplateFieldRuntime.clearPending()
                dismissPanel()
            },
            onConfirm: { _, values in
                // ユーザが確定した値はそのままサジェスト履歴にフィードバック。
                // 空文字は store 側で弾くのでここでは丸ごと渡す。
                for (key, value) in values {
                    FieldHistoryStore.shared.record(fieldName: key, value: value)
                }
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

/// borderless だけど key window になれる NSPanel。これがないと内部の
/// `KeyHandlingView.onEsc` クロージャが発火せず、Esc でも閉じられない。
final class AIActionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AIActionCoordinator {
    static let shared = AIActionCoordinator()
    private init() {}

    private var activePanel: NSPanel?
    private var escMonitor: Any?

    func presentMenu(for clip: ClipItem,
                     store: ClipStore,
                     onPick: ((AIAction) -> Void)? = nil) {
        let view = AIActionMenu(
            clip: clip,
            onSelect: { [weak self] action in
                self?.dismissMenu()
                self?.execute(action, on: clip, store: store)
                onPick?(action)
            },
            onSelectMacro: { [weak self] macro in
                self?.dismissMenu()
                self?.executeMacro(macro, on: clip, store: store)
            },
            onDismiss: { [weak self] in self?.dismissMenu() }
        )
        let hosting = NSHostingController(rootView: view)
        let p = AIActionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
            styleMask: [.borderless],
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
        // Activate first so the new key window actually receives keyDown.
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeKey()
        activePanel = p

        // SwiftUI 内の KeyHandlingView がフォーカスから外れていても確実に
        // Esc を捕まえる保険。Pasty にフォーカスが乗っている間だけ動く。
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // keyCode 53 = Esc
            if event.keyCode == 53 {
                Task { @MainActor in self?.dismissMenu() }
                return nil
            }
            return event
        }
    }

    func dismissMenu() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        activePanel?.orderOut(nil)
        activePanel = nil
    }

    func execute(_ action: AIAction, on clip: ClipItem, store: ClipStore) {
        let source = clip.content ?? clip.preview
        let label = actionLabel(for: action)
        let settings = SettingsStore.shared
        let useGlow = settings.aiGlowEnabled
        let useSound = settings.aiSoundEnabled
        let successSound = settings.aiSoundName

        // 0 ms フィードバック: 走り始めたことを画面端の青パルスで伝える。
        if useGlow {
            ScreenGlowController.shared.showRunning()
        }

        Task {
            do {
                let result = try await AIEngine.perform(action, on: source)
                let newClip = try await store.createTextClip(
                    content: result.text,
                    sourceAppName: "Pasty AI"
                )
                PasteToast.shared.show(targetApp: nil,
                                       customMessage: label + " 完了")
                _ = newClip
                if useGlow { ScreenGlowController.shared.showSuccess() }
                if useSound, let s = NSSound(named: NSSound.Name(successSound)) {
                    s.play()
                }
            } catch {
                // v0.9.6-beta (P1 #10): typed AIError で原因別の文言を出す。
                let msg = aiErrorToastMessage(error)
                PasteToast.shared.show(targetApp: nil, customMessage: msg)
                if useGlow { ScreenGlowController.shared.showFailure() }
                if useSound, let s = NSSound(named: NSSound.Name("Funk")) {
                    s.play()
                }
            }
        }
    }

    /// v0.9.6-beta (P1 #10): typed AIError → UI 文言マップ。
    private func aiErrorToastMessage(_ error: Error) -> String {
        switch AIError.from(error) {
        case .modelNotAvailable:
            return "Apple Intelligence のモデルが利用できません。設定から有効化してください。"
        case .osUnsupported:
            return "この機能は macOS の対応バージョンが必要です"
        case .aiDisabledBySettings:
            return "AI 機能は設定で無効になっています"
        case .other:
            return "AI 処理でエラーが発生しました"
        }
    }

    /// B2: AI マクロを順次実行する。各ステップの出力が次ステップの入力になる。
    /// 成功時は新規クリップ 1 件 (`sourceAppName = "Pasty AI · <macro name>"`) を作成。
    /// 中断/失敗時はトーストでステップを通知し、それ以降を打ち切る。
    func executeMacro(_ macro: AIMacro, on clip: ClipItem, store: ClipStore) {
        let resolvedActions = macro.actions.compactMap { $0.resolved() }
        guard !resolvedActions.isEmpty else {
            PasteToast.shared.show(targetApp: nil,
                                   customMessage: "マクロにアクションがありません")
            NSSound(named: "Funk")?.play()
            return
        }

        let settings = SettingsStore.shared
        let useGlow = settings.aiGlowEnabled
        let useSound = settings.aiSoundEnabled
        let successSound = settings.aiSoundName

        if useGlow {
            ScreenGlowController.shared.showRunning()
        }

        let source = clip.content ?? clip.preview
        let macroName = macro.name

        Task {
            var current = source
            do {
                for (idx, action) in resolvedActions.enumerated() {
                    let result = try await AIEngine.perform(action, on: current)
                    current = result.text
                    let stepLabel = "ステップ \(idx + 1)/\(resolvedActions.count) 完了"
                    PasteToast.shared.show(targetApp: nil, customMessage: stepLabel)
                }
                _ = try await store.createTextClip(
                    content: current,
                    sourceAppName: "Pasty AI · \(macroName)"
                )
                PasteToast.shared.show(targetApp: nil,
                                       customMessage: "マクロ「\(macroName)」完了")
                if useGlow { ScreenGlowController.shared.showSuccess() }
                if useSound, let s = NSSound(named: NSSound.Name(successSound)) {
                    s.play()
                }
            } catch {
                // v0.9.6-beta (P1 #10): typed AIError → 文言。
                let msg = "マクロ失敗: " + aiErrorToastMessage(error)
                PasteToast.shared.show(targetApp: nil, customMessage: msg)
                if useGlow { ScreenGlowController.shared.showFailure() }
                if useSound, let s = NSSound(named: NSSound.Name("Funk")) {
                    s.play()
                }
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

            // 永続化 (v0.4.2): メモリ上のカウンタに加えて paste_events にも記録。
            // ClipStore がまだ用意されていなければ静かに無視する（ベストエフォート）。
            // 直前の貼付先アプリは PreviousAppTracker から取得。
            let targetApp = PreviousAppTracker.shared.previous
            let bid = targetApp?.bundleIdentifier
            let name = targetApp?.localizedName
            if let store = ClipStoreContainer.shared.store {
                Task {
                    try? await store.recordPaste(
                        clipId: id,
                        targetBundleId: bid,
                        targetAppName: name
                    )
                }
            }
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
            // v0.9.6-beta (audit follow-up #4): synthesized ⌘Z は HID event tap を
            // 通るので Accessibility 権限が無いと黙って失敗する。明示的にガードして
            // 失敗理由を broadcast し、トースト UI 側で「権限が無い」と分かるようにする。
            guard AXIsProcessTrusted() else {
                NotificationCenter.default.post(
                    name: .pastyPasteFailed,
                    object: nil,
                    userInfo: ["reason": "no_accessibility"]
                )
                PasteToast.shared.show(
                    targetApp: nil,
                    customMessage: "アクセシビリティ権限が無効です。設定で再付与してください"
                )
                PasteAutomator.showAccessibilityRevokedAlert()
                return
            }
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
