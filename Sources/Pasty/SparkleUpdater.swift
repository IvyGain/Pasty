import AppKit
import Sparkle
import SwiftUI

/// Sparkle 2.x ベースの自動アップデート。
///
/// 起動時に `SPUStandardUpdaterController(startingUpdater: true, ...)` を作る
/// だけで、Info.plist の `SUFeedURL` (appcast.xml の URL) を 24 時間おきに
/// チェックし、新版が見つかればユーザーに確認ダイアログを出す。
///
/// EdDSA 署名検証は Sparkle 内部で行われるため、`SUPublicEDKey` (Info.plist)
/// に対応した `sparkle:edSignature` 属性が appcast.xml に含まれている dmg
/// だけがインストールされる。
///
/// 既存ユーザーへの伝達:
/// - v0.5.0-beta 以前は別の `UpdateChecker` が動いていたので、それが Sparkle
///   入り版 (v0.6.0+) を一度通知する。それ以降は Sparkle が自動で次の世代に
///   引き継ぐ。
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    let controller: SPUStandardUpdaterController

    private init() {
        // `startingUpdater: true` で内部のスケジューラが起動。Info.plist の
        // `SUEnableAutomaticChecks` が true なら自動でチェックが走る。
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 手動で「アップデートを確認」を発火するエントリ。
    /// 設定 → Pastyについて の "アップデートを確認" ボタンと、メニューバーの
    /// 同名アクションから呼ばれる。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Sparkle の SPUUpdater インスタンス。必要なら SwiftUI 側で
    /// `@ObservedObject` 越しに状態をのぞく。
    var updater: SPUUpdater { controller.updater }
}
