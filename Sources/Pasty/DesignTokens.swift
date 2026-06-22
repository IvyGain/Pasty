import SwiftUI
import AppKit

/// Pasty v0.9.8-beta — Luxury Design Tokens.
///
/// 既存の `PastyTheme` / `ModernTokens` は維持しつつ、
/// **全サーフェイス共通の "高級感ボキャブラリ"** として PastyDesign を新設する。
/// 色は macOS の NSAppearance に追従する dynamic provider で実装し、
/// Asset Catalog (.xcassets) なしで Light/Dark を切り替える。
enum PastyDesign {

    // MARK: - Color
    enum Color {
        /// Indigo accent — Light #6366F1 / Dark #818CF8
        static let accent = SwiftUI.Color(
            light: NSColor(srgbRed: 0x63/255.0, green: 0x66/255.0, blue: 0xF1/255.0, alpha: 1),
            dark:  NSColor(srgbRed: 0x81/255.0, green: 0x8C/255.0, blue: 0xF8/255.0, alpha: 1)
        )
        /// Violet secondary — Light #A855F7 / Dark #C084FC
        static let secondary = SwiftUI.Color(
            light: NSColor(srgbRed: 0xA8/255.0, green: 0x55/255.0, blue: 0xF7/255.0, alpha: 1),
            dark:  NSColor(srgbRed: 0xC0/255.0, green: 0x84/255.0, blue: 0xFC/255.0, alpha: 1)
        )
        /// Base surface (window-ish, opaque) — Light #FFFFFF / Dark #1C1C1E
        static let surface = SwiftUI.Color(
            light: NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
            dark:  NSColor(srgbRed: 0x1C/255.0, green: 0x1C/255.0, blue: 0x1E/255.0, alpha: 1)
        )
        /// Elevated surface (cards, popovers) — Light #F8F9FB / Dark #2C2C2E
        static let surfaceElevated = SwiftUI.Color(
            light: NSColor(srgbRed: 0xF8/255.0, green: 0xF9/255.0, blue: 0xFB/255.0, alpha: 1),
            dark:  NSColor(srgbRed: 0x2C/255.0, green: 0x2C/255.0, blue: 0x2E/255.0, alpha: 1)
        )
        /// Subtle hairline border — Light black @ 0.08 / Dark white @ 0.10
        static let border = SwiftUI.Color(
            light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08),
            dark:  NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
        )
        /// Primary text — Light #1D1D1F / Dark #F5F5F7
        static let textPrimary = SwiftUI.Color(
            light: NSColor(srgbRed: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0, alpha: 1),
            dark:  NSColor(srgbRed: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0, alpha: 1)
        )
        /// Secondary text — Light #6E6E73 / Dark #98989D
        static let textSecondary = SwiftUI.Color(
            light: NSColor(srgbRed: 0x6E/255.0, green: 0x6E/255.0, blue: 0x73/255.0, alpha: 1),
            dark:  NSColor(srgbRed: 0x98/255.0, green: 0x98/255.0, blue: 0x9D/255.0, alpha: 1)
        )
    }

    // MARK: - Spacing
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    // MARK: - Radius
    enum Radius {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 6
        static let md:  CGFloat = 10
        static let lg:  CGFloat = 14
        static let xl:  CGFloat = 20
        static let full: CGFloat = 999
    }

    // MARK: - Shadow
    enum Shadow {
        struct ShadowSpec {
            let c: SwiftUI.Color
            let r: CGFloat
            let y: CGFloat
        }
        static let subtle: [ShadowSpec] = [
            .init(c: .black.opacity(0.04), r: 2, y: 1),
            .init(c: .black.opacity(0.06), r: 8, y: 4)
        ]
        static let soft: [ShadowSpec] = [
            .init(c: .black.opacity(0.05), r: 4, y: 2),
            .init(c: .black.opacity(0.10), r: 16, y: 8)
        ]
        static let lifted: [ShadowSpec] = [
            .init(c: .black.opacity(0.08), r: 8, y: 4),
            .init(c: .black.opacity(0.16), r: 32, y: 16)
        ]
        static let prominent: [ShadowSpec] = [
            .init(c: .black.opacity(0.12), r: 16, y: 8),
            .init(c: .black.opacity(0.20), r: 48, y: 24)
        ]
    }

    // MARK: - TypeRamp
    enum TypeRamp {
        static let caption:    Font = .system(size: 11, weight: .medium,   design: .default)
        static let body:       Font = .system(size: 13, weight: .regular,  design: .default)
        static let bodyMedium: Font = .system(size: 13, weight: .medium,   design: .default)
        static let title:      Font = .system(size: 15, weight: .semibold, design: .default)
        static let hero:       Font = .system(size: 22, weight: .bold,     design: .default)
        static let mono:       Font = .system(size: 12, weight: .regular,  design: .monospaced)
    }

    // MARK: - Animation
    enum Animation {
        /// Smooth, dignified (panels, sections)
        static let gentle:  SwiftUI.Animation = .spring(response: 0.5,  dampingFraction: 0.85)
        /// Quick, responsive (hovers, taps)
        static let snappy:  SwiftUI.Animation = .spring(response: 0.35, dampingFraction: 0.85)
        /// Playful (onboarding, transitions)
        static let bouncy:  SwiftUI.Animation = .spring(response: 0.5,  dampingFraction: 0.7)
    }
}

// MARK: - Color(light:dark:) bridge

extension SwiftUI.Color {
    /// macOS NSAppearance に追従する dynamic color。
    /// .xcassets を持たないターゲットで Light/Dark を切り替えるためのヘルパ。
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark ? dark : light
        })
    }
}

// MARK: - pastyShadow modifier

extension View {
    /// 複数レイヤーのドロップシャドウを `PastyDesign.Shadow.*` から重ねがけ。
    func pastyShadow(_ specs: [PastyDesign.Shadow.ShadowSpec]) -> some View {
        specs.reduce(AnyView(self)) { acc, spec in
            AnyView(acc.shadow(color: spec.c, radius: spec.r, x: 0, y: spec.y))
        }
    }
}
