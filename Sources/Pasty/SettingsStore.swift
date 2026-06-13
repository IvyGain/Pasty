import Foundation
import SwiftUI
import Combine

/// Lightweight, user-defaults-backed preferences. Anything heavier (rule
/// engines, per-app blacklists with patterns) lives in SQLite.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

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

    private enum Keys {
        static let capturingEnabled   = "pasty.capturing"
        static let pauseUntil         = "pasty.pauseUntil"
        static let ignoredBundleIds   = "pasty.ignoredBundleIds"
        static let maxRetentionDays   = "pasty.maxRetentionDays"
        static let notchHoverEnabled  = "pasty.notchHoverEnabled"
        static let stripPanelEnabled  = "pasty.stripPanelEnabled"
        static let autoPaste          = "pasty.autoPaste"
        static let locale             = "pasty.locale"
    }

    private init() {
        defaults.register(defaults: [
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
            ]
        ])
        self.capturingEnabled = defaults.bool(forKey: Keys.capturingEnabled)
        self.pauseUntil = defaults.object(forKey: Keys.pauseUntil) as? Date
        self.ignoredBundleIds = Set(defaults.array(forKey: Keys.ignoredBundleIds) as? [String] ?? [])
        self.maxRetentionDays = defaults.integer(forKey: Keys.maxRetentionDays)
        self.notchHoverEnabled = defaults.bool(forKey: Keys.notchHoverEnabled)
        self.stripPanelEnabled = defaults.bool(forKey: Keys.stripPanelEnabled)
        self.autoPaste = defaults.bool(forKey: Keys.autoPaste)
        self.locale = defaults.string(forKey: Keys.locale) ?? "auto"
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
