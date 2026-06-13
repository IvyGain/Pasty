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
    let body: AnyView
}

// MARK: - OnboardingView (Raycast-style)

@MainActor
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var stepIndex: Int = 0
    @State private var triggeredHotkey: Bool = false

    private var steps: [OnboardingStep] {
        [
            OnboardingStep(
                badge: "01", title: "ようこそ、Pasty へ",
                subtitle: "あなたのコピー履歴を、思考のスピードで取り出せるようにします。",
                body: AnyView(welcomeBody)
            ),
            OnboardingStep(
                badge: "02", title: "⇧⌘V でいつでも呼び出す",
                subtitle: "どんなアプリでも、ストリップが下から立ち上がります。",
                body: AnyView(hotkeyBody)
            ),
            OnboardingStep(
                badge: "03", title: "ノッチに乗せれば、降りてくる",
                subtitle: "M1/M2/M3 のノッチ (なくても画面上端) にカーソルを置くだけ。",
                body: AnyView(notchBody)
            ),
            OnboardingStep(
                badge: "04", title: "アクセシビリティ権限を許可",
                subtitle: "選択したクリップを自動で ⌘V するために必要です。Pasty は履歴を外部に送りません。",
                body: AnyView(accessibilityBody)
            ),
            OnboardingStep(
                badge: "05", title: "フォルダで定型文を倉庫化",
                subtitle: "履歴 + 色付きフォルダで、繰り返し使う文章をワンクリックで貼付。",
                body: AnyView(folderBody)
            ),
            OnboardingStep(
                badge: "06", title: "キーボードだけで完結する",
                subtitle: "マウスを使わずに探す、選ぶ、貼る。生産性は手元から逃げない。",
                body: AnyView(keyboardBody)
            ),
            OnboardingStep(
                badge: "07", title: "準備完了。",
                subtitle: "あとは ⇧⌘V でいつでも Pasty を呼んでください。",
                body: AnyView(completeBody)
            )
        ]
    }

    var body: some View {
        ZStack {
            // === 背景: 多層グラデーション ===
            backgroundLayer

            VStack(spacing: 0) {
                topBar
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
    }

    private var hotkeyBody: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                KeyCap(label: "⇧", size: 72)
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCap(label: "⌘", size: 72)
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tertiary)
                KeyCap(label: "V", size: 72)
            }
            if triggeredHotkey {
                Label("ナイス! ストリップが立ち上がりました", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Text("今すぐ試してみよう")
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
            Text("マウスを乗せると、ここから降りてきます")
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
                Label("システム設定を開く", systemImage: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(height: 220)
    }

    private var folderBody: some View {
        HStack(spacing: 12) {
            ForEach(["7C8CF8", "F8AA7C", "7CF88C", "F87CE0"], id: \.self) { hex in
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: "#\(hex)").opacity(0.18))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(Color(hex: "#\(hex)"))
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(width: 80, height: 80)
                .shadow(color: Color(hex: "#\(hex)").opacity(0.3), radius: 8, x: 0, y: 4)
            }
        }
        .frame(height: 220)
    }

    private var keyboardBody: some View {
        // 2 列に分けて 220pt 程度に収める
        let leftRows: [(String, String)] = [
            ("⇧⌘V", "Pasty を呼び出す"),
            ("← / →", "前後のクリップへ移動"),
            ("Tab / ⇧Tab", "フォルダを切り替える"),
            ("Space", "プレビュー"),
            ("Return", "貼付"),
            ("⌘?", "ショートカット早見表")
        ]
        let rightRows: [(String, String)] = [
            ("⇧← / ⇧→", "範囲選択"),
            ("X", "選択トグル"),
            ("⌘A", "全選択"),
            ("⌘1〜9", "番号で即貼付"),
            ("⌘Return", "結合して貼付")
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

// MARK: - KeyCap

private struct KeyCap: View {
    let label: String
    var size: CGFloat = 72

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                    // 上端ハイライト
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(LinearGradient(
                            colors: [Color.white.opacity(0.3), Color.clear],
                            startPoint: .top, endPoint: .center
                        ), lineWidth: 0.5)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 4)
    }
}

// MARK: - OnboardingPresenter

@MainActor
final class OnboardingPresenter {
    static let shared = OnboardingPresenter()

    private var window: NSWindow?

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
}
