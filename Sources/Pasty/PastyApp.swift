import SwiftUI
import AppKit
import os

private let pastyAppLogger = Logger(subsystem: "io.pasty.app", category: "PastyApp")

@main
struct PastyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store: ClipStore
    @StateObject private var pinboards: PinboardStore
    @StateObject private var stack: PasteStack
    @StateObject private var observer: PasteboardObserver
    @StateObject private var coordinator: PanelCoordinator
    @StateObject private var settings: SettingsStore
    @StateObject private var selection: SelectionModel

    init() {
        let store: ClipStore
        do {
            store = try ClipStore.shared()
        } catch {
            // v0.9.6-beta (P0 #5): instead of fatalError, try once to recover
            // by side-lining the apparently-corrupt DB and rebuilding from
            // scratch. If that also fails, *then* we fatalError because the
            // file system itself is hostile and there's nothing further the
            // app can do.
            pastyAppLogger.error("ClipStore.shared() failed: \(String(describing: error), privacy: .public)")
            store = PastyApp.recoverFromDBOpenFailure(originalError: error)
        }

        // PasteHistory など ClipStore を持たないシングルトンから
        // 貼付イベントを永続化できるよう、共有コンテナにも差し込んでおく。
        ClipStoreContainer.shared.store = store

        let pinboards = PinboardStore(dbWriter: store.dbWriter)
        PinboardStoreContainer.shared.pinboards = pinboards
        let stack = PasteStack()
        let selection = SelectionModel()
        let coordinator = PanelCoordinator(store: store, pinboards: pinboards,
                                           stack: stack, selection: selection)
        let observer = PasteboardObserver(store: store)

        // 直前アプリの追跡を起動。Pastyが召喚されても元のアプリを記憶し続ける。
        _ = PreviousAppTracker.shared

        _store = StateObject(wrappedValue: store)
        _pinboards = StateObject(wrappedValue: pinboards)
        _stack = StateObject(wrappedValue: stack)
        _coordinator = StateObject(wrappedValue: coordinator)
        _observer = StateObject(wrappedValue: observer)
        _settings = StateObject(wrappedValue: .shared)
        _selection = StateObject(wrappedValue: selection)

        // v0.8.4-beta (M-4): 起動シーケンスを 2 段に分割。
        // Stage 1 はホットキー/ノッチ/Strip prewarm/権限など UI クリティカル。
        // Stage 2 は Sparkle / Onboarding / WhatsNew / Stack ピル / DB backfill
        // など最初のフレームに不要なものを 0.5s 遅延で。
        let installable = coordinator
        let store2 = store

        // Stage 1 — 即時 (UI クリティカル)
        DispatchQueue.main.async {
            installable.installHotkeys()
            installable.installNotchHover()
            installable.prewarmStrip()
            _ = PasteAutomator.shared.ensureAccessibilityPermission(prompt: true)

            // Subscribe to settings notifications. Capture the observer tokens
            // so `applicationWillTerminate(_:)` can tear them down on quit and
            // we don't leak the closure references across an app relaunch
            // (sandbox / fast-restart scenarios).
            let wipeToken = NotificationCenter.default.addObserver(
                forName: .pastyWipeAll, object: nil, queue: .main
            ) { _ in
                Task { try? await store2.deleteAll() }
            }
            let openToken = NotificationCenter.default.addObserver(
                forName: .pastyOpenSettings, object: nil, queue: .main
            ) { _ in
                openSettingsWindowRobustly()
            }
            AppDelegate.stage1Observers.append(wipeToken)
            AppDelegate.stage1Observers.append(openToken)
        }

        // Stage 2 — 0.5s 遅延 (非クリティカル / 起動後タスク)
        Task { @MainActor [stack] in
            try? await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
            // Sparkle: SPUStandardUpdaterController(startingUpdater: true) を呼んだ時点で
            // 自動チェッカーが起動するので、shared にアクセスするだけで初期化される。
            _ = SparkleUpdater.shared

            // v0.9.6-beta (P1 #7): Sparkle のフェイル/インストール完了をトーストで表面化する。
            // failed reason: "network" | "edsa" | "sandbox" | "other"
            let sparkleFailedToken = NotificationCenter.default.addObserver(
                forName: .pastySparkleUpdateFailed,
                object: nil, queue: .main
            ) { note in
                let reason = (note.userInfo?["reason"] as? String) ?? "other"
                let message: String
                switch reason {
                case "network": message = "アップデートのダウンロードに失敗しました（ネットワークエラー）"
                case "edsa":    message = "アップデートの署名検証に失敗しました"
                case "sandbox": message = "アップデートのインストール権限がありません"
                default:        message = "アップデートに失敗しました"
                }
                Task { @MainActor in
                    PasteToast.shared.show(targetApp: nil,
                                           customMessage: message,
                                           durationSeconds: 2.4)
                }
            }
            let sparkleInstalledToken = NotificationCenter.default.addObserver(
                forName: .pastySparkleUpdateInstalled,
                object: nil, queue: .main
            ) { note in
                let version = (note.userInfo?["version"] as? String) ?? ""
                let message = "Pasty を更新しました（バージョン \(version)）"
                Task { @MainActor in
                    PasteToast.shared.show(targetApp: nil,
                                           customMessage: message,
                                           durationSeconds: 2.4)
                }
            }
            AppDelegate.stage1Observers.append(sparkleFailedToken)
            AppDelegate.stage1Observers.append(sparkleInstalledToken)

            // 初回起動時のオンボーディング
            OnboardingPresenter.shared.presentIfNeeded {
                SettingsStore.shared.hasCompletedOnboarding = true
                // A8: オンボーディング完了後の起動回でリリースノートを表示
                WhatsNewPresenter.shared.presentIfNeeded()
            }
            // オンボーディングを既に終えているユーザー向け: 起動直後に評価
            if SettingsStore.shared.hasCompletedOnboarding {
                let prevSeen = UserDefaults.standard.string(forKey: "pasty.whatsNewLastShownVersion")
                let current = WhatsNewPresenter.shared.currentVersionString
                WhatsNewPresenter.shared.presentIfNeeded()
                // アップデート直後にだけ、`##` 見出しから組み立てたミニオンボーディングをキューイング
                if prevSeen != current {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(0.4 * 1_000_000_000))
                        OnboardingPresenter.shared.presentMiniWhatsNew(version: current)
                    }
                }
            }

            // フローティング Stack ピル（Stack に積まれている時だけ表示）
            if SettingsStore.shared.stackPillEnabled {
                StackPillController.shared.install(stack: stack, coordinator: installable)
            }

            // 起動後にバックグラウンドで entity_uuid backfill を進める (M-2)
            Task { await store2.backfillEntityUUIDsIfNeeded() }

            // v0.9.6-beta (P0 #3): kick off BlobGC sweep on startup. Sweeps
            // orphan blobs (deleted soft-deleted rows that aged past the
            // 30-day grace window) and hard-deletes the corresponding rows.
            // Hand-off to BlobGC is MainActor-bound; the heavy disk walk is
            // off-actor inside BlobGC.sweep itself.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                do {
                    let result = try await BlobGC.sweep(store: store2)
                    pastyAppLogger.info("BlobGC sweep: deleted=\(result.deleted, privacy: .public) kept=\(result.kept, privacy: .public)")
                } catch {
                    pastyAppLogger.error("BlobGC sweep failed: \(String(describing: error), privacy: .public)")
                }

                // v0.10.0-beta (Axis 5): hard-delete tombstoned rows aged past
                // the 90-day grace window. Runs after BlobGC so any blobs that
                // belonged to those rows have already been reclaimed.
                do {
                    let result = try await RetentionSweeper.sweep(store: store2)
                    pastyAppLogger.info("RetentionSweeper hardDeleted=\(result.hardDeleted, privacy: .public) kept=\(result.keptRows, privacy: .public)")
                } catch {
                    pastyAppLogger.error("RetentionSweeper failed: \(String(describing: error), privacy: .public)")
                }

                // v0.10.0-beta: Disk thumbnail LRU sweep. Defers ~5 s after
                // launch so the cold-start path is untouched, then evicts
                // expired (>90 d) and oversize entries from both buckets
                // using file mtime as the LRU signal. Runs off-MainActor
                // inside `DiskThumbnailStore` (actor) — the outer Task
                // here just kicks it off and returns.
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await VideoThumbnailCache.diskStore.evictExpiredAndOversize()
                    await PDFThumbnailCache.diskStore.evictExpiredAndOversize()
                }

                // v0.9.8-beta Wave 1A: startup auto-trim. After BlobGC has had
                // a chance to reclaim orphan blobs, enforce the clip-count
                // ceiling. Pinned clips are protected by trimToMaxClips itself
                // (NOT IN pinboard_items). Silent on the zero case, logged when
                // we actually shed clips.
                let settings = SettingsStore.shared
                if settings.autoTrimEnabled {
                    do {
                        let trimmed = try store2.trimToMaxClips(settings.autoTrimMaxClips)
                        if trimmed > 0 {
                            print("[AutoTrim] startup: trimmed \(trimmed) clips")
                        }
                    } catch {
                        print("[AutoTrim] startup error: \(error)")
                    }
                }
            }
        }
    }

    /// v0.9.6-beta (P0 #5): Side-line a corrupt `pasty.sqlite` and rebuild
    /// from an empty DB. We rename the old file to
    /// `clips.db.corrupt-<unixTimestamp>` so the user (or support) can
    /// recover data offline, then attempt `ClipStore.shared()` once more.
    /// An `NSAlert` lets the user know their history is preserved on disk.
    ///
    /// If the second open also fails, we fatalError as a last resort —
    /// that path means the user-facing recovery attempt was already made.
    private static func recoverFromDBOpenFailure(originalError: Error) -> ClipStore {
        let timestamp = Int(Date().timeIntervalSince1970)
        let fm = FileManager.default
        var backupName: String? = nil

        do {
            let appSupport = try fm
                .url(for: .applicationSupportDirectory, in: .userDomainMask,
                     appropriateFor: nil, create: true)
                .appendingPathComponent("Pasty", isDirectory: true)
            let dbURL = appSupport.appendingPathComponent("pasty.sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                let backup = "clips.db.corrupt-\(timestamp)"
                let backupURL = appSupport.appendingPathComponent(backup)
                try fm.moveItem(at: dbURL, to: backupURL)
                backupName = backup
                pastyAppLogger.error("Renamed corrupt DB to \(backup, privacy: .public)")

                // SQLite sidecar files (-wal, -shm) would tie the rebuilt DB
                // back to the corrupt state, so move them out of the way too.
                for sidecarSuffix in ["-wal", "-shm"] {
                    let sidecar = appSupport
                        .appendingPathComponent("pasty.sqlite\(sidecarSuffix)")
                    if fm.fileExists(atPath: sidecar.path) {
                        let sidecarBackup = appSupport
                            .appendingPathComponent("\(backup)\(sidecarSuffix)")
                        try? fm.moveItem(at: sidecar, to: sidecarBackup)
                    }
                }
            }

            let store = try ClipStore.shared()

            // Surface the recovery to the user. We're inside `init`, so
            // dispatch the alert async to next main-loop tick.
            let backupLabel = backupName ?? "clips.db.corrupt-\(timestamp)"
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Pasty"
                alert.informativeText = "DB を再構築しました。バックアップは \(backupLabel) に保存されています。"
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                _ = alert.runModal()
            }
            return store
        } catch {
            pastyAppLogger.fault("DB recovery failed: \(String(describing: error), privacy: .public). Original: \(String(describing: originalError), privacy: .public)")
            fatalError("Failed to open ClipStore (original: \(originalError), recovery: \(error))")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                store: store,
                pinboards: pinboards,
                observer: observer,
                coordinator: coordinator,
                settings: settings,
                selection: selection
            )
        } label: {
            MenuBarLabel(isPaused: settings.isPaused)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, pinboards: pinboards, store: store)
        }
    }
}

