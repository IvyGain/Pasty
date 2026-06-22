import AppKit
import Sparkle
import SwiftUI
import UserNotifications
import os

private let sparkleLogger = Logger(subsystem: "io.pasty.app", category: "SparkleUpdater")

/// v0.9.6-beta (P1 #6/#7): Sparkle のダウンロード/インストール失敗・成功を
/// アプリ内のトーストに繋ぐためのブロードキャストチャネル。
///
/// `pastySparkleUpdateFailed` userInfo:
///   - "reason": String — "network" | "edsa" | "sandbox" | "other"
///
/// `pastySparkleUpdateInstalled` userInfo:
///   - "version": String — display version of the installed update
extension Notification.Name {
    static let pastySparkleUpdateFailed   = Notification.Name("pasty.sparkle.updateFailed")
    static let pastySparkleUpdateInstalled = Notification.Name("pasty.sparkle.updateInstalled")
}

/// Sparkle 2.x ベースの自動アップデート。
///
/// 起動時に `SPUStandardUpdaterController(startingUpdater: true, ...)` を作る
/// だけで、Info.plist の `SUFeedURL` (appcast.xml の URL) を `SUScheduledCheckInterval`
/// 秒おきにチェックし、新版が見つかればユーザーに確認ダイアログを出す。
///
/// 加えて、`startingUpdater: true` ではスケジューラだけが立つので、ユーザーが
/// 「気付けない」状態を避けるため:
///   1. 初回バックグラウンドチェックを「初ペースト or 30 秒経過」のどちらか早い方で発火 (P1 #8)
///   2. 新版検出時に macOS の `UserNotifications` で通知センターにも push
@MainActor
final class SparkleUpdater: NSObject, ObservableObject {
    static let shared = SparkleUpdater()

    let controller: SPUStandardUpdaterController

    /// v0.9.6-beta (P1 #8): 初回バックグラウンドチェックを 1 度だけ走らせるためのフラグ。
    /// 初ペースト完了 or 30 秒タイマー のどちらかが先に立ち上がった瞬間に true になり、
    /// もう片方は no-op になる。
    private var hasKickedOffFirstCheck = false
    private var firstPasteObserver: NSObjectProtocol?

    override init() {
        // 一旦 super.init してから controller を作る (delegate に self を渡せる順序にする)。
        // Sparkle の updaterDelegate は @objc プロトコルなので NSObject 派生にする必要がある。
        let placeholderDelegate = UpdaterDelegate()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: placeholderDelegate,
            userDriverDelegate: nil
        )
        super.init()
        placeholderDelegate.owner = self

