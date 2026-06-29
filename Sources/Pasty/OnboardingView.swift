import SwiftUI
import AppKit

// MARK: - UserDefaults key

private enum OnboardingDefaults {
    static let completedKey = "pasty.hasCompletedOnboarding"
}

// MARK: - Step model

@MainActor
private struct OnboardingStep: Identifiable {
    let id = UUID()
    let badge: String        // "01" など
    let title: String
    let subtitle: String
    let category: OnboardingCategory
    let body: AnyView
}

// MARK: - Category model

enum OnboardingCategory: String, CaseIterable, Identifiable {
    case basic       // 基本操作
    case notch       // ノッチ
    case folder      // フォルダ
    case ai          // AI
    case shortcut    // ショートカット

    var id: String { rawValue }

    var label: String {
        switch self {
        case .basic:    return "基本操作"
        case .notch:    return "ノッチ"
        case .folder:   return "フォルダ"
        case .ai:       return "AI"
        case .shortcut: return "ショートカット"
        }
    }

    var systemImage: String {
        switch self {
        case .basic:    return "hand.point.up.left.fill"
        case .notch:    return "rectangle.topthird.inset.filled"
        case .folder:   return "folder.fill"
        case .ai:       return "sparkles"
        case .shortcut: return "keyboard"
        }
    }
}

// MARK: - OnboardingView (Raycast-style)

