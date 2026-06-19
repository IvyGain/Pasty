import SwiftUI
import AppKit

// MARK: - Color tokens (Linear / Vercel / shadcn 系)
/// shadcn/Linear/Vercel に影響を受けたニュートラルパレット。
/// Light/Dark で自動切替し、Pasty の "次世代 SaaS" トーンに統一する。
enum ModernTokens {
    /// 表面（カードや行の背景）— 控えめなニュートラル
    static var surface: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.isDarkMode
                ? NSColor(white: 1.0, alpha: 0.04)
                : NSColor(white: 0.0, alpha: 0.025)
        })
    }
    /// ホバー時の表面
    static var surfaceHover: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.isDarkMode
                ? NSColor(white: 1.0, alpha: 0.07)
                : NSColor(white: 0.0, alpha: 0.045)
        })
    }
    /// 強調された表面
    static var surfaceStrong: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.isDarkMode
                ? NSColor(white: 1.0, alpha: 0.10)
                : NSColor(white: 0.0, alpha: 0.075)
        })
    }
    /// ヘアライン（仕切り線）
    static var hairline: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.isDarkMode
                ? NSColor(white: 1.0, alpha: 0.10)
                : NSColor(white: 0.0, alpha: 0.08)
        })
    }
    /// 強いヘアライン
    static var hairlineStrong: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.isDarkMode
                ? NSColor(white: 1.0, alpha: 0.18)
                : NSColor(white: 0.0, alpha: 0.14)
        })
    }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark]) != nil
    }
}

// MARK: - Modern Search Field
/// command palette / shadcn Input 風の検索フィールド。
@MainActor
struct ModernSearchField: View {
    @Binding var text: String
    var placeholder: String = "クリップを検索…"
    var shortcut: String? = "⌘F"
    /// true なら非フォーカス時は折り畳み (アイコンのみ)、フォーカス時に展開
    var collapsible: Bool = false
    var expandedWidth: CGFloat = 320
    var onSubmit: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var hovering = false

    private var isExpanded: Bool {
        !collapsible || focused || !text.isEmpty || hovering
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(focused ? Color.accentColor.opacity(0.85) : .secondary)
                .animation(.easeOut(duration: 0.15), value: focused)
            if isExpanded {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .regular))
                    .tracking(-0.1)
                    .focused($focused)
                    .frame(minWidth: 0)
                    .onSubmit {
                        // v0.8.9: Enter は親 (StripPanel) に橋渡しして貼付を発火させる。
                        // 検索フィールドにフォーカスがあるときに Enter が死ぬ問題を解消。
                        if let cb = onSubmit {
                            focused = false  // KeyCatcher にフォーカスを返す前段
                            cb()
                        }
                    }
            }
            if isExpanded, !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else if isExpanded, let shortcut {
                // shadcn kbd: 半透明背景 + ヘアライン + わずかなインセットシャドウ
                Text(shortcut)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(ModernTokens.surfaceStrong.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(ModernTokens.hairline, lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5.5)
        .frame(width: isExpanded ? expandedWidth : 34, alignment: .leading)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isExpanded)
        .onHover { hovering = $0 }
        .background(
            // 内側のかすかなインセット感（shadcn流）
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(focused ? ModernTokens.surfaceStrong : ModernTokens.surface)
                // Top inset highlight
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.black.opacity(0.06), Color.clear],
                            startPoint: .top, endPoint: .center
                        ),
                        lineWidth: 0.5
                    )
                    .mask(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.55) : ModernTokens.hairline,
                              lineWidth: focused ? 1.5 : 0.5)
        )
        .shadow(color: focused ? Color.accentColor.opacity(0.12) : .clear,
                radius: focused ? 8 : 0, x: 0, y: 0)
        .animation(.easeOut(duration: 0.18), value: focused)
    }
}

// MARK: - Modern Pill (shadcn Badge 風)
/// shadcn Badge を踏襲したモダンなピル。
@MainActor
struct ModernPill<Content: View>: View {
    var color: Color
    var isSelected: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected
                              ? color.opacity(0.18)
                              : (hovering ? ModernTokens.surfaceHover : ModernTokens.surface))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? color.opacity(0.4) : ModernTokens.hairline,
                                      lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Modern Icon Button