private struct MenuBarLabel: View {
    let isPaused: Bool
    var body: some View {
        Image(systemName: isPaused ? "doc.on.clipboard.fill" : "doc.on.clipboard")
            .symbolRenderingMode(isPaused ? .multicolor : .monochrome)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Stage-1 NotificationCenter observer tokens captured during
    /// `PastyApp.init`'s immediate `DispatchQueue.main.async` block. We tear
    /// them down in `applicationWillTerminate(_:)` to avoid the observers
    /// outliving their owning state — see `PastyApp.init` for the call site.
    static var stage1Observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for token in AppDelegate.stage1Observers {
            NotificationCenter.default.removeObserver(token)
        }
        AppDelegate.stage1Observers.removeAll()
    }
}

/// 設定画面は SwiftUI の `Settings { }` シーンが accessory アプリだと
/// 信頼性低く開かない/閉じても残骸が残るので、自前で NSWindow を管理する。
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?
    private var policyObserver: NSObjectProtocol?

    private init() {}

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // SettingsView を NSHostingController でラップ
        let view = SettingsView(
            settings: .shared,
            pinboards: PinboardStoreContainer.shared.pinboards
                ?? PinboardStore(dbWriter: ClipStoreContainer.shared.store!.dbWriter),
            store: ClipStoreContainer.shared.store
        )
        let host = NSHostingController(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Pasty 設定"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.contentViewController = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)

        // 閉じたら accessory に戻す
        policyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w, queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }

        self.window = w
    }
}

/// 互換ヘルパ。既存呼び出し箇所はこの関数を通る。
@MainActor
func openSettingsWindowRobustly() {
    SettingsWindowManager.shared.show()
}

/// PinboardStore を SettingsWindowManager から取得できるようにするコンテナ。
@MainActor
final class PinboardStoreContainer {
    static let shared = PinboardStoreContainer()
    var pinboards: PinboardStore?
}