@MainActor
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var stepIndex: Int = 0
    @State private var triggeredHotkey: Bool = false

    private var steps: [OnboardingStep] {
        [
            // 01 — Welcome (basic)
            OnboardingStep(
                badge: "01", title: L10n("onboarding.01.title"),
                subtitle: L10n("onboarding.01.subtitle"),
                category: .basic,
                body: AnyView(welcomeBody)
            ),
            // 02 — Hotkey (basic / shortcut)
            OnboardingStep(
                badge: "02", title: L10n("onboarding.02.title"),
                subtitle: L10n("onboarding.02.subtitle"),
                category: .basic,
                body: AnyView(hotkeyBody)
            ),
            // 03 — Notch reveal
            OnboardingStep(
                badge: "03", title: L10n("onboarding.03.title"),
                subtitle: L10n("onboarding.03.subtitle"),
                category: .notch,
                body: AnyView(notchBody)
            ),
            // 03b — Notch wheel scroll (NEW)
            OnboardingStep(
                badge: "03b", title: L10n("onboarding.03b.title"),
                subtitle: L10n("onboarding.03b.subtitle"),
                category: .notch,
                body: AnyView(notchScrollBody)
            ),
            // 04 — Accessibility (basic)
            OnboardingStep(
                badge: "04", title: L10n("onboarding.04.title"),
                subtitle: L10n("onboarding.04.subtitle"),
                category: .basic,
                body: AnyView(accessibilityBody)
            ),
            // 05 — Folders (folder)
            OnboardingStep(
                badge: "05", title: L10n("onboarding.05.title"),
                subtitle: L10n("onboarding.05.subtitle"),
                category: .folder,
                body: AnyView(folderBody)
            ),
            // 06 — Clip → folder (folder)
            OnboardingStep(
                badge: "06", title: L10n("onboarding.06.title"),
                subtitle: L10n("onboarding.06.subtitle"),
                category: .folder,
                body: AnyView(clipToFolderBody)
            ),
            // 06b — Folder drag-reorder (NEW, folder)
            OnboardingStep(
                badge: "06b", title: L10n("onboarding.06b.title"),
                subtitle: L10n("onboarding.06b.subtitle"),
                category: .folder,
                body: AnyView(dragReorderBody)
            ),
            // 07 — Stack (basic)
            OnboardingStep(
                badge: "07", title: L10n("onboarding.07.title"),
                subtitle: L10n("onboarding.07.subtitle"),
                category: .basic,
                body: AnyView(stackBody)
            ),
            // 08 — Multi-select (NEW v0.9.0 UX) (basic)
            OnboardingStep(
                badge: "08", title: L10n("onboarding.08.title"),
                subtitle: L10n("onboarding.08.subtitle"),
                category: .basic,
                body: AnyView(multiSelectBody)
            ),
            // 08b — AI macro + sound + glow (NEW, ai)
            OnboardingStep(
                badge: "08b", title: L10n("onboarding.08b.title"),
                subtitle: L10n("onboarding.08b.subtitle"),
                category: .ai,
                body: AnyView(aiMacroBody)
            ),
            // 09 — Keyboard mastery (shortcut)
            OnboardingStep(
                badge: "09", title: L10n("onboarding.09.title"),
                subtitle: L10n("onboarding.09.subtitle"),
                category: .shortcut,
                body: AnyView(keyboardBody)
            ),
            // 09b — Confidential mode (NEW, shortcut)
            OnboardingStep(
                badge: "09b", title: L10n("onboarding.09b.title"),
                subtitle: L10n("onboarding.09b.subtitle"),
                category: .shortcut,
                body: AnyView(confidentialBody)
            ),
            // 10b — Quick-paste (NEW, shortcut)
            OnboardingStep(
                badge: "10b", title: L10n("onboarding.10b.title"),
                subtitle: L10n("onboarding.10b.subtitle"),
                category: .shortcut,
                body: AnyView(quickPasteBody)
            ),
            // 11 — Complete
            OnboardingStep(
                badge: "11", title: L10n("onboarding.11.title"),
                subtitle: L10n("onboarding.11.subtitle"),
                category: .basic,
                body: AnyView(completeBody)
            )
        ]
    }

    /// 各カテゴリの先頭ステップ index を返す
    private var categoryStartIndex: [OnboardingCategory: Int] {
        var map: [OnboardingCategory: Int] = [:]
        for (i, s) in steps.enumerated() where map[s.category] == nil {
            map[s.category] = i
        }
        return map
    }

    /// 現在の step が属するカテゴリ
    private var currentCategory: OnboardingCategory {
        steps[stepIndex].category
    }

    var body: some View {
        ZStack {
            // === 背景: 多層グラデーション ===
            backgroundLayer

            VStack(spacing: 0) {
                topBar
                categoryChips
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
                progressIndicator
                    .padding(.bottom, 14)
                bottomBar
                    .padding(.horizontal, 36)
                    .padding(.bottom, 28)
            }
        }
        .frame(width: 760, height: 600)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: stepIndex)
    }

    // MARK: - Category chips

    private var categoryChips: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingCategory.allCases) { category in
                categoryChip(category)
            }
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private func categoryChip(_ category: OnboardingCategory) -> some View {
        let isActive = (category == currentCategory)
        Button {
            if let idx = categoryStartIndex[category] {
                stepIndex = idx
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(category.label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .background(
                Capsule(style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isActive ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                        lineWidth: isActive ? 1.2 : 0.7
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.label) セクション")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            VisualEffectBackground()
            // Accent グラデーション (左上から右下)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color.accentColor.opacity(0.04),
                    Color.clear
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Soft glow (右下)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.20), Color.clear],
                center: .bottomTrailing,
                startRadius: 50, endRadius: 360
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar (badge + skip)

    private var topBar: some View {
        HStack {
            // ステップバッジ
            HStack(spacing: 8) {
                Text(steps[stepIndex].badge)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.85))
                    )
                Text("\(stepIndex + 1) / \(steps.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if stepIndex < steps.count - 1 {
                Button("スキップ", action: skip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28).padding(.top, 22)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 22) {
            steps[stepIndex].body
                .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                Text(steps[stepIndex].title)
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(steps[stepIndex].subtitle)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 56)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 36)
        .id(stepIndex)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    // MARK: - Step bodies

    private var welcomeBody: some View {
        ZStack {
            // 後ろの円形グロー
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 220, height: 220)
                .blur(radius: 24)
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 110, weight: .regular))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .symbolRenderingMode(.hierarchical)
                .shadow(color: Color.accentColor.opacity(0.4), radius: 18, x: 0, y: 8)
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }

    private var hotkeyBody: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                KeyCap(label: "⇧", size: 72, animatePressed: true)
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCap(label: "⌘", size: 72, animatePressed: true)
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCap(label: "V", size: 72, animatePressed: true)
            }
            if triggeredHotkey {
                Label(L10n("onboarding.cta.success"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Text(L10n("onboarding.cta.tryNow"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 220)
    }

    private var notchBody: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: 260, height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 10)

                // ノッチ風の凹み
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black)
                    .frame(width: 140, height: 26)
                    .offset(y: -55)
            }
            Image(systemName: "arrow.down")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.accentColor)
            Text(L10n("onboarding.notch.hint"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 220)
    }

    private var accessibilityBody: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 150, height: 150)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 78, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            Button {
                _ = PasteAutomator.shared.ensureAccessibilityPermission(prompt: true)
            } label: {
                Label(L10n("action.openSystemSettings"), systemImage: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(height: 220)
    }

    private var folderBody: some View {
        // フォルダタブ + 「+ 新しいフォルダ」 のヘッダー風モック
        let samples: [(String, String, Int, Bool)] = [
            ("Inbox", "7C8CF8", 24, true),
            ("Work",  "F8AA7C", 12, false),
            ("Code",  "7CF88C",  7, false),
            ("Refs",  "F87CE0",  3, false)
        ]
        return VStack(spacing: 18) {
            // 上段: ヘッダー風タブ + 新規作成ボタン
            HStack(spacing: 8) {
                ForEach(samples, id: \.0) { sample in
                    ModernFolderTab(
                        name: sample.0,
                        colorHex: sample.1,
                        systemImage: nil,
                        count: sample.2,
                        isSelected: sample.3,
                        action: {}
                    )
                }
                Spacer(minLength: 8)
                // ダッシュド「+ 新しいフォルダ」 pill
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L10n("onboarding.folder.newFolder"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .stroke(
                            Color.primary.opacity(0.22),
                            style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                        )
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
            .padding(.horizontal, 24)

            // 下段: ヒント "Tab / ⇧Tab で切替"
            HStack(spacing: 10) {
                kbInlineCap("Tab")
                Text("/")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                kbInlineCap("⇧Tab")
                Text(L10n("onboarding.folder.tabHint"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 220)
    }

    private var clipToFolderBody: some View {
        HStack(spacing: 16) {
            clipToFolderCard(
                number: "1",
                icon: "rectangle.and.hand.point.up.left.fill",
                tint: Color(hex: "#7C8CF8"),
                title: "ドラッグ",
                description: "履歴のクリップカードを\nフォルダタブに直接ドラッグ"
            )
            clipToFolderCard(
                number: "2",
                icon: "contextualmenu.and.cursorarrow",
                tint: Color(hex: "#F8AA7C"),
                title: "右クリック",
                description: "クリップを右クリック →\n「○○ へ移動」を選ぶ"
            )
            clipToFolderCard(
                number: "3",
                icon: "checklist",
                tint: Color(hex: "#7CF88C"),
                title: "複数選択",
                description: "Space で複数選んで\n右クリック → 一括移動"
            )
        }
        .frame(height: 220)
    }

    private func clipToFolderCard(
        number: String,
        icon: String,
        tint: Color,
        title: String,
        description: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // カード本体
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .frame(width: 200, height: 160)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: tint.opacity(0.18), radius: 12, x: 0, y: 6)

            // 番号バッジ
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.85))
                )
                .offset(x: 10, y: 10)
        }
        .frame(width: 200, height: 160)
    }

    private func kbInlineCap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
    }

    private var stackBody: some View {
        HStack(alignment: .center, spacing: 22) {
            // 左: 操作フロー (右クリック → Stack に追加)
            VStack(alignment: .leading, spacing: 14) {
                stackStepRow(num: 1, icon: "cursorarrow.click.2", text: "クリップを右クリック → \"Stack に追加\"")
                stackStepRow(num: 2, icon: "rectangle.stack.fill", text: "画面右下の Pill にスタックが積まれる")
                stackStepRow(num: 3, icon: "arrow.down.doc", text: "Pill から好きな順に貼付、または「すべて貼付」で結合")
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )

            // 右: Pill のモック
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: 140, height: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "rectangle.stack.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Stack 3")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Spacer()
                    }
                    ForEach(0..<3) { i in
                        HStack {
                            Circle().fill(Color.accentColor.opacity(0.7)).frame(width: 6, height: 6)
                            Text(["Hello!", "Thanks", "— mash"][i])
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer()
                            Text("⌘V")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                        }
                    }
                    Spacer()
                    Button {} label: {
                        Text("すべて貼付")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .frame(width: 140, height: 180)
            }
        }
        .frame(height: 220)
    }

    private func stackStepRow(num: Int, icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(num)")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - v0.9.0 step bodies

    private var notchScrollBody: some View {
        VStack(spacing: 14) {
            NotchScrollMock()
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("ホイールを回すと履歴が左右に流れます")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 220)
    }

    private var dragReorderBody: some View {
        VStack(spacing: 14) {
            DragReorderDemo()
            Text("細い線がドロップ位置を教えてくれます")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 220)
    }

    private var multiSelectBody: some View {
        VStack(spacing: 14) {
            // 4 つの選択カード (うち 2 つを selected 表示)
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    multiSelectCardMock(
                        index: i,
                        title: ["Hello", "Thanks", "— mash", "P.S."][i],
                        order: [1, 0, 2, 0][i]
                    )
                }
            }
            HStack(spacing: 14) {
                multiSelectHintRow(icon: "checkmark.circle.fill",
                                   text: "Space で複数選択 → Enter で選んだ順に貼付")
                multiSelectHintRow(icon: "arrow.uturn.backward",
                                   text: "Esc 1 回目で解除、2 回目で閉じる")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(height: 220)
    }

    private func multiSelectCardMock(index: Int, title: String, order: Int) -> some View {
        let isSelected = order > 0
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: 100, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 1.8 : 1
                        )
                )
                .shadow(color: .black.opacity(isSelected ? 0.18 : 0.08), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("クリップ #\(index + 1)")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)

            if isSelected {
                Text("\(order)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                    .offset(x: -6, y: -6)
            }
        }
        .frame(width: 100, height: 64)
    }

    private func multiSelectHintRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(text)
        }
    }

    private var aiMacroBody: some View {
        VStack(spacing: 14) {
            ZStack {
                // 画面端 glow
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 2.4)
                    .frame(width: 280, height: 150)
                    .shadow(color: Color.accentColor.opacity(0.55), radius: 12)
                    .symbolEffectIfAvailable()

                // 内側: AI アクション結果のプレビュー
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: 252, height: 122)
                    .overlay(
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Color.accentColor)
                                    .pulseEffectIfAvailable()
                                Text("AI: 要約しました")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                Spacer()
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .bounceEffectIfAvailable()
                            }
                            Divider().opacity(0.4)
                            Text("ノッチ風 UI から AI マクロを呼び出して、整形・翻訳・要約まで一気通貫。")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .lineSpacing(2)
                        }
                        .padding(10)
                    )
            }
            Text("完了でサウンド + 画面端の縁取りで通知")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 220)
    }

    private var confidentialBody: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                KeyCap(label: "⌃", size: 56)
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCap(label: "⌥", size: 56)
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCap(label: "⇧", size: 56)
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCap(label: "P", size: 56)
            }
            ConfidentialModeBadge()
        }
        .frame(height: 220)
    }

    private var quickPasteBody: some View {
        VStack(spacing: 14) {
            // ⌃⌥1〜5 鍵盤チェイン
            HStack(spacing: 8) {
                KeyCap(label: "⌃", size: 52)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCap(label: "⌥", size: 52)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { n in
                        KeyCap(label: "\(n)", size: 44)
                    }
                }
            }
            // ヒント
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("直近 5 件を Pasty を開かず即貼付")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 220)
    }

    private var keyboardBody: some View {
        // 2 列に分けて 220pt 程度に収める
        let leftRows: [(String, String)] = [
            ("⇧⌘V", "Pasty を呼ぶ"),
            ("← / →", "前後のクリップへ移動"),
            ("Tab / ⇧Tab", "フォルダ切替"),
            ("Enter", "貼付"),
            ("⌘Enter", "結合貼付"),
            ("⌘?", "ヘルプ")
        ]
        let rightRows: [(String, String)] = [
            ("Space", "選択トグル"),
            ("⌘A / ⌘D", "全選択 / 解除"),
            ("⇧← / ⇧→", "範囲選択"),
            ("⌘Y", "Quick Look"),
            ("⌘⇧V", "再呼出")
        ]
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(leftRows, id: \.0) { kbRow($0.0, $0.1) }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rightRows, id: \.0) { kbRow($0.0, $0.1) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .frame(height: 220)
    }

    private var completeBody: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.green.opacity(0.25), Color.accentColor.opacity(0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 180, height: 180)
                .blur(radius: 10)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 120, weight: .regular))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.green, Color.green.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .symbolRenderingMode(.hierarchical)
                .shadow(color: Color.green.opacity(0.4), radius: 18, x: 0, y: 8)
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }

    private func kbRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                )
                .frame(width: 84, alignment: .leading)
            Text(label)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Progress

    private var progressIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps.count, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i == stepIndex
                          ? Color.accentColor
                          : Color.secondary.opacity(0.25))
                    .frame(width: i == stepIndex ? 28 : 8, height: 8)
                    .animation(.spring(response: 0.32, dampingFraction: 0.8), value: stepIndex)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("ステップ \(stepIndex + 1)、全 \(steps.count) ステップ")
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if stepIndex > 0 {
                Button("戻る") { stepIndex -= 1 }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            } else {
                Color.clear.frame(width: 80, height: 1)
            }
            Spacer()
            Button(primaryTitle) { advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        stepIndex == steps.count - 1 ? "Pasty を始める" : "次へ"
    }

    private func advance() {
        if stepIndex < steps.count - 1 {
            stepIndex += 1
        } else {
            onComplete()
        }
    }

    private func skip() {
        onComplete()
    }
}

