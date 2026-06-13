import Foundation

/// グローバルな弱参照ハブ。`PasteHistory` のように `ClipStore` を持たない
/// シングルトンから、貼付イベントを永続化したいときの呼び出し口。
///
/// `PastyApp.init` で `shared.store = store` をセットしている前提。
/// テスト時や Pasty 本体未起動時は `nil` のままで、利用側は `Task { try? ... }`
/// などでベストエフォート呼び出しすること。
@MainActor
final class ClipStoreContainer {
    static let shared = ClipStoreContainer()
    var store: ClipStore?

    private init() {}
}
