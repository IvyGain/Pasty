import AppKit
import Carbon.HIToolbox
import ApplicationServices
import os

private let pasteAutomatorLogger = Logger(subsystem: "io.pasty.app", category: "PasteAutomator")

/// v0.9.6-beta (P0 #10 / #11): broadcast when a paste attempt aborts so a
/// future toast UI listener can offer to open System Settings (for
/// `reason == "accessibility"`) or surface a blob-read failure
/// (`reason == "blob_read"`). The toast UI itself is intentionally not built
/// in this codegen — see the TODO inside `place(_:)` / `emitCommandV()`.
///
/// userInfo keys:
///   - "reason": String — "accessibility" | "blob_read"
///   - "clipId": Int64 (blob_read only)
extension Notification.Name {
    static let pastyPasteFailed = Notification.Name("io.pasty.pasteFailed")
    /// v0.9.6-beta (P1 #8): セッション初回のペースト成功で 1 度だけ post される。
    /// Sparkle の初回バックグラウンドチェックを「ユーザーがちゃんと使い始めた」
    /// タイミングまで遅延させるためのトリガ。
    static let pastyFirstPasteCompleted = Notification.Name("pasty.firstPasteCompleted")
}

// TODO(v0.9.6-beta P0 #10): wire a toast listener that observes
// `.pastyPasteFailed`. For reason == "accessibility", offer a button that
// opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
// For reason == "blob_read", show "貼り付け元のファイルが見つかりませんでした" and
// the related clip id for support.

/// `ClipItem` をシステムのペーストボードに書き戻し、直前のフロントアプリに
/// 戻してから ⌘V を送出する。`paste(_:)` は単発、`pasteSequence(_:)` は
/// 複数アイテムを順番に貼り付ける（フォームへの自動入力や複数行展開向け）。
@MainActor
final class PasteAutomator {
    static let shared = PasteAutomator()
    private init() {}

    /// v0.9.6-beta (P1 #8): セッション内で `pastyFirstPasteCompleted` を 1 度だけ post する
    /// ためのガード。アプリプロセスが生きている間 true のまま据え置く。
    private static var hasPostedFirstPaste = false

    /// 初回ペースト成功時に内部から呼ぶ。post 後はフラグが固定されるため、
    /// 2 回目以降の呼び出しは no-op。
    static func notifyFirstPasteIfNeeded() {
        guard !hasPostedFirstPaste else { return }
        hasPostedFirstPaste = true
        NotificationCenter.default.post(name: .pastyFirstPasteCompleted, object: nil)
    }

    /// v0.9.6-beta (P1 #9): アクセシビリティ権限が失効していた時に
    /// 1 度だけ目立つ NSAlert を出す。連続発火しないよう 5 分のクールダウンを噛ます。
    private static var lastAccessibilityAlertAt: Date?

    static func showAccessibilityRevokedAlert() {
        if let last = lastAccessibilityAlertAt,
           Date().timeIntervalSince(last) < 300 {
            return
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "アクセシビリティ権限が必要です"
            alert.informativeText = "Pasty がペーストを実行するには、システム設定でアクセシビリティ権限を許可してください。"
            alert.addButton(withTitle: "システム設定を開く")
            alert.addButton(withTitle: "後で")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            lastAccessibilityAlertAt = Date()
        }
    }

    /// PanelCoordinator が「パネルを召喚した瞬間のマウス位置」を保存する場所。
    /// 貼付時にここへ合成クリックを送ることで「マウスがあった場所」にキャレットを
    /// 移してから ⌘V を撃つ → 「クリック位置に貼り付く」体験になる。
    var summonMouseLocation: NSPoint?