// MARK: - KeyCap (with optional pressed animation)

private struct KeyCap: View {
    let label: String
    var size: CGFloat = 72
    /// `true` にすると 1.4s 周期で pressed/unpressed をループ
    var animatePressed: Bool = false

    @State private var pressed: Bool = false
    @State private var timer: Timer? = nil

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(pressed ? PastyDesign.Color.accent : PastyDesign.Color.textPrimary)
            .frame(width: size, height: size)
            .background(
                ZStack {
                    // 3D gradient surface — surface → surfaceElevated でガラス的奥行き
                    RoundedRectangle(cornerRadius: PastyDesign.Radius.lg, style: .continuous)
                        .fill(pressed
                              ? AnyShapeStyle(PastyDesign.Color.accent.opacity(0.12))
                              : AnyShapeStyle(LinearGradient(
                                    colors: [PastyDesign.Color.surface, PastyDesign.Color.surfaceElevated],
                                    startPoint: .top, endPoint: .bottom
                                )))
                    // 上端ハイライト (ガラス反射)
                    RoundedRectangle(cornerRadius: PastyDesign.Radius.lg, style: .continuous)
                        .stroke(LinearGradient(
                            colors: [Color.white.opacity(0.3), Color.clear],
                            startPoint: .top, endPoint: .center
                        ), lineWidth: 0.5)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: PastyDesign.Radius.lg, style: .continuous)
                    .stroke(
                        pressed ? PastyDesign.Color.accent.opacity(0.7) : PastyDesign.Color.border,
                        lineWidth: pressed ? 1.0 : 0.5
                    )
            )
            .scaleEffect(pressed ? 0.92 : 1.0)
            .pastyShadow(PastyDesign.Shadow.subtle)
            .animation(PastyDesign.Animation.bouncy, value: pressed)
            .onAppear {
                guard animatePressed else { return }
                timer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { _ in
                    Task { @MainActor in pressed.toggle() }
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
}

// MARK: - NotchScrollMock (B-3)

/// ノッチ風 RoundedRectangle + 横カルーセル + ホイールアイコン
@MainActor
private struct NotchScrollMock: View {
    @State private var offset: CGFloat = 0
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // ノッチ風枠
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: 300, height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)

                // ノッチ風の凹み
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black)
                    .frame(width: 130, height: 22)
                    .offset(y: -56)

