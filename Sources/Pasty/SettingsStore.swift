import Foundation
import SwiftUI
import Combine

/// Lightweight, user-defaults-backed preferences. Anything heavier (rule
/// engines, per-app blacklists with patterns) lives in SQLite.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var primarySurface: PrimarySurface {
        didSet { defaults.set(primarySurface.rawValue, forKey: Keys.primarySurface) }
    }
    @Published var capturingEnabled: Bool {
        didSet { defaults.set(capturingEnabled, forKey: Keys.capturingEnabled) }
    }
    @Published var pauseUntil: Date? {
        didSet { defaults.set(pauseUntil, forKey: Keys.pauseUntil) }
    }
    @Published var ignoredBundleIds: Set<String> {
        didSet { defaults.set(Array(ignoredBundleIds), forKey: Keys.ignoredBundleIds) }
    }
    @Published var maxRetentionDays: Int {
        didSet { defaults.set(maxRetentionDays, forKey: Keys.maxRetentionDays) }
    }
    @Published var notchHoverEnabled: Bool {
        didSet { defaults.set(notchHoverEnabled, forKey: Keys.notchHoverEnabled) }
    }
    /// v0.8: マウスホイール (or トラックパッド縦) をストリップ/ノッチの横スクロールに変換する。
    @Published var notchScrollWheelEnabled: Bool {
        didSet { defaults.set(notchScrollWheelEnabled, forKey: Keys.notchScrollWheelEnabled) }
    }
    /// v0.8.5: ノッチホバー検出から表示開始までの dwell 時間 (ms)。
    /// 0=即時 (デフォルト) / 50 / 100 / 200。0 にすると hover 検出と同タイミックで
    /// `show()` が走り、知覚遅延が「実質ゼロ」になる。誤発火が気になる人だけ
    /// 値を上げる前提。
    @Published var notchDwellMs: Int {
        didSet { defaults.set(notchDwellMs, forKey: Keys.notchDwellMs) }
    }
    /// v0.8.5: ノッチパネルが降りてくるときのアニメーション時間 (ms)。
    /// 0=アニメ無し (瞬間表示) / 60 / 120。0 を選ぶと NSAnimationContext を
    /// 経由せず `setFrame` 直叩きで一発配置する。
    @Published var notchAnimMs: Int {
        didSet { defaults.set(notchAnimMs, forKey: Keys.notchAnimMs) }
    }
    @Published var stripPanelEnabled: Bool {
        didSet { defaults.set(stripPanelEnabled, forKey: Keys.stripPanelEnabled) }
    }
    @Published var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Keys.autoPaste) }
    }
    @Published var locale: String {
        didSet { defaults.set(locale, forKey: Keys.locale) }
    }
    @Published var toastEnabled: Bool {
        didSet { defaults.set(toastEnabled, forKey: Keys.toastEnabled) }
    }
    @Published var explorerMode: Bool {
        didSet { defaults.set(explorerMode, forKey: Keys.explorerMode) }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }
    @Published var stackPillEnabled: Bool {
        didSet { defaults.set(stackPillEnabled, forKey: Keys.stackPillEnabled) }
    }
    @Published var hoverPreviewEnabled: Bool {
        didSet { defaults.set(hoverPreviewEnabled, forKey: Keys.hoverPreviewEnabled) }
    }
    /// 貼付直前に、Pasty が召喚された瞬間のマウス位置へ合成クリックを送る。
    /// ON にすると「⇧⌘V を押した時にカーソルがあった場所にキャレットが
    /// 移り、そこに貼り付く」体験になる。OFF だと従来通り、フォーカス中の
    /// テキストキャレット位置に貼り付く。
    @Published var clickBeforePaste: Bool {
        didSet { defaults.set(clickBeforePaste, forKey: Keys.clickBeforePaste) }
    }
    @Published var previewFontSize: PreviewFontSize {
        didSet { defaults.set(previewFontSize.rawValue, forKey: Keys.previewFontSize) }
    }

    /// 全 AI アクションの system prompt 前段に注入される文体ルール。
    /// 例: "常に丁寧語で。文章は簡潔に。" など。空ならハードコード prompt のみ。
    @Published var aiStyleGuide: String {
        didSet { defaults.set(aiStyleGuide, forKey: Keys.aiStyleGuide) }
    }
    /// `.emailify` 専用テンプレ。署名・敬語スタイル・件名規約など。
    /// `{{body}}` プレースホルダがあれば、そこに整形後の本文が差し込まれる。
    @Published var aiEmailTemplate: String {
        didSet { defaults.set(aiEmailTemplate, forKey: Keys.aiEmailTemplate) }
    }
    /// AI アクション完了時にシステムサウンドを鳴らす。
    @Published var aiSoundEnabled: Bool {
        didSet { defaults.set(aiSoundEnabled, forKey: Keys.aiSoundEnabled) }
    }
    /// 成功時に鳴らすサウンド名 (macOS 標準音: Glass / Tink / Pop / Ping /
    /// Sosumi / Submarine)。
    @Published var aiSoundName: String {
        didSet { defaults.set(aiSoundName, forKey: Keys.aiSoundName) }
    }
    /// 画面端のグロー (実行中=青パルス / 成功=緑 / 失敗=赤) を表示する。
    @Published var aiGlowEnabled: Bool {
        didSet { defaults.set(aiGlowEnabled, forKey: Keys.aiGlowEnabled) }
    }

    // A1: ストリップの検索 / フィルタ状態の永続化
    @Published var stripRememberFilters: Bool {
        didSet { defaults.set(stripRememberFilters, forKey: Keys.stripRememberFilters) }
    }
    @Published var lastStripQuery: String {
        didSet { defaults.set(lastStripQuery, forKey: Keys.lastStripQuery) }
    }
    @Published var lastStripFilterKindRaw: String {
        didSet { defaults.set(lastStripFilterKindRaw, forKey: Keys.lastStripFilterKindRaw) }
    }

    // B2: AI マクロのリスト。永続化は didSet で UserDefaults に JSON 保存。
    @Published var aiMacros: [AIMacro] {
        didSet { persistAIMacros() }
    }

    /// v0.8 (C1 phase 1): iCloud 同期。phase 2 で実装される予定の足場。
    /// デフォルト OFF。設定画面で「実験的・未実装」とラベル付けして公開。
    @Published var cloudSyncEnabled: Bool {
        didSet { defaults.set(cloudSyncEnabled, forKey: Keys.cloudSyncEnabled) }
    }

    private enum Keys {
        static let primarySurface         = "pasty.primarySurface"
        static let capturingEnabled       = "pasty.capturing"
        static let pauseUntil             = "pasty.pauseUntil"
        static let ignoredBundleIds       = "pasty.ignoredBundleIds"
        static let maxRetentionDays       = "pasty.maxRetentionDays"
        static let notchHoverEnabled      = "pasty.notchHoverEnabled"
        static let notchScrollWheelEnabled = "pasty.notchScrollWheelEnabled"
        static let notchDwellMs           = "pasty.notchDwellMs"
        static let notchAnimMs            = "pasty.notchAnimMs"
        static let stripPanelEnabled      = "pasty.stripPanelEnabled"
        static let autoPaste              = "pasty.autoPaste"
        static let locale                 = "pasty.locale"
        static let toastEnabled           = "pasty.toastEnabled"
        static let explorerMode           = "pasty.explorerMode"
        static let hasCompletedOnboarding = "pasty.hasCompletedOnboarding"
        static let stackPillEnabled       = "pasty.stackPillEnabled"
        static let hoverPreviewEnabled    = "pasty.hoverPreviewEnabled"
        static let previewFontSize        = "pasty.previewFontSize"
        static let clickBeforePaste       = "pasty.clickBeforePaste"
        static let aiStyleGuide           = "pasty.aiStyleGuide"
        static let aiEmailTemplate        = "pasty.aiEmailTemplate"
        static let aiSoundEnabled         = "pasty.aiSoundEnabled"
        static let aiSoundName            = "pasty.aiSoundName"
        static let aiGlowEnabled          = "pasty.aiGlowEnabled"
        static let stripRememberFilters   = "pasty.stripRememberFilters"
        static let lastStripQuery         = "pasty.lastStripQuery"
        static let lastStripFilterKindRaw = "pasty.lastStripFilterKindRaw"
        static let aiMacros               = "pasty.aiMacros.v1"
        static let cloudSyncEnabled       = "pasty.cloudSyncEnabled"
    }

    private init() {
        defaults.register(defaults: [
            Keys.primarySurface: PrimarySurface.strip.rawValue,
            Keys.capturingEnabled: true,
            Keys.maxRetentionDays: 30,
            Keys.notchHoverEnabled: true,
            Keys.notchScrollWheelEnabled: true,
            Keys.notchDwellMs: 0,
            Keys.notchAnimMs: 0,
            Keys.stripPanelEnabled: true,
            Keys.autoPaste: true,
            Keys.locale: "ja",
            Keys.ignoredBundleIds: [
                "com.apple.keychainaccess",
                "com.agilebits.onepassword7",
                "com.1password.1password",
                "com.bitwarden.desktop"
            ],
            Keys.toastEnabled: true,
            Keys.explorerMode: false,
            Keys.hasCompletedOnboarding: false,
            Keys.stackPillEnabled: true,
            Keys.hoverPreviewEnabled: true,
            Keys.previewFontSize: PreviewFontSize.medium.rawValue,
            Keys.clickBeforePaste: true,
            Keys.aiStyleGuide: "",
            Keys.aiEmailTemplate: "",
            Keys.aiSoundEnabled: true,
            Keys.aiSoundName: "Glass",
            Keys.aiGlowEnabled: true,
            Keys.stripRememberFilters: true,
            Keys.lastStripQuery: "",
            Keys.lastStripFilterKindRaw: "",
            Keys.cloudSyncEnabled: false,
        ])
        // v0.3 でメインサーフェスを Strip に切り替えたので、明示的な
        // 「これは Strip だよ」マイグレーションフラグを使う。フラグがない
        // ユーザーは旧 Spotlight 既定で来ている可能性があるので、強制的に
        // Strip に揃え直す。以降は自由に切り替え可。
        let migratedKey = "pasty.primarySurfaceMigratedToStrip.v1"
        if !defaults.bool(forKey: migratedKey) {
            defaults.set(PrimarySurface.strip.rawValue, forKey: Keys.primarySurface)
            defaults.set(true, forKey: migratedKey)
        }
        let rawSurface = defaults.string(forKey: Keys.primarySurface) ?? PrimarySurface.strip.rawValue
        self.primarySurface = PrimarySurface(rawValue: rawSurface) ?? .strip
        self.capturingEnabled = defaults.bool(forKey: Keys.capturingEnabled)
        self.pauseUntil = defaults.object(forKey: Keys.pauseUntil) as? Date
        self.ignoredBundleIds = Set(defaults.array(forKey: Keys.ignoredBundleIds) as? [String] ?? [])
        self.maxRetentionDays = defaults.integer(forKey: Keys.maxRetentionDays)
        self.notchHoverEnabled = defaults.bool(forKey: Keys.notchHoverEnabled)
        self.notchScrollWheelEnabled = defaults.bool(forKey: Keys.notchScrollWheelEnabled)
        self.notchDwellMs = defaults.integer(forKey: Keys.notchDwellMs)
        self.notchAnimMs = defaults.integer(forKey: Keys.notchAnimMs)
        self.stripPanelEnabled = defaults.bool(forKey: Keys.stripPanelEnabled)
        self.autoPaste = defaults.bool(forKey: Keys.autoPaste)
        self.locale = defaults.string(forKey: Keys.locale) ?? "ja"
        self.toastEnabled = defaults.bool(forKey: Keys.toastEnabled)
        self.explorerMode = defaults.bool(forKey: Keys.explorerMode)
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.stackPillEnabled = defaults.bool(forKey: Keys.stackPillEnabled)
        self.hoverPreviewEnabled = defaults.bool(forKey: Keys.hoverPreviewEnabled)
        let rawFontSize = defaults.string(forKey: Keys.previewFontSize) ?? PreviewFontSize.medium.rawValue
        self.previewFontSize = PreviewFontSize(rawValue: rawFontSize) ?? .medium
        self.clickBeforePaste = defaults.bool(forKey: Keys.clickBeforePaste)
        self.aiStyleGuide = defaults.string(forKey: Keys.aiStyleGuide) ?? ""
        self.aiEmailTemplate = defaults.string(forKey: Keys.aiEmailTemplate) ?? ""
        self.aiSoundEnabled = defaults.bool(forKey: Keys.aiSoundEnabled)
        self.aiSoundName = defaults.string(forKey: Keys.aiSoundName) ?? "Glass"
        self.aiGlowEnabled = defaults.bool(forKey: Keys.aiGlowEnabled)
        // A1: ストリップ検索/フィルタ復元
        self.stripRememberFilters = defaults.bool(forKey: Keys.stripRememberFilters)
        self.lastStripQuery = defaults.string(forKey: Keys.lastStripQuery) ?? ""
        self.lastStripFilterKindRaw = defaults.string(forKey: Keys.lastStripFilterKindRaw) ?? ""
        self.cloudSyncEnabled = defaults.bool(forKey: Keys.cloudSyncEnabled)
        // B2: AI マクロの初期化。データが無ければデフォルトを seed する。
        if let data = defaults.data(forKey: Keys.aiMacros),
           let decoded = try? JSONDecoder().decode([AIMacro].self, from: data) {
            self.aiMacros = decoded
        } else {
            self.aiMacros = AIMacro.defaultMacros
            // 直接 persist (didSet は init 中は走らない)
            if let data = try? JSONEncoder().encode(AIMacro.defaultMacros) {
                defaults.set(data, forKey: Keys.aiMacros)
            }
        }
    }

    private func persistAIMacros() {
        if let data = try? JSONEncoder().encode(aiMacros) {
            defaults.set(data, forKey: Keys.aiMacros)
        }
    }

    /// 復元する種類フィルタ。stripRememberFilters が OFF か未保存なら nil。
    func restoredStripFilterKind() -> ClipKind? {
        guard stripRememberFilters else { return nil }
        let raw = lastStripFilterKindRaw
        guard !raw.isEmpty else { return nil }
        return ClipKind(rawValue: raw)
    }

    /// 復元する検索クエリ。stripRememberFilters が OFF なら空文字。
    func restoredStripQuery() -> String {
        guard stripRememberFilters else { return "" }
        return lastStripQuery
    }

    /// AIEngine が prompt 組み立て時に参照する、ユーザー設定のスナップショット。
    /// MainActor から非 MainActor へ渡すために値型でコピーする。
    struct AIPromptContext: Sendable {
        let styleGuide: String
        let emailTemplate: String
    }

    var aiPromptContext: AIPromptContext {
        AIPromptContext(
            styleGuide: aiStyleGuide.trimmingCharacters(in: .whitespacesAndNewlines),
            emailTemplate: aiEmailTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    enum PreviewFontSize: String, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }
        var jpLabel: String {
            switch self {
            case .small:  return "小"
            case .medium: return "中"
            case .large:  return "大"
            }
        }
        var pointSize: CGFloat {
            switch self {
            case .small:  return 11
            case .medium: return 13
            case .large:  return 16
            }
        }
    }

    enum PrimarySurface: String, CaseIterable, Identifiable {
        case strip

        var id: String { rawValue }
        var label: String { "Bottom strip (carousel)" }
        var iconName: String { "rectangle.bottomthird.inset.filled" }
        var jpLabel: String { "下部ストリップ（メイン）" }
    }

    var isPaused: Bool {
        if !capturingEnabled { return true }
        if let until = pauseUntil, until > Date() { return true }
        return false
    }

    func pause(forSeconds seconds: TimeInterval) {
        pauseUntil = Date(timeIntervalSinceNow: seconds)
    }

    func resume() {
        pauseUntil = nil
        capturingEnabled = true
    }
}
