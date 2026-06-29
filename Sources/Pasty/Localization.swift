//
//  Localization.swift
//  Pasty
//
//  Lightweight L10n helpers for the SPM target. Routes lookups through
//  `Bundle.module` so the en.lproj / ja.lproj `.strings` files ship with the
//  resources processed by SwiftPM.
//
//  Usage:
//      L10n("onboarding.01.title")
//      L10n.format("settings.retention.daysFormat", 7)
//      Text(L10nKey("onboarding.01.title"))           // SwiftUI
//

import Foundation
import SwiftUI

/// Resolve a localized string from this module's bundle. Falls back to the key
/// itself if no entry is found.
func L10n(_ key: String, comment: StaticString = "") -> String {
    NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: String(describing: comment))
}

enum L10nFormat {
    /// Resolve a format-style entry (e.g. `"%lld days"`) and apply arguments.
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let template = NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
        return String(format: template, locale: Locale.current, arguments: args)
    }
}

/// SwiftUI helper: returns a `Text` that resolves a key against `Bundle.module`.
func L10nText(_ key: String) -> Text {
    Text(LocalizedStringKey(key), bundle: .module)
}
