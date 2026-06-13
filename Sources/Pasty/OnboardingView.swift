import SwiftUI
import AppKit

// MARK: - UserDefaults key

private enum OnboardingDefaults {
    static let completedKey = "pasty.hasCompletedOnboarding"
}

// MARK: - OnboardingView

@MainActor
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: Int = 0

    private let totalSteps = 3

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Group {
                    switch step {
                    case 0:
                        welcomeStep
                    case 1:
                        shortcutStep
                    default:
                        folderStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .trailing)))

                Spacer(minLength: 0)

                progressIndicator
                    .padding(.bottom, 18)

                controlBar
                    .padding(.horizontal, 36)
                    .padding(.bottom, 28)
            }
        }
        .frame(width: 640, height: 460)
        .animation(.easeInOut(duration: 0.22), value: step)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 4)

            Text("ようこそ、Pasty へ")
                .font(.system(size: 26, weight: .semibold, design: .default))
                .foregroundStyle(.primary)

            Text("クリップボードを倉庫として持ち歩く、3 つの呼び出し方")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
        }
        .padding(.top, 24)
    }

    private var shortcutStep: some View {
        VStack(spacing: 24) {
            HStack(spacing: 14) {
                KeyCap(label: "⇧")
                KeyCap(label: "⌘")
                KeyCap(label: "V")
            }
            .padding(.bottom, 4)

            Text("⇧⌘V で呼び出す")
                .font(.system(size: 24, weight: .semibold, design: .default))
                .foregroundStyle(.primary)

            Text("ストリップが下から立ち上がります。\n⌥⇧V で中央モーダル、ノッチに乗せれば上から降りてきます")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 50)
        }
        .padding(.top, 16)
    }

    private var folderStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "folder.fill")
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 4)

            Text("フォルダ＝倉庫で整理")
                .font(.system(size: 24, weight: .semibold, design: .default))
                .foregroundStyle(.primary)

            Text("色付きフォルダを好きなだけ作成。\n定型文や画像、リンクを分類して保存できます")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 60)
        }
        .padding(.top, 24)
    }

    // MARK: - Progress

    private var progressIndicator: some View {
        HStack(spacing: 10) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Circle()
                    .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.18), value: step)
            }
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack {
            if step > 0 {
                Button("戻る") {
                    if step > 0 { step -= 1 }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                // Keep symmetry
                Color.clear.frame(width: 80, height: 1)
            }

            Spacer()

            Button(primaryButtonTitle) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryButtonTitle: String {
        step == totalSteps - 1 ? "はじめる" : "次へ"
    }

    private func advance() {
        if step < totalSteps - 1 {
            step += 1
        } else {
            onComplete()
        }
    }
}

// MARK: - KeyCap

private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 36, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(width: 78, height: 78)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
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
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Pasty へようこそ"
        newWindow.contentViewController = hosting
        newWindow.isReleasedWhenClosed = false
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.center()

        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
        window = nil
    }
}
