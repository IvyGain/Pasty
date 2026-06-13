import SwiftUI
import AppKit

/// Pasty のデザイン言語。**全 UI で必ずここを参照**することで
/// トーンとリズムを揃える。Apple Mail / Notes / Things のような
/// "Sonoma 以降の高級感" を意識した余白・角丸・微細グレースケール。
enum PastyTheme {
    // MARK: - Geometry
    static let cornerRadius: CGFloat       = 18
    static let cardCornerRadius: CGFloat   = 14
    static let rowCornerRadius: CGFloat    = 10
    static let panelPadding: CGFloat       = 14
    static let rowSpacing: CGFloat         = 4
    static let strokeOpacity: Double       = 0.07

    // MARK: - Materials
    static let backgroundMaterial: NSVisualEffectView.Material = .hudWindow
    static let backgroundBlending: NSVisualEffectView.BlendingMode = .behindWindow

    // MARK: - Typography
    /// アプリ全体のサンセリフベース。SF Pro Display を優先しつつ、日本語は
    /// ヒラギノ角ゴ ProN（W3/W6）。Apple の Sonoma Notes / Calendar と同じ
    /// 落ち着いた重量感。
    static let titleFont: Font = .system(size: 14, weight: .semibold, design: .default)
    static let bodyFont:  Font = .system(size: 13, weight: .regular,  design: .default)
    static let subtitleFont: Font = .system(size: 11, weight: .regular, design: .default)
    static let metaFont:  Font = .system(size: 10.5, weight: .medium, design: .default)
    static let captionFont: Font = .system(size: 10, weight: .regular, design: .default)
    /// 数値・コード用のモノスペース（New York 風）。SF Mono を 13pt。
    static let monoFont: Font = .system(size: 12.5, weight: .regular, design: .monospaced)
    /// ヘッドライン用（タイトルバーに大きく置く時）。
    static let headlineFont: Font = .system(size: 18, weight: .semibold, design: .default)

    /// AppKit 用の NSFont 変換ヘルパ。
    static func nsTitle()    -> NSFont { NSFont.systemFont(ofSize: 14, weight: .semibold) }
    static func nsBody()     -> NSFont { NSFont.systemFont(ofSize: 13, weight: .regular) }
    static func nsMono(size: CGFloat = 12.5) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Color tokens (system aware)
    /// アプリのアクセント (インディゴ寄りのブルー)。デフォルト accentColor を使うが
    /// 直接参照したい時用。
    static let accent  = Color.accentColor

    /// 通常テキスト。
    static let label: Color = Color.primary
    /// セカンダリテキスト (subtle)。
    static let secondaryLabel: Color = Color.secondary
    /// 三次的なメタ情報。
    static let tertiaryLabel: Color = Color.secondary.opacity(0.75)
}

/// SwiftUI から NSVisualEffectView を被せるための薄いブリッジ。
/// `material` と `blending` は Theme から既定値を引いている。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = PastyTheme.backgroundMaterial
    var blending: NSVisualEffectView.BlendingMode = PastyTheme.backgroundBlending
    var emphasized: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = emphasized
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.isEmphasized = emphasized
    }
}

/// 上品なホバー反応用 ViewModifier。カードや行に付けると、ホバー時に
/// うっすら背景が立ち上がる + わずかにスケール。
struct LuxuryHover: ViewModifier {
    @State private var hovering = false
    var scale: CGFloat = 1.02
    var background: Color = .primary
    var radius: CGFloat = PastyTheme.cardCornerRadius

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(background.opacity(hovering ? 0.05 : 0))
            )
            .scaleEffect(hovering ? scale : 1)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 高級感のあるホバー反応 (微小スケール + 薄いハイライト)。
    func luxuryHover(scale: CGFloat = 1.02, radius: CGFloat = PastyTheme.cardCornerRadius) -> some View {
        modifier(LuxuryHover(scale: scale, radius: radius))
    }
}

/// パネル全体に被せる、上品な「フロスト + 微かなインナーシャドウ + ヘアライン」のスタイル。
struct LuxuryPanelBackground: ViewModifier {
    var radius: CGFloat = PastyTheme.cornerRadius

    func body(content: Content) -> some View {
        content
            .background(VisualEffectBackground())
            // ふんわりとした内側のグラデーション (より深みのある質感)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.05), Color.white.opacity(0)],
                        startPoint: .top,
                        endPoint: .center
                    ))
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // ヘアラインを上下で強弱 (Sonoma の Notes 風)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ), lineWidth: 0.75)
            )
    }
}

extension View {
    /// ストリップやスポットライトなどのパネル外周にかける既定スタイル。
    func luxuryPanelBackground(radius: CGFloat = PastyTheme.cornerRadius) -> some View {
        modifier(LuxuryPanelBackground(radius: radius))
    }
}