                // 横カルーセル: 5 枚の小カード
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15 + Double(i) * 0.12))
                            .frame(width: 48, height: 64)
                            .overlay(
                                Text(["A", "B", "C", "D", "E"][i])
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                            )
                    }
                }
                .offset(x: offset)
                .frame(width: 270, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .offset(y: 12)

                // ホイールアイコン
                Image(systemName: "computermouse.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .padding(8)
                    .background(Circle().fill(.regularMaterial))
                    .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .offset(x: 170, y: 0)
            }
            .frame(width: 380, height: 130)
        }
        .onAppear {
            offset = 30
            timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 1.5)) {
                        offset = (offset > 0) ? -30 : 30
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - ConfidentialModeBadge (B-3)

@MainActor
private struct ConfidentialModeBadge: View {
    @State private var remaining: Int = 60
    @State private var timer: Timer? = nil

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .pulseEffectIfAvailable()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Confidential モード ON")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text("残り \(remaining)s")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: Color.accentColor.opacity(0.18), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Confidential モード オン、残り \(remaining) 秒")
        .onAppear {
            remaining = 60
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    if remaining > 0 {
                        remaining -= 1
                    } else {
                        remaining = 60
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - DragReorderDemo (B-3)

/// 3 つの ModernFolderTab スタブ + 隙間にスライドする Capsule
@MainActor
private struct DragReorderDemo: View {
    @State private var gapIndex: Int = 1
    @State private var timer: Timer? = nil

    /// `[(name, colorHex, count)]`
    private let folders: [(String, String, Int)] = [
        ("Inbox", "7C8CF8", 24),
        ("Work",  "F8AA7C", 12),
        ("Code",  "7CF88C",  7)
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                ForEach(folders.indices, id: \.self) { i in
                    ModernFolderTab(
                        name: folders[i].0,
                        colorHex: folders[i].1,
                        systemImage: nil,
                        count: folders[i].2,
                        isSelected: i == 0,
                        action: {}
                    )
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            // 隙間に挿入されるドロップ位置ライン
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: 30)
                .offset(x: gapOffsetX(), y: 14)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: gapIndex)
        }
        .frame(height: 80)
        .onAppear {
            gapIndex = 1
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    gapIndex = (gapIndex + 1) % (folders.count + 1)
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 各 ModernFolderTab の概算幅 (74pt) + spacing (8pt) を基に gap x 位置を計算
    private func gapOffsetX() -> CGFloat {
        let tabWidth: CGFloat = 74
        let spacing: CGFloat = 8
        let leading: CGFloat = 14   // padding.horizontal
        return leading + CGFloat(gapIndex) * (tabWidth + spacing) - spacing / 2
    }
}

// MARK: - SymbolEffect helpers (macOS 14+ で `.symbolEffect` を使う)

private extension View {
    /// `.symbolEffect(.pulse)` を macOS 14+ で適用 (それ以外は no-op)
    @ViewBuilder
    func pulseEffectIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.symbolEffect(.pulse, options: .repeating)
        } else {
            self
        }
    }

    /// `.symbolEffect(.bounce)` を macOS 14+ で適用
    @ViewBuilder
    func bounceEffectIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.symbolEffect(.bounce, options: .repeating)
        } else {
            self
        }
    }

    /// AI macro step の枠線 glow を脈動させるだけのプレースホルダ
    @ViewBuilder
    func symbolEffectIfAvailable() -> some View {
        self
    }
}

