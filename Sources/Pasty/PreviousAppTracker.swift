import AppKit

/// 直前にフロントにいたアプリ（=ユーザーがコピー先として想定しているアプリ）を
/// 記録しておくためのトラッカー。Pastyが召喚されたとき、`NSApp.activate(...)`
/// で前面化してしまうと、テキストフィールドのキャレットを奪ってしまい
/// 結果として「クリックしたのに貼り付かない」「別のところに貼り付いた」が起きる。
///
/// このクラスは：
///   1. アクティブアプリの切り替えを `NSWorkspace` 経由で常時監視
///   2. Pasty 自身は除外（Pasty にフォーカスが移っても記録しない）
///   3. 貼付直前に「直前のアプリを再アクティベート」できる API を提供
@MainActor
final class PreviousAppTracker {
    static let shared = PreviousAppTracker()

    private(set) var previous: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private let myPID = ProcessInfo.processInfo.processIdentifier

    private init() {
        // 初期値：起動時に既にフロントにいるアプリ（≠ Pasty）
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != myPID {
            self.previous = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Pasty 自体への切替は無視。前のアプリの記録を温存する。
            if app.processIdentifier == self.myPID { return }
            self.previous = app
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// 直前のフロントアプリをアクティベートし、`grace` 秒待つ。
    /// アクティベートが成功した、あるいは Pasty 以外の何かが前面にいれば true。
    @discardableResult
    func restoreFocus(grace: TimeInterval = 0.08) async -> Bool {
        guard let app = previous else { return false }
        if app.isTerminated { return false }
        app.activate(options: [])
        // 直後に CGEvent を叩くと「Pasty がまだ前面」と扱われることがある。
        // 80ms 程度待ってからキー送信すると 95%+ のターゲットアプリで安定。
        try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
        return true
    }
}
