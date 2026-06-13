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

    private enum Keys {
        static let primarySurface         = "pasty.primarySurface"
        static let capturingEnabled       = "pasty.capturing"
        static let pauseUntil             = "pasty.pauseUntil"
        static let ignoredBundleIds       = "pasty.ignoredBundleIds"
        static let maxRetentionDays       = "pasty.maxRetentionDays"
        static let notchHoverEnabled      = "pasty.notchHoverEnabled"
        static let stripPanelEnabled      = "pasty.stripPanelEnabled"
        static let autoPaste              = "pasty.autoPaste"
        static let locale                 = "pasty.locale"
        static let toastEnabled           = "pasty.toastEnabled"
        static let explorerMode           = "pasty.explorerMode"
        static let hasCompletedOnboarding = "pasty.hasCompletedOnboarding"
        static let stackPillEnabled       = "pasty.stackPillEnabled"
    }

    private init() {
        defaults.register(defaults: [
            Keys.primarySurface: PrimarySurface.strip.rawValue,
            Keys.capturingEnabled: true,
            Keys.maxRetentionDays: 30,
            Keys.notchHoverEnabled: true,
            Keys.stripPanelEnabled: true,
            Keys.autoPaste: true,
            Keys.locale: "auto",
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
        self.stripPanelEnabled = defaults.bool(forKey: Keys.stripPanelEnabled)
        self.autoPaste = defaults.bool(forKey: Keys.autoPaste)
        self.locale = defaults.string(forKey: Keys.locale) ?? "auto"
        self.toastEnabled = defaults.bool(forKey: Keys.toastEnabled)
        self.explorerMode = defaults.bool(forKey: Keys.explorerMode)
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.stackPillEnabled = defaults.bool(forKey: Keys.stackPillEnabled)
    }

    enum PrimarySurface: String, CaseIterable, Identifiable {
        case spotlight
        case strip

        var id: String { rawValue }
        var label: String {
            switch self {
            case .spotlight: return "Spotlight modal (centred)"
            case .strip:     return "Bottom strip (carousel)"
            }
        }
        var iconName: String {
            switch self {
            case .spotlight: return "rectangle.center.inset.filled"
            case .strip:     return "rectangle.bottomthird.inset.filled"
            }
        }

        var jpLabel: String {
            switch self {
            case .strip:     return "下部ストリップ（メイン）"
            case .spotlight: return "Spotlight モーダル（検索特化）"
            }
        }
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