// MARK: - OnboardingPresenter

@MainActor
final class OnboardingPresenter {
    static let shared = OnboardingPresenter()

    private var window: NSWindow?
    private var miniWindow: NSWindow?

    private init() {}

    /// 初回起動かどうかをチェックして必要なら独立ウィンドウを表示
    func presentIfNeeded(onComplete: @escaping () -> Void) {
        let completed = UserDefaults.standard.bool(forKey: OnboardingDefaults.completedKey)
        guard !completed else { return }
        present(onComplete: onComplete)
    }

    /// 強制表示（設定から「再表示」用）
    func presentForce(onComplete: @escaping () -> Void) {
        present(onComplete: onComplete)
    }

    /// WhatsNew の `##` 見出しから動的に組み立てた「ミニオンボーディング」を表示。
    /// アップデート直後の起動で `WhatsNewPresenter.presentIfNeeded()` の隣 / 後段から呼ぶ。
    /// 見出しが取れない場合は何もしない。
    func presentMiniWhatsNew(version: String) {
        let headings = WhatsNewPresenter.shared.extractFeatureHeadings(forVersion: version)
        guard !headings.isEmpty else { return }

        if let existing = miniWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = MiniWhatsNewOnboardingView(
            version: version,
            headings: Array(headings.prefix(4))
        ) { [weak self] in
            self?.closeMini()
        }
        let hosting = NSHostingController(rootView: rootView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = "Pasty \(version) — はじめての操作"
        panel.contentViewController = hosting
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.center()
        panel.level = .floating
        miniWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.miniWindow = nil }
        }
    }

    // MARK: - Private

    private func present(onComplete: @escaping () -> Void) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = OnboardingView { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(true, forKey: OnboardingDefaults.completedKey)
            self.close()
            onComplete()
        }

        let hosting = NSHostingController(rootView: rootView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Pasty へようこそ"
        newWindow.contentViewController = hosting
        newWindow.isReleasedWhenClosed = false
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isMovableByWindowBackground = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true
        newWindow.center()

        self.window = newWindow

        // accessory モードのままだと前面に出てこないので一時的に regular へ
        NSApp.setActivationPolicy(.regular)
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 閉じたら accessory に戻す
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow, queue: .main
        ) { _ in
            Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func close() {
        window?.close()
        window = nil
    }

    private func closeMini() {
        miniWindow?.close()
        miniWindow = nil
    }
}

