import AppKit
import Sparkle
import SwiftUI
import UserNotifications

/// Sparkle 2.x ベースの自動アップデート。
///
/// 起動時に `SPUStandardUpdaterController(startingUpdater: true, ...)` を作る
/// だけで、Info.plist の `SUFeedURL` (appcast.xml の URL) を `SUScheduledCheckInterval`
/// 秒おきにチェックし、新版が見つかればユーザーに確認ダイアログを出す。
///
/// 加えて、`startingUpdater: true` ではスケジューラだけが立つので、ユーザーが
/// 「気付けない」状態を避けるため:
///   1. 起動 8 秒後にバックグラウンドチェックを 1 回明示的に発火
///   2. 新版検出時に macOS の `UserNotifications` で通知センターにも push
@MainActor
final class SparkleUpdater: NSObject, ObservableObject {
    static let shared = SparkleUpdater()

    let controller: SPUStandardUpdaterController

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

        // 起動 8 秒後に必ず 1 度だけバックグラウンドチェックを走らせる。
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.controller.updater.checkForUpdatesInBackground()
        }
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
}
