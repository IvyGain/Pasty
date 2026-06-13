import SwiftUI

/// Shared visual tokens. Tweaking here ripples through every panel.
enum PastyTheme {
    static let cornerRadius: CGFloat = 14
    static let panelPadding: CGFloat = 10
    static let rowSpacing: CGFloat = 2
    static let rowCornerRadius: CGFloat = 8
    static let strokeOpacity: Double = 0.08
    static let backgroundMaterial: NSVisualEffectView.Material = .hudWindow
    static let backgroundBlending: NSVisualEffectView.BlendingMode = .behindWindow

    static let monoFont = Font.system(.body, design: .monospaced)
    static let titleFont = Font.system(size: 13, weight: .semibold, design: .default)
    static let subtitleFont = Font.system(size: 11, weight: .regular, design: .default)
}

/// SwiftUI bridge around `NSVisualEffectView` so we can apply the same
/// frosted-glass material on every Pasty panel.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = PastyTheme.backgroundMaterial
    var blending: NSVisualEffectView.BlendingMode = PastyTheme.backgroundBlending

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
