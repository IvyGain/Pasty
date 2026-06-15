import AppKit
import Foundation

/// 軽量な GitHub Releases ベースのアップデート確認。
///
/// 起動時と 6 時間ごとに `releases/latest` を叩いて、`CFBundleShortVersionString`
/// より新しいタグが出ているか判定する。新しければ
/// `Notification.Name.pastyUpdateAvailable` を post し、メニューバー / 設定が
/// それを購読してバッジ / ボタン表示する。
///
/// 完全自動の差分インストールは行わない (ad-hoc 署名 dmg の置換は手作業が
/// 正しい)。代わりに「アップデートを開く」ボタンで dmg の URL をブラウザに
/// 渡す。Sparkle へのフル移行は v1.0 で別途検討する。
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let prerelease: Bool
        let assets: [Asset]
        let body: String?

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    /// 直近の確認時刻 (UserDefaults)。
    private let lastCheckKey = "pasty.update.lastCheck"
    /// 最後に見つけたバージョン (UserDefaults)。
    private let latestVersionKey = "pasty.update.latestVersion"
    /// 最後の dmg URL。
    private let latestDmgURLKey = "pasty.update.latestDmgURL"

    /// 最後に取得した情報。UI 側がバッジ表示に使う。
    private(set) var available: AvailableUpdate?

    struct AvailableUpdate {
        let version: String
        let dmgURL: URL
        let releasePageURL: URL
        let isPrerelease: Bool
    }

    /// 起動時に 1 回 + 6h おきにチェックを仕掛ける。
    func start() {
        // 起動 5 秒後に 1 回
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check()
        }
        // 以降 6 時間ごと
        Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// 手動チェック (設定 / メニューバーから呼ぶ)。
    @discardableResult
    func check(force: Bool = false) -> Task<Void, Never> {
        return Task { @MainActor in
            await self.performCheck(force: force)
        }
    }

    private func performCheck(force: Bool) async {
        let url = URL(string: "https://api.github.com/repos/IvyGain/Pasty/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(Release.self, from: data)
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)

            let latestVersion = sanitize(release.tag_name)
            let currentVersion = currentAppVersion()

            // 比較。latest <= current なら何もしない。
            if compareVersion(latestVersion, currentVersion) <= 0 {
                self.available = nil
                NotificationCenter.default.post(name: .pastyUpdateAvailable, object: nil)
                return
            }

            // dmg URL を探す。`Pasty.dmg` (固定名) を優先、なければ `Pasty-x.y.z*.dmg`。
            let dmgAsset = release.assets.first(where: { $0.name == "Pasty.dmg" })
                ?? release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
            guard let dmgAsset, let dmgURL = URL(string: dmgAsset.browser_download_url) else {
                return
            }
            guard let releasePageURL = URL(string: release.html_url) else { return }

            let info = AvailableUpdate(
                version: latestVersion,
                dmgURL: dmgURL,
                releasePageURL: releasePageURL,
                isPrerelease: release.prerelease
            )
            self.available = info
            UserDefaults.standard.set(latestVersion, forKey: latestVersionKey)
            UserDefaults.standard.set(dmgURL.absoluteString, forKey: latestDmgURLKey)
            NotificationCenter.default.post(name: .pastyUpdateAvailable, object: info)
        } catch {
            // ネットワークエラーは黙って無視。次の interval で再試行される。
        }
    }

    /// 「アップデートをダウンロード」アクション — dmg URL をブラウザで開く。
    func openDownload() {
        guard let url = available?.dmgURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// 「リリースノートを開く」アクション。
    func openReleasePage() {
        guard let url = available?.releasePageURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - helpers

    private func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// `v0.5.0-beta` → `0.5.0-beta` のように `v` プレフィックスを剥がす。
    private func sanitize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// セマンティックバージョン比較 (簡易、`-beta` などの suffix は文字列比較で fallback)。
    /// 戻り値: a < b なら負、a == b なら 0、a > b なら正。
    private func compareVersion(_ a: String, _ b: String) -> Int {
        let (aCore, aSuffix) = splitVersion(a)
        let (bCore, bSuffix) = splitVersion(b)
        // numeric core 比較
        for i in 0..<max(aCore.count, bCore.count) {
            let av = i < aCore.count ? aCore[i] : 0
            let bv = i < bCore.count ? bCore[i] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        // core が同じなら suffix を文字列比較
        // ただし「suffix なし」は「-beta などあり」より新しい (stable > beta)
        switch (aSuffix.isEmpty, bSuffix.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): return aSuffix.compare(bSuffix).rawValue
        }
    }

    private func splitVersion(_ s: String) -> (core: [Int], suffix: String) {
        if let dash = s.firstIndex(of: "-") {
            let core = String(s[..<dash])
            let suffix = String(s[s.index(after: dash)...])
            return (core.split(separator: ".").compactMap { Int($0) }, suffix)
        } else {
            return (s.split(separator: ".").compactMap { Int($0) }, "")
        }
    }
}

extension Notification.Name {
    /// `UpdateChecker.shared.available` が更新された (有り/無し 両方)。
    static let pastyUpdateAvailable = Notification.Name("pasty.update.available")
}