    /// Accessibility 権限が取れているか。初回は OS のダイアログを出す。
    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 1 つのクリップを貼り付ける。`autoPaste` が true なら ⌘V も送る。
    func paste(_ item: ClipItem, asPlainText: Bool = false, autoPaste: Bool = true) {
        // テンプレに `[[name]]` プレースホルダがあれば、貼付前に値を集める。
        // ユーザが入力を確定したら本体の `_doPaste` が呼ばれる。
        let raw = item.content ?? item.preview
        TemplateFieldPresenter.presentIfNeeded(for: raw) { [weak self] in
            self?._doPaste(item, asPlainText: asPlainText, autoPaste: autoPaste)
        }
    }

    private func _doPaste(_ item: ClipItem, asPlainText: Bool, autoPaste: Bool) {
        // 召喚時のマウス位置は「ここに貼って」の意思表示。クリック有効時は
        // パネル dismiss → 60ms 安定待ち → 合成クリック → 60ms → ⌘V の流れ。
        // 召喚位置が未記録の時は、ペースト指示時点でのマウス位置にフォールバック
        // して、必ずカーソル位置にクリックを撃つ。
        let savedSummon = summonMouseLocation ?? NSEvent.mouseLocation
        summonMouseLocation = nil

        Task { @MainActor in
            // v0.9.6-beta (P1 #21): if autoPaste is requested but accessibility
            // is revoked, the synthetic ⌘V will silently fail AFTER we've
            // already clobbered NSPasteboard.general — destroying whatever the
            // user had on their clipboard. Check up front and abort before any
            // pasteboard write so the user's existing clipboard contents stay
            // intact. Manual-place mode (autoPaste == false) still proceeds
            // because the user explicitly asked us to load the pasteboard.
            if autoPaste && !AXIsProcessTrusted() {
                NotificationCenter.default.post(
                    name: .pastyPasteFailed,
                    object: nil,
                    userInfo: ["reason": "no_accessibility"]
                )
                pasteAutomatorLogger.error("_doPaste: AXIsProcessTrusted false; aborting before pasteboard write")
                PasteAutomator.showAccessibilityRevokedAlert()
                return
            }

            place(item, asPlainText: asPlainText)
            guard autoPaste else {
                if SettingsStore.shared.toastEnabled {
                    PasteToast.shared.show(targetApp: nil,
                                           customMessage: "クリップボードに置きました")
                }
                return
            }

            // v0.8.1: パネル dismiss 後の安定待ちを 60ms → 30ms に短縮。
            // orderOut 直後でも CGEvent の合成タップは概ね 30ms あれば
            // 安全にターゲットアプリへ届く。短すぎる場合のみ次の Sleep で
            // 補完される。
            try? await Task.sleep(nanoseconds: 30_000_000)

            if SettingsStore.shared.clickBeforePaste {
                // クリック前に **必ず** 直前アプリにフォーカスを戻しておく。
                // これをやらないと、Pasty パネルが見えなくなった後も
                // 一瞬フォーカスが Pasty に残り、続く ⌘V が Pasty に
                // 送られて消えるケースがある。
                await PreviousAppTracker.shared.restoreFocus(grace: 0.04)
                // v0.8.1: クリック後の待機を 100ms → 50ms に短縮。
                // 50ms あれば多くのアプリでキャレット位置が確定するので、
                // ペースト体感の遅さを大きく削減。
                clickAtScreenPoint(savedSummon)
                try? await Task.sleep(nanoseconds: 50_000_000)
            } else {
                // クリックなしモードでは「直前アプリにフォーカスを戻す」
                // という従来挙動。
                await PreviousAppTracker.shared.restoreFocus(grace: 0.08)
            }

            emitCommandV()

            PasteHistory.shared.record(item)
            if SettingsStore.shared.toastEnabled {
                let app = PreviousAppTracker.shared.previous?.localizedName
                let anchor = savedSummon ?? NSEvent.mouseLocation
                PasteToast.shared.show(targetApp: app, near: anchor)
            }
            // v0.9.6-beta (P1 #8): セッション初回ペースト後に Sparkle 初回 BG チェックを起動。
            PasteAutomator.notifyFirstPasteIfNeeded()
        }
    }

