import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var pinboards: PinboardStore
    var store: ClipStore? = nil

    @State private var selected: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, capture, ui, hotkeys, insights, privacy, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "一般"
            case .capture: return "キャプチャ"
            case .ui: return "サーフェス"
            case .hotkeys: return "ショートカット"
            case .insights: return "インサイト"
            case .privacy: return "プライバシー"
            case .about: return "Pastyについて"
            }
        }
        var systemImage: String {
            switch self {
            case .general: return "gear"
            case .capture: return "doc.on.clipboard"
            case .ui: return "rectangle.3.group"
            case .hotkeys: return "command"
            case .insights: return "chart.bar"
            case .privacy: return "lock.shield"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 4)
            }
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        }
        .frame(width: 720, height: 520)
        .background(VisualEffectBackground())
    }

    // 横並びの NSToolbar 風タブバー (System Settings 12 風)
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(
                    label: tab.label,
                    systemImage: tab.systemImage,
                    isSelected: selected == tab
                ) {
                    selected = tab
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .general: generalTab
        case .capture: captureTab
        case .ui: uiTab
        case .hotkeys: hotkeysTab
        case .insights: insightsTab
        case .privacy: privacyTab
        case .about: aboutTab
        }
    }

    @ViewBuilder
    private var hotkeysTab: some View {
        HotkeySettingsView()
    }

    @ViewBuilder
    private var insightsTab: some View {
        if let store {
            InsightsDashboard(store: store)
        } else {
            Text("インサイトを表示するには Pasty を再起動してください")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    private var generalTab: some View {
        Form {
            Section("呼び出し方") {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下部ストリップ").font(.system(size: 13, weight: .semibold))
                        Text("⇧⌘V / ⌥⇧V でいつでも呼び出せるメインサーフェス")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raycast 拡張で検索 (オプション)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Raycast から「Pasty」を呼ぶと、検索・連続貼付・複数選択ができます。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Raycast Store を開く") {
                            if let url = URL(string: "https://www.raycast.com/ivygain/pasty") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
            }
            Section("キャプチャ") {
                Toggle("クリップボードを自動キャプチャ", isOn: $settings.capturingEnabled)
                Toggle("アイテム選択後に自動で貼付", isOn: $settings.autoPaste)
            }
            Section("履歴保持期間") {
                let presets: [(label: String, value: Int)] = [
                    ("7 日", 7),
                    ("30 日", 30),
                    ("90 日", 90),
                    ("365 日", 365),
                    ("無期限", -1)
                ]
                HStack(spacing: 8) {
                    ForEach(presets, id: \.value) { preset in
                        Button {
                            settings.maxRetentionDays = preset.value
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 12, weight: settings.maxRetentionDays == preset.value ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(
                                    Capsule().fill(
                                        settings.maxRetentionDays == preset.value
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.primary.opacity(0.06)
                                    )
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        settings.maxRetentionDays == preset.value
                                            ? Color.accentColor.opacity(0.4)
                                            : .clear, lineWidth: 1
                                    )
                                )
                                .foregroundStyle(settings.maxRetentionDays == preset.value ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if settings.maxRetentionDays != -1 {
                    Stepper(value: $settings.maxRetentionDays, in: 1...3650, step: 1) {
                        HStack(spacing: 6) {
                            Text("カスタム:")
                                .foregroundStyle(.secondary)
                            Text("\(settings.maxRetentionDays) 日")
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 60, alignment: .leading)
                        }
                    }
                } else {
                    Label("無期限保持 — クリップは自動削除されません", systemImage: "infinity")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Text("プリセットボタンで素早く設定、または Stepper で日単位調整。「無期限」を選ぶと削除されません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("言語") {
                Picker("", selection: $settings.locale) {
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                    Text("自動").tag("auto")
                }
                .pickerStyle(.segmented)
            }

            Section("アクセシビリティ権限") {
                accessibilityStatusRow
                Text("Pasty は ⌘V を送出するためにアクセシビリティ権限が必要です。アプリを再ビルドすると古い権限が無効になる場合があります。その時は「リスト削除→再追加」を行ってください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        openAccessibilitySettings()
                    } label: {
                        Label("システム設定を開く", systemImage: "arrow.up.right.square")
                    }
                    Button {
                        resetAccessibilityPermission()
                    } label: {
                        Label("Pasty の権限をリセット", systemImage: "arrow.counterclockwise")
                    }
                    .help("ターミナルで `tccutil reset Accessibility io.pasty.app` を実行します (管理者パスワードが必要な場合あり)")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// 現在の権限ステータスを行で表示
    @ViewBuilder
    private var accessibilityStatusRow: some View {
        let trusted = AXIsProcessTrusted()
        HStack {
            Image(systemName: trusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(trusted ? .green : .red)
            Text(trusted ? "許可されています" : "許可されていません")
                .font(.system(size: 12, weight: .medium))
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    private func resetAccessibilityPermission() {
        // tccutil でこのアプリの Accessibility 許可を削除する。
        // 古い code signing hash の許可エントリも含めて消えるので、
        // 次回ペースト時に新規ダイアログが正しく出るようになる。
        let task = Process()
        task.launchPath = "/usr/bin/tccutil"
        task.arguments = ["reset", "Accessibility", "io.pasty.app"]
        do {
            try task.run()
            task.waitUntilExit()
            // 念のため再起動を促す
            let alert = NSAlert()
            alert.messageText = "権限をリセットしました"
            alert.informativeText = "Pasty を再起動すると次回ペースト時にダイアログが再表示されます。"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "リセットに失敗しました"
            alert.informativeText = "ターミナルで以下を実行してください:\ntccutil reset Accessibility io.pasty.app"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private var captureTab: some View {
        Form {
            if settings.isPaused {
                Label("キャプチャは一時停止中", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                Button("すぐに再開") { settings.resume() }
            } else {
                Button("60 秒間一時停止")  { settings.pause(forSeconds: 60) }
                Button("10 分間一時停止") { settings.pause(forSeconds: 600) }
            }
            Divider()
            Text("除外するアプリ (Bundle ID)")
                .font(.headline)
            ForEach(Array(settings.ignoredBundleIds).sorted(), id: \.self) { id in
                HStack {
                    Text(id).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("削除") {
                        settings.ignoredBundleIds.remove(id)
                    }
                }
            }
            HStack {
                TextField("com.example.app", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                Button("最前面のアプリを追加") {
                    if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                        settings.ignoredBundleIds.insert(id)
                    }
                }
            }
            Divider()
            autoCategorizerSection
        }
        .padding()
    }

    @ViewBuilder
    private var autoCategorizerSection: some View {
        Section("自動カテゴリ分類") {
            Text("コピーした内容を自動判定して、対応するフォルダに自動的に追加します")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AutoCategory.allCases) { cat in
                        AutoCategoryMappingRow(category: cat, pinboards: pinboards)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private var uiTab: some View {
        Form {
            Section("サーフェス") {
                Toggle("下部ストリップ (⌥⇧V)", isOn: $settings.stripPanelEnabled)
                Toggle("ノッチホバー", isOn: $settings.notchHoverEnabled)
                Text("ヒント: ノッチ（またはノッチなし Mac では画面上端中央）にカーソルを当てるとパネルが降りてきます。カードを下方向にドラッグするとマウスでペーストできます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("プレビュー") {
                Toggle("ホバープレビュー", isOn: $settings.hoverPreviewEnabled)
                Toggle("Explorer モード (分割ペイン) を常時 ON", isOn: $settings.explorerMode)
                Picker("プレビューフォントサイズ", selection: $settings.previewFontSize) {
                    ForEach(SettingsStore.PreviewFontSize.allCases) { size in
                        Text(size.jpLabel).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("貼付") {
                Toggle("マウス位置に自動でクリック→貼付", isOn: $settings.clickBeforePaste)
                Text("ON にすると、⇧⌘V で Pasty を呼んだ時にマウスがあった位置にキャレットを移してから貼り付けます。OFF だと従来通り、フォーカス中のテキスト入力欄の既存キャレット位置に貼ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("フィードバック") {
                Toggle("貼付完了トースト", isOn: $settings.toastEnabled)
                Toggle("Stack ピル表示", isOn: $settings.stackPillEnabled)
                Text("トーストはマウスカーソル付近に表示されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI") {
                HStack {
                    Text("Apple Intelligence (Foundation Models)")
                    Spacer()
                    if AIEngine.isFoundationModelsAvailable {
                        Label("利用可能", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("利用不可", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if !AIEngine.isFoundationModelsAvailable {
                    Text("macOS 26 以降 + Apple Intelligence が必要です")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("完了音を鳴らす", isOn: $settings.aiSoundEnabled)
                if settings.aiSoundEnabled {
                    Picker("完了音", selection: $settings.aiSoundName) {
                        ForEach(["Glass", "Tink", "Pop", "Ping", "Sosumi", "Submarine"], id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Button("試聴") {
                        NSSound(named: NSSound.Name(settings.aiSoundName))?.play()
                    }
                    .controlSize(.small)
                }

                Toggle("画面端グロー (青パルス / 緑成功 / 赤失敗)", isOn: $settings.aiGlowEnabled)
                if settings.aiGlowEnabled {
                    HStack(spacing: 8) {
                        Button("プレビュー: 成功") {
                            ScreenGlowController.shared.showSuccess()
                        }
                        .controlSize(.small)
                        Button("プレビュー: 失敗") {
                            ScreenGlowController.shared.showFailure()
                        }
                        .controlSize(.small)
                    }
                }

                aiPromptSection
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var aiPromptSection: some View {
        DisclosureGroup("カスタムプロンプト (文体ガイド + メールテンプレ)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("文体ガイド (全 AI アクションに適用)")
                    .font(.caption.weight(.semibold))
                TextEditor(text: $settings.aiStyleGuide)
                    .font(.system(size: 12))
                    .frame(minHeight: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                Text("例: 常に丁寧語で。一文を短く。専門用語には括弧で平易な言い換えを添える。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("メールテンプレート (⌃⇧L 専用)")
                    .font(.caption.weight(.semibold))
                TextEditor(text: $settings.aiEmailTemplate)
                    .font(.system(size: 12))
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                Text("`{{body}}` をテンプレ内に書いておくと、整形後の本文がそこに差し込まれます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Button("ビジネス標準") {
                        settings.aiEmailTemplate = Self.emailPresetBusiness
                    }
                    .controlSize(.small)
                    Button("社内向け") {
                        settings.aiEmailTemplate = Self.emailPresetInternal
                    }
                    .controlSize(.small)
                    Button("フォーマル (英)") {
                        settings.aiEmailTemplate = Self.emailPresetFormalEnglish
                    }
                    .controlSize(.small)
                    Button("カジュアル") {
                        settings.aiEmailTemplate = Self.emailPresetCasual
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 4)
    }

    private static let emailPresetBusiness = """
    お世話になっております。〔差出人名〕です。

    {{body}}

    お手数をおかけしますが、何卒よろしくお願いいたします。

    〔差出人名〕
    〔会社名 / 部署〕
    """

    private static let emailPresetInternal = """
    お疲れさまです。〔差出人名〕です。

    {{body}}

    引き続き、どうぞよろしくお願いいたします。
    〔差出人名〕
    """

    private static let emailPresetFormalEnglish = """
    Dear 〔Recipient〕,

    {{body}}

    Sincerely,
    〔Your Name〕
    """

    private static let emailPresetCasual = """
    お疲れさま！

    {{body}}

    よろしくお願いします〜
    """

    private var pinboardsTab: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(pinboards.boards) { board in
                    HStack {
                        Circle().fill(Color(hex: board.colorHex)).frame(width: 12, height: 12)
                        Text(board.name)
                        Spacer()
                        Button("削除") {
                            guard let id = board.id else { return }
                            Task { try? await pinboards.delete(id: id) }
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            Button("新しいフォルダを作成") {
                Task {
                    try? await pinboards.create(name: "新しいフォルダ", colorHex: "#7C8CF8")
                }
            }
        }
        .padding()
    }

    private var privacyTab: some View {
        Form {
            Section("ローカルファースト") {
                Text("Pasty はすべてのデータをこの Mac だけに保存します。クラウドアカウント、テレメトリ、解析は一切ありません。")
                    .font(.callout)
                Button("Application Support フォルダを開く") {
                    if let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                        NSWorkspace.shared.open(appSupport.appendingPathComponent("Pasty"))
                    }
                }
            }

            Section("バックアップと引っ越し") {
                Button("全クリップを JSON でエクスポート") {
                    if let store {
                        Task {
                            _ = try? await ImportExportManager.shared.exportWithSavePanel(
                                store: store, pinboards: pinboards)
                        }
                    }
                }
                Button("JSON からインポート") {
                    if let store {
                        Task {
                            _ = try? await ImportExportManager.shared.importWithOpenPanel(
                                store: store, pinboards: pinboards,
                                conflictPolicy: .skipDuplicates)
                        }
                    }
                }
            }

            Section("削除") {
                Button("すべての履歴を削除", role: .destructive) {
                    NotificationCenter.default.post(name: .pastyWipeAll, object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Pasty")
                .font(.title.weight(.semibold))
            Text("オープンソースの macOS クリップボードマネージャ")
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    OnboardingPresenter.shared.presentForce { }
                } label: {
                    Label("使い方を見る", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    HelpOverlayPresenter.shared.toggle()
                } label: {
                    Label("ショートカット一覧 (⌘?)", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    SparkleUpdater.shared.checkForUpdates()
                } label: {
                    Label("アップデートを確認", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 6)

            Text("MIT License · github.com/IvyGain/Pasty")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

@MainActor
private struct AutoCategoryMappingRow: View {
    let category: AutoCategory
    @ObservedObject var pinboards: PinboardStore
    @State private var selection: Int64? = nil

    var body: some View {
        HStack {
            Image(systemName: category.systemImage)
                .frame(width: 18)
            Text(category.japaneseLabel)
            Spacer()
            Picker("", selection: $selection) {
                Text("自動分類しない").tag(Int64?.none)
                ForEach(pinboards.boards) { board in
                    if let bid = board.id {
                        Text(board.name).tag(Int64?.some(bid))
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .onAppear {
                selection = AutoCategorizer.shared.mapping[category]
            }
            .onChange(of: selection) { newValue in
                var m = AutoCategorizer.shared.mapping
                if let v = newValue {
                    m[category] = v
                } else {
                    m.removeValue(forKey: category)
                }
                AutoCategorizer.shared.mapping = m
            }
        }
    }
}

@MainActor
private struct SettingsTabButton: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 22)
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .tracking(-0.05)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.14)
                          : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.32) : .clear,
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension Notification.Name {
    static let pastyNotchCycleFolderForward  = Notification.Name("pasty.notchCycleFolder.fwd")
    static let pastyNotchCycleFolderBackward = Notification.Name("pasty.notchCycleFolder.bwd")
    static let pastyDragTargetHovered        = Notification.Name("pasty.drag.targetHovered")
    static let pastyDragTargetUnhovered      = Notification.Name("pasty.drag.targetUnhovered")
    static let pastyWipeAll = Notification.Name("pasty.wipeAll")
    static let pastyOpenSettings = Notification.Name("pasty.openSettings")
}