// MARK: - MiniWhatsNewOnboardingView

/// `##` 見出しから動的に組み立てる 3〜4 ステップの軽量カードフロー
@MainActor
private struct MiniWhatsNewOnboardingView: View {
    let version: String
    let headings: [String]
    let onClose: () -> Void

    @State private var index: Int = 0

    var body: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                // ヘッダー
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.accentColor)
                            .pulseEffectIfAvailable()
                        Text(String(format: L10n("whatsNew.title.versioned"), version))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(min(index + 1, headings.count)) / \(headings.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 22).padding(.top, 18)

                Spacer(minLength: 0)

                // カード
                if !headings.isEmpty {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.16))
                                .frame(width: 90, height: 90)
                                .blur(radius: 6)
                            Image(systemName: "sparkles")
                                .font(.system(size: 44, weight: .regular))
                                .foregroundStyle(Color.accentColor)
                                .symbolRenderingMode(.hierarchical)
                                .pulseEffectIfAvailable()
                        }
                        Text(headings[index])
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    .id(index)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }

                Spacer(minLength: 0)

                // インジケータ
                HStack(spacing: 6) {
                    ForEach(0..<headings.count, id: \.self) { i in
                        Capsule(style: .continuous)
                            .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == index ? 22 : 6, height: 6)
                    }
                }
                .padding(.bottom, 14)

                HStack {
                    if index > 0 {
                        Button(L10n("common.back")) { index -= 1 }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    } else {
                        Color.clear.frame(width: 80, height: 1)
                    }
                    Spacer()
                    Button(index == headings.count - 1 ? L10n("common.close") : L10n("common.next")) {
                        if index == headings.count - 1 {
                            onClose()
                        } else {
                            index += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 22).padding(.bottom, 18)
            }
        }
        .frame(width: 520, height: 380)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: index)
    }
}