    /// 与えられた **Cocoa 座標** (左下原点・y 上向き、全画面座標) に左クリック
    /// を 1 回送る。CGEvent は **Quartz 座標** (プライマリスクリーン左上原点・
    /// y 下向き) を使うので、ここで反転する。複数スクリーン環境でも
    /// プライマリの高さを使えば、全画面で正しく解釈される。
    private func clickAtScreenPoint(_ point: NSPoint) {
        // v0.9.6-beta (P0 #10): synthesized clicks also go through the HID
        // event tap, so they require Accessibility permission. If the
        // permission was revoked (e.g. after a re-sign of the ad-hoc bundle),
        // bail out and broadcast so the future toast listener can guide the
        // user to System Settings.
        guard AXIsProcessTrusted() else {
            NotificationCenter.default.post(
                name: .pastyPasteFailed,
                object: nil,
                userInfo: ["reason": "accessibility"]
            )
            pasteAutomatorLogger.error("clickAtScreenPoint: AXIsProcessTrusted false; aborting click")
            // v0.9.6-beta (P1 #9): surface a persistent NSAlert (cooldown 5 min)
            // so the user can jump straight to System Settings.
            PasteAutomator.showAccessibilityRevokedAlert()
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        let src = CGEventSource(stateID: .combinedSessionState)
        // mouseMove → mouseDown → mouseUp の順で送ると、対象アプリが
        // 「マウスがここに来てクリックされた」と確実に解釈する。
        if let move = CGEvent(mouseEventSource: src,
                              mouseType: .mouseMoved,
                              mouseCursorPosition: cgPoint,
                              mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        if let down = CGEvent(mouseEventSource: src,
                              mouseType: .leftMouseDown,
                              mouseCursorPosition: cgPoint,
                              mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: src,
                            mouseType: .leftMouseUp,
                            mouseCursorPosition: cgPoint,
                            mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    /// 複数クリップを順番に貼り付ける。
    /// - separator: 結合戦略
    ///     - `.join(string)` : 1 つの文字列に連結して 1 度だけ貼り付け（推奨デフォルト）
    ///     - `.sequence` : 各アイテムを置いて ⌘V → 次のアイテムを置いて ⌘V を反復
    ///                       （フォーム入力や Tab 区切りで「次の欄」に進めたい時用）
    func pasteSequence(_ items: [ClipItem],
                       asPlainText: Bool = false,
                       strategy: SequenceStrategy = .join(separator: "\n"),
                       autoPaste: Bool = true) {
        guard !items.isEmpty else { return }
        switch strategy {
        case .join(let sep):
            // 画像 / バイナリは「結合」には参加しない（=文字列に変換するのが嘘になる）。
            // ファイルパスは絶対パス文字列として文字列扱いする。
            let parts: [String] = items.compactMap { clip in
                switch clip.kind {
                case .image:
                    return clip.dataPath.map { ClipBlobs.blobURL(for: $0).path }
                case .file, .video:
                    return clip.content ?? clip.preview
                default:
                    return clip.content ?? clip.preview
                }
            }
            let merged = parts.joined(separator: sep)
            let synthetic = ClipItem(
                id: nil, createdAt: Date(),
                kind: .text,
                preview: String(merged.prefix(120)),
                content: merged,
                dataPath: nil,
                byteSize: Int64(merged.utf8.count),
                sourceBundleId: "io.pasty.bulk",
                sourceAppName: "Pasty Bulk",
                contentHash: ""
            )
            paste(synthetic, asPlainText: asPlainText, autoPaste: autoPaste)
        case .sequence(let delay):
            Task { @MainActor in
                guard autoPaste else {
                    // フォーカス復元しないモードでは最後のアイテムだけクリップに置く
                    if let last = items.last { place(last, asPlainText: asPlainText) }
                    return
                }
                await PreviousAppTracker.shared.restoreFocus()
                // v0.8.9: place → emit → sleep(delay) の順番に修正。
                // 旧実装は place → sleep(delay) → emit だったため、2 件目の place が
                // 1 件目のペースト完了前に pasteboard を上書きし、Slack/Notion など
                // 反応が遅いアプリで「最後の 1 件しか入らない」競合が起きていた。
                // delay も 0.12s → 0.25s に拡大して受信側の autocomplete 等を待つ。
                let interItemDelay = max(delay, 0.25)
                for (idx, item) in items.enumerated() {
                    place(item, asPlainText: asPlainText)
                    // pasteboard 反映直後の race を避けるため、emit 前に短いマージンを置く。
                    try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
                    emitCommandV()
                    // 受信側が ⌘V を消化する時間。最終アイテムだけは詰める必要がない。
                    if idx < items.count - 1 {
                        try? await Task.sleep(nanoseconds: UInt64(interItemDelay * 1_000_000_000))
                    }
                }
            }
        }
    }

    enum SequenceStrategy {
        /// 1 度の貼付に連結。改行 / カンマ / TAB などお好みのセパレータで。
        case join(separator: String)
        /// 1 アイテムごとに ⌘V を撃つ。`delay` は各 ⌘V の間隔。
        case sequence(delayBetween: TimeInterval)
    }

    // MARK: - private

    /// Pasty が自分で書き込んだ pasteboard 項目に付与する private marker type。
    /// PasteboardObserver 側でこの type を見つけたら新規クリップ取り込みをスキップする。
    static let suppressTypeRaw = "io.pasty.suppress"

    private func place(_ item: ClipItem, asPlainText: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // 先に suppress marker を仕込んでおく (clearContents の後・実コンテンツの前)。
        // 画像 case など内部で再 clearContents する分岐があるので、最後の `defer` でも
        // 再付与して "Pasty 由来" の印を必ず残す。
        defer {
            pb.setString("1", forType: NSPasteboard.PasteboardType(Self.suppressTypeRaw))
        }

        switch item.kind {
        case .text, .richText, .link, .color, .other:
            if let raw = item.content {
                // Step 1: `[[name]]` mail-merge プレースホルダを (もしユーザが直近
                // のフォームで埋めていれば) 値で置換
                let mailMerged = TemplateFieldRuntime.applyPendingValues(to: raw)
                // Step 2: {{date}} {{cursor}} {{uuid}} {{user}} {{clipboard}} などを展開
                let expanded = SnippetEngine.expand(mailMerged)
                pb.setString(expanded.text, forType: .string)
                if item.kind == .richText, !asPlainText, let data = expanded.text.data(using: .utf8) {
                    pb.setData(data, forType: .rtf)
                }
            } else {
                pb.setString(item.preview, forType: .string)
            }
        case .file, .video:
            if let s = item.content, let url = URL(string: s) {
                if url.isFileURL {
                    pb.writeObjects([url as NSURL])
                } else {
                    pb.setString(s, forType: .string)
                }
            }
        case .image:
            // 画像は dataPath からファイルを読んで pasteboard に NSImage として置く。
            // テキスト系 type は一切書かない (受信側が文字列フォールバックして
            // "PASTY|..." や preview を貼ってしまう問題を避ける)。
            guard let p = item.dataPath else {
                // v0.9.6-beta (P0 #11): data path missing on an image clip is
                // a structural failure (BlobGC may have reaped it, or the
                // row was inserted incorrectly). Broadcast so the toast UI
                // can surface "貼り付け元が見つかりません" and keep telemetry.
                let clipId = item.id ?? -1
                NotificationCenter.default.post(
                    name: .pastyPasteFailed,
                    object: nil,
                    userInfo: ["reason": "blob_read", "clipId": clipId]
                )
                pasteAutomatorLogger.error("blob read failed for clip \(clipId, privacy: .public): missing dataPath")
                // データパスが無い image kind は壊れている。preview を text として fallback
                let raw = item.content ?? item.preview
                if !raw.isEmpty {
                    pb.setString(raw, forType: .string)
                }
                return
            }
            let url = ClipBlobs.blobURL(for: p)
            guard let nsImage = NSImage(contentsOf: url) else {
                // v0.9.6-beta (P0 #11): the row points at a relative path that
                // no longer exists on disk (deleted out from under us, or the
                // blob dir was relocated). Broadcast and continue with text
                // fallback so the user gets *something*.
                let clipId = item.id ?? -1
                NotificationCenter.default.post(
                    name: .pastyPasteFailed,
                    object: nil,
                    userInfo: ["reason": "blob_read", "clipId": clipId]
                )
                pasteAutomatorLogger.error("blob read failed for clip \(clipId, privacy: .public): \(url.path, privacy: .public)")
                // ファイル読込失敗時も同様にテキスト fallback
                pb.setString(item.preview, forType: .string)
                return
            }
            // NSImage の TIFF と元データ (PNG/JPEG) を両方登録、テキスト系は登録しない。
            // place 先頭で既に clearContents 済みだが、writeObjects は append ではなく
            // clear→write なのでここで再度 clear して NSImage を正規に登録する。
            pb.clearContents()
            pb.writeObjects([nsImage])
            if let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                let type: NSPasteboard.PasteboardType
                switch ext {
                case "png": type = .png
                case "jpg", "jpeg":
                    type = NSPasteboard.PasteboardType(rawValue: "public.jpeg")
                case "tiff", "tif": type = .tiff
                default: type = .tiff
                }
                pb.setData(data, forType: type)
            }
        }
    }

    private func emitCommandV() {
        // ad-hoc 署名のまま Pasty.app を再ビルドすると Accessibility 権限が
        // 失効しがち。emit 前に確認して、無ければトーストだけ出す。
        // (ダイアログ反復防止のため prompt: true は呼ばない。設定ボタンから手動で。)
        // v0.9.6-beta (P0 #10): also broadcast `.pastyPasteFailed` so a future
        // toast UI can offer to open System Settings → Privacy → Accessibility.
        if !AXIsProcessTrusted() {
            NotificationCenter.default.post(
                name: .pastyPasteFailed,
                object: nil,
                userInfo: ["reason": "accessibility"]
            )
            pasteAutomatorLogger.error("emitCommandV: AXIsProcessTrusted false; aborting ⌘V")
            Task { @MainActor in
                PasteToast.shared.show(
                    targetApp: nil,
                    customMessage: "アクセシビリティ権限が無効です。設定で再付与してください",
                    durationSeconds: 4
                )
            }
            // v0.9.6-beta (P1 #9): also pop a modal NSAlert (cooldown 5 min) so
            // a returning user immediately understands why ⌘V silently failed.
            PasteAutomator.showAccessibilityRevokedAlert()
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src,
                           virtualKey: CGKeyCode(kVK_ANSI_V),
                           keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: src,
                         virtualKey: CGKeyCode(kVK_ANSI_V),
                         keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}

/// バイナリ payload（画像・ファイル・将来的に動画）を内容ハッシュで
/// 保存するシンプルなアドレスドストア。SQLiteを肥大化させず、`dataPath`
/// は相対パスだけを持つ。
enum ClipBlobs {
    static var directory: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = appSupport
            .appendingPathComponent("Pasty", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // v0.9.6-beta (P1 #19): tighten perms to 0o700 unconditionally so
        // existing installs migrate from looser modes on first access.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir.path
        )
        return dir
    }

    static func blobURL(for relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    /// 画像データを `images/<hash>.<ext>` に保存して相対パスを返す。
    /// 既に同じハッシュのファイルがあれば書かずにパスだけ返す（自然なdedupe）。
    @discardableResult
    static func writeImage(_ data: Data, hash: String, suggestedExt: String = "png") -> String {
        let subdir = "images"
        let dir = directory.appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // v0.9.6-beta (P1 #19): tighten image subdir perms to 0o700 so
        // pasteboard image payloads aren't world-readable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir.path
        )
        let rel = "\(subdir)/\(hash).\(suggestedExt)"
        let url = directory.appendingPathComponent(rel)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        return rel
    }
}