        // 起動直後の通知センター許可リクエスト (silent)。許可されていなくても
        // Sparkle 自体のダイアログは出るので最低限の通知経路は確保される。
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // v0.9.6-beta (P1 #8): 起動直後の即時チェックは「ユーザーの操作を邪魔する」と
        // クレームが上がっていたため廃止。代わりに以下のいずれかで 1 度だけ発火する:
        //   (a) 初回ペースト完了 (`pastyFirstPasteCompleted`)
        //   (b) 起動から 30 秒
        // どちらかが先に発火した時点で `hasKickedOffFirstCheck` を立て、もう一方は no-op。
        firstPasteObserver = NotificationCenter.default.addObserver(
            forName: .pastyFirstPasteCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.kickOffFirstBackgroundCheckIfNeeded(trigger: "firstPaste")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.kickOffFirstBackgroundCheckIfNeeded(trigger: "timer30s")
        }
    }

    /// 初回バックグラウンドチェックを 1 度だけ撃つ。先勝ち。
    private func kickOffFirstBackgroundCheckIfNeeded(trigger: String) {
        guard !hasKickedOffFirstCheck else { return }
        hasKickedOffFirstCheck = true
        sparkleLogger.info("Sparkle: first background check fired via \(trigger, privacy: .public)")
        if let observer = firstPasteObserver {
            NotificationCenter.default.removeObserver(observer)
            firstPasteObserver = nil
        }
        controller.updater.checkForUpdatesInBackground()
    }

    /// 手動で「アップデートを確認」を発火するエントリ。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle の SPUUpdater インスタンス。
    var updater: SPUUpdater { controller.updater }

    /// 新版が見つかった時に通知センターへ通知を投げる。
    func postFoundUpdateNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pasty アップデート: v\(version)"
        content.body = "新しいバージョンが利用可能です。タップして詳細を確認してください。"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "pasty.update.\(version)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// v0.9.6-beta (P1 #6): エラーを `reason` 文字列に分類する。
    /// - NSURLErrorDomain / -100x 系: "network"
    /// - EdDSA / signature 検証系: "edsa"
    /// - sandbox / file-write / NSFileWriteNoPermissionError: "sandbox"
    /// - それ以外: "other"
    static func classify(_ error: NSError) -> String {
        let domain = error.domain
        let code = error.code
        let desc = (error.localizedDescription as NSString).lowercased

        if domain == NSURLErrorDomain { return "network" }
        if desc.contains("network") || desc.contains("offline")
            || desc.contains("connection") || desc.contains("timed out")
            || desc.contains("could not connect") {
            return "network"
        }

        if desc.contains("edsa") || desc.contains("ed25519")
            || desc.contains("signature") || desc.contains("dsa") {
            return "edsa"
        }

        if domain == NSCocoaErrorDomain &&
            (code == NSFileWriteNoPermissionError
             || code == NSFileWriteVolumeReadOnlyError) {
            return "sandbox"
        }
        if desc.contains("sandbox") || desc.contains("permission")
            || desc.contains("not permitted") || desc.contains("read-only") {
            return "sandbox"
        }

        return "other"
    }

    /// P1 #7 で UI 側 (PastyApp) から購読される。フェイル系をブロードキャスト。
    func broadcastFailed(reason: String) {
        NotificationCenter.default.post(
            name: .pastySparkleUpdateFailed,
            object: nil,
            userInfo: ["reason": reason]
        )
    }

    /// インストール成功時に発火。version は表示用文字列。
    func broadcastInstalled(version: String) {
        NotificationCenter.default.post(
            name: .pastySparkleUpdateInstalled,
            object: nil,
            userInfo: ["version": version]
        )
    }
}

/// SPUUpdaterDelegate を実装する別オブジェクト。`@objc` プロトコル準拠が必要なので
/// NSObject 派生で持つ。delegate コールバックで `SparkleUpdater.shared` に通知を
/// 中継する。
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var owner: SparkleUpdater?

    /// Sparkle が valid な更新候補を見つけた時に呼ばれる。
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString ?? item.versionString
        Task { @MainActor [weak self] in
            self?.owner?.postFoundUpdateNotification(version: version)
        }
    }

    // MARK: - v0.9.6-beta (P1 #6): failure delegate callbacks

    /// ダウンロード失敗 → 概ねネットワーク系。
    func updater(_ updater: SPUUpdater,
                 failedToDownloadUpdate item: SUAppcastItem,
                 error: Error) {
        sparkleLogger.error("Sparkle failedToDownloadUpdate: \(String(describing: error), privacy: .public)")
        Task { @MainActor [weak self] in
            self?.owner?.broadcastFailed(reason: "network")
        }
    }

    /// アップデートサイクル全体のエラー (検証/インストール準備など)。
    /// 成功時は error=nil で呼ばれるため、その場合は無視する。
    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        guard let error = error else { return }
        let reason = SparkleUpdater.classify(error as NSError)
        sparkleLogger.error("Sparkle didFinishUpdateCycle error reason=\(reason, privacy: .public): \(String(describing: error), privacy: .public)")
        Task { @MainActor [weak self] in
            self?.owner?.broadcastFailed(reason: reason)
        }
    }

    /// アップデートが abort された (権限・署名・想定外)。
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let reason = SparkleUpdater.classify(error as NSError)
        sparkleLogger.error("Sparkle didAbortWithError reason=\(reason, privacy: .public): \(String(describing: error), privacy: .public)")
        Task { @MainActor [weak self] in
            self?.owner?.broadcastFailed(reason: reason)
        }
    }

    /// インストール成功 (Sparkle が relauncher へ移行する直前のフック)。
    /// Sparkle 2.x には `updaterDidFinishInstallingUpdate(_:)` が無く、
    /// `willInstallUpdate:` がインストール成功直前に呼ばれるためここで通知する。
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString ?? item.versionString
        Task { @MainActor [weak self] in
            self?.owner?.broadcastInstalled(version: version)
        }
    }
}
