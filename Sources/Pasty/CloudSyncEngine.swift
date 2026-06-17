import Foundation
import Combine

/// **C1 phase 1: 足場のみ — 実装は phase 2 で入る。**
///
/// 設計の根拠は以下を参照:
/// - `.ai/decisions/c1-icloud-sync-architecture.md`
/// - `.ai/decisions/c1-icloud-sync-security.md`
/// - `.ai/decisions/c1-icloud-sync-schema.md`
/// - `.ai/decisions/c1-icloud-sync-review.md`
///
/// 概要:
/// - ClipStore に追加された `sync_journal` テーブルから未同期エントリを取り出し、
///   CloudKit private DB の `CKRecord` として push する。
/// - 同時に remote の変更を pull し、LWW + Lamport clock でローカルとマージ。
/// - 全 payload は CryptoKit AES-GCM-256 で端末間共有鍵により暗号化（E2E）。
///
/// 現状: 全メソッドが no-op で `// TODO: C1 phase 2` を吐くだけ。
/// UI からは無効化された状態でしか呼ばれないため、リリースしても誤動作はしない。
@MainActor
final class CloudSyncEngine: ObservableObject {
    static let shared = CloudSyncEngine()

    /// 同期エンジンが現在稼働中か。`start()` が呼ばれていれば true。
    @Published private(set) var isRunning: Bool = false

    /// 直近の同期完了時刻。phase 2 で UI に出す予定。
    @Published private(set) var lastSyncedAt: Date?

    /// 同期中にエラーが出た場合、その人間向け説明。phase 2 で UI に出す予定。
    @Published private(set) var lastError: String?

    private init() {
        // TODO: C1 phase 2 — CKContainer の準備、Keychain からの鍵読み込み、
        // device pairing 状態のロード等を行う。
    }

    /// 同期エンジンを起動する。設定で iCloud 同期が ON になっている場合のみ呼ぶ。
    func start() {
        // TODO: C1 phase 2 — CKSyncEngine.start(), background scheduler 起動,
        // PasteboardObserver からの insert hook を購読して journal を書く。
        isRunning = false
    }

    /// 同期エンジンを停止する。設定で OFF にされた / アプリ終了時。
    func stop() {
        // TODO: C1 phase 2 — CKSyncEngine.stop(), Combine cancellable 解放。
        isRunning = false
    }

    /// 明示的な「今すぐ同期」。設定画面のボタンから呼ばれる想定。
    func sync() async {
        // TODO: C1 phase 2 — 未同期 journal を全部 push、remote pull、conflict 解決。
        lastSyncedAt = Date()
    }

    /// 端末ペアリング: QR コードを生成し、もう片方の Mac でスキャンしてもらう。
    func generatePairingPayload() -> String? {
        // TODO: C1 phase 2 — Ed25519 公開鍵 + device_id をエンコード。
        return nil
    }

    /// 端末ペアリングの受け入れ側。スキャン結果を取り込む。
    func acceptPairingPayload(_ payload: String) {
        // TODO: C1 phase 2 — 公開鍵検証 + シンメトリック鍵共有 (ECDH)。
    }
}