/// shadcn Ghost Button を踏襲したツールバー用アイコンボタン。
@MainActor
struct ModernIconButton: View {
    var systemImage: String
    var help: String? = nil
    var role: ButtonRole? = nil
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(role == .destructive ? Color.red : Color.primary.opacity(0.7))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? ModernTokens.surfaceHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

// MARK: - Modern Primary Button
/// shadcn Primary Button 風。グラデーション + 微細シャドウ。
@MainActor
struct ModernPrimaryButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.accentColor,
                                     Color.accentColor.opacity(0.88)],
                            startPoint: .top, endPoint: .bottom
                        ))
                )
                .shadow(color: Color.accentColor.opacity(hovering ? 0.35 : 0.18),
                        radius: hovering ? 8 : 4, x: 0, y: 2)
                .scaleEffect(hovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Modern Folder Tab
/// **Awwwards 級** に作り直したフォルダタブ。色ドット + ラベル + 件数バッジ。
/// 選択時はアクセントカラーのソフトフィル + 強いラベル、非選択時はゴースト。
@MainActor
struct ModernFolderTab: View {
    var name: String
    var colorHex: String?       // nil なら system gray
    var systemImage: String?    // 履歴タブ等
    var count: Int?             // 件数バッジ（任意）
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    private var accent: Color {
        if let hex = colorHex { return Color(hex: hex) }
        return Color.secondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .secondary)
                        .frame(width: 12)
                } else {
                    // ドット: 選択時は内側ハイライト付き、ドロップシャドウで浮かせる
                    Circle()
                        .fill(LinearGradient(
                            colors: [accent.opacity(0.95), accent.opacity(0.78)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                        )
                        .shadow(color: accent.opacity(isSelected ? 0.45 : 0.18),
                                radius: isSelected ? 3 : 1.5, x: 0, y: 0.5)
                }
                Text(name)
                    .font(.system(size: 12.5,
                                  weight: isSelected ? .semibold : .medium))
                    .tracking(-0.1)
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.74))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? accent : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected
                                      ? accent.opacity(0.18)
                                      : ModernTokens.surfaceStrong)
                        )
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(isSelected
                              ? accent.opacity(0.12)
                              : (hovering ? ModernTokens.surfaceHover : .clear))
                    // 選択時はトップに内側ハイライト
                    if isSelected {
                        Capsule(style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.25), Color.clear],
                                    startPoint: .top, endPoint: .center
                                ),
                                lineWidth: 0.5
                            )
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.42) : .clear,
                                  lineWidth: 1)
            )
            .shadow(color: isSelected ? accent.opacity(0.18) : .clear,
                    radius: isSelected ? 6 : 0, x: 0, y: isSelected ? 2 : 0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Kind Chip (segmented filter)
/// Linear / Vercel 系のセグメント内チップ。選択時にカード状に浮かせる。
@MainActor
struct KindChip: View {
    var label: String
    var systemImage: String?
    var isOn: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                    .tracking(-0.05)
            }
            .foregroundStyle(isOn ? Color.primary : Color.primary.opacity(hovering ? 0.85 : 0.6))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(isOn
                              ? Color.primary.opacity(0.10)
                              : (hovering ? ModernTokens.surfaceHover.opacity(0.6) : .clear))
                    if isOn {
                        // 選択時はトップに内側ハイライト
                        Capsule(style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.22), Color.clear],
                                    startPoint: .top, endPoint: .center
                                ),
                                lineWidth: 0.5
                            )
                    }
                }
            )
            .shadow(color: isOn ? .black.opacity(0.08) : .clear,
                    radius: isOn ? 3 : 0, x: 0, y: isOn ? 1 : 0)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: isOn)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Section Divider with subtle gradient
/// 普通の Divider より洗練された "soft fade" 仕切り線。
@MainActor
struct SoftDivider: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [
                    Color.clear,
                    ModernTokens.hairlineStrong,
                    Color.clear
                ],
                startPoint: .leading, endPoint: .trailing
            ))
            .frame(height: 1)
    }
}
