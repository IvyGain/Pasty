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
            Divider()
            perAppRetentionSection
            Divider()
            ocrSection
        }
        .padding()
    }

    @ViewBuilder
    private var perAppRetentionSection: some View {
        Section("アプリ別保持期間") {
            Text("特定のアプリからのコピーは別の期間で保持できます (グローバル設定をオーバーライド)")
                .font(.caption)
                .foregroundStyle(.secondary)
            PerAppRetentionEditor(settings: settings)
        }
    }

    @ViewBuilder
    private var ocrSection: some View {
        Section("画像から自動でテキスト抽出") {
            Text("画像クリップを取り込んだ直後に Vision OCR でテキストを抽出し、検索ヒット可能にします")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("画像 OCR を有効化", isOn: $settings.autoTagOCRImages)
            if settings.autoTagOCRImages {
                OCRLanguageEditor(settings: settings)
                // v0.9.6-beta P0 #9: OCR テキスト内の機密データ (CC / SSN /
                // マイナンバー / 電話 / API トークン / IBAN) を保存前にマスク。
                Toggle("機密データ自動マスク (CC / 身分証 / API トークン)", isOn: $settings.redactOCRSensitiveData)
                    .padding(.leading, 18)
                Text("クレジットカード番号や身分証番号などをプレースホルダに置換してから DB に保存します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
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
        Section("カスタムルール (デフォルト判定より優先)") {
            Text("ルールが上から順に評価され、最初に一致したものが適用されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            CustomRulesEditor(pinboards: pinboards)
        }
    }

    private var uiTab: some View {
        Form {
            Section("サーフェス") {
                Toggle("下部ストリップ (⌥⇧V)", isOn: $settings.stripPanelEnabled)
                Toggle("ノッチホバー", isOn: $settings.notchHoverEnabled)
                Toggle("ホイールで横スクロール", isOn: $settings.notchScrollWheelEnabled)
                Toggle("URL プレビュー (軽量フェッチ)", isOn: $settings.urlPreviewEnabled)
                if settings.urlPreviewEnabled {
                    Toggle("URL favicon を取得", isOn: $settings.urlPreviewFaviconEnabled)
                        .padding(.leading, 18)
                }
                Picker("ノッチ起動遅延", selection: $settings.notchDwellMs) {
                    Text("0ms (即時)").tag(0)
                    Text("50ms").tag(50)
                    Text("100ms").tag(100)
                    Text("200ms").tag(200)
                }
                .pickerStyle(.segmented)
                Picker("ノッチアニメ", selection: $settings.notchAnimMs) {
                    Text("0ms (瞬間表示)").tag(0)
                    Text("60ms").tag(60)
                    Text("120ms").tag(120)
                }
                .pickerStyle(.segmented)
                Text("ヒント: ノッチ（またはノッチなし Mac では画面上端中央）にカーソルを当てるとパネルが降りてきます。「起動遅延 0ms + アニメ 0ms」で瞬間表示になります。誤発火が気になる場合は 50ms / 100ms に上げてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("URL プレビューを ON にすると、リンククリップのカードに LinkPresentation 経由でタイトル + ファビコンを表示します (キャッシュあり)。ネットワーク発火を避けたい場合は OFF。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("検索とフィルタ") {
                Toggle("ストリップの検索クエリとフィルタを記憶", isOn: $settings.stripRememberFilters)
                Text("ON にすると、ストリップを開き直しても直前の検索文字列と種類フィルタが復元されます。")
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

            Section("ホバープレビュー") {
                Toggle("PDF プレビュー (1 ページ目サムネ)", isOn: $settings.hoverPreviewPDFEnabled)
                    .disabled(!settings.hoverPreviewEnabled)
                Toggle("動画プレビュー (0:00 サムネ)", isOn: $settings.hoverPreviewVideoEnabled)
                    .disabled(!settings.hoverPreviewEnabled)
                Text("ファイルクリップにホバーした際、PDF や動画の先頭フレームをプレビューに描画します。「ホバープレビュー」が OFF のときは無効です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("iCloud 同期 (実験的・未実装)") {
                Toggle("iCloud 同期を有効化", isOn: $settings.cloudSyncEnabled)
                    .disabled(true)
                Text("複数の Mac 間で履歴を同期する機能の設計フェーズが完了しました。実装は v0.9 で予定されています。詳細は .ai/decisions/c1-icloud-sync-*.md を参照してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            // v0.8.6: 開発者向けの perf 計測フラグ。Console.app で subsystem
            // `io.pasty.perf` を絞ると ⇧⌘V / ノッチ展開 / ClipStore 初期化の
            // 所要時間が flat な行で出てくる。デフォルト OFF (オーバーヘッド 0)。
            Section("診断") {
                Toggle("パフォーマンスログを記録 (Console.app で io.pasty.perf を確認)",
                       isOn: $settings.perfLogEnabled)
                Text("ホットパス (ノッチ展開・ストリップ表示・ClipStore 初期化) の所要時間を NSLog と unified log に記録します。問題報告のときだけ ON にしてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var aboutTab: some View {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return VStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Pasty")
                .font(.title.weight(.semibold))
            Text("オープンソースの macOS クリップボードマネージャ")
                .foregroundStyle(.secondary)

            // Version badge — クリックでバージョン文字列をコピー
            Button {
                let payload = "Pasty v\(short) (build \(build))"
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(payload, forType: .string)
                PasteToast.shared.show(targetApp: nil, customMessage: "バージョン情報をコピーしました")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
                    Text("v\(short) · build \(build)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.primary.opacity(0.07))
                )
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("クリックでバージョン文字列をコピー")
            .padding(.top, 4)
            .padding(.bottom, 6)

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

                Button {
                    WhatsNewPresenter.shared.presentForce()
                } label: {
                    Label("リリースノート", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 6)

            Text("MIT License · github.com/IvyGain/Pasty")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            SnippetCounterEditor(settings: settings)
                .padding(.top, 10)
                .frame(maxWidth: 480)

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

// MARK: - A7: Custom Category Rules Editor

@MainActor
private struct CustomRulesEditor: View {
    @ObservedObject var pinboards: PinboardStore
    @State private var rules: [CustomCategoryRule] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rules) { $rule in
                ruleRow($rule)
            }
            if rules.isEmpty {
                Text("ルールはまだありません")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
            HStack {
                Button {
                    addNewRule()
                } label: {
                    Label("新しいルール", systemImage: "plus.circle")
                }
                .disabled(rules.count >= AutoCategorizer.maxCustomRules)
                Spacer()
                if rules.count >= AutoCategorizer.maxCustomRules {
                    Text("上限: \(AutoCategorizer.maxCustomRules) 件").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .onAppear { rules = AutoCategorizer.shared.customRules }
        .onChange(of: rules) { _, newValue in
            AutoCategorizer.shared.customRules = newValue
        }
    }

    private func ruleRow(_ rule: Binding<CustomCategoryRule>) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: rule.enabled).labelsHidden()
            TextField("ラベル", text: rule.label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Picker("", selection: Binding(
                get: { rule.wrappedValue.condition.kind },
                set: { newKind in
                    let current = rule.wrappedValue.condition
                    let str = current.stringValue
                    switch newKind {
                    case .contentContains: rule.wrappedValue.condition = .contentContains(str)
                    case .domainContains:  rule.wrappedValue.condition = .domainContains(str)
                    case .sourceApp:       rule.wrappedValue.condition = .sourceApp(str)
                    case .kindIs:          rule.wrappedValue.condition = .kindIs(ClipKind(rawValue: str) ?? .text)
                    }
                }
            )) {
                ForEach(RuleCondition.Kind.allCases) { k in
                    Text(k.japaneseLabel).tag(k)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            conditionValueField(rule)
                .frame(maxWidth: .infinity)
            Picker("", selection: Binding(
                get: { rule.wrappedValue.pinboardId },
                set: { rule.wrappedValue.pinboardId = $0 }
            )) {
                ForEach(pinboards.boards) { board in
                    if let bid = board.id {
                        Text(board.name).tag(bid)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Button(role: .destructive) {
                if let idx = rules.firstIndex(where: { $0.id == rule.wrappedValue.id }) {
                    rules.remove(at: idx)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("このルールを削除")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func conditionValueField(_ rule: Binding<CustomCategoryRule>) -> some View {
        switch rule.wrappedValue.condition {
        case .contentContains, .domainContains, .sourceApp:
            TextField("値", text: Binding(
                get: { rule.wrappedValue.condition.stringValue },
                set: { newVal in
                    switch rule.wrappedValue.condition {
                    case .contentContains: rule.wrappedValue.condition = .contentContains(newVal)
                    case .domainContains:  rule.wrappedValue.condition = .domainContains(newVal)
                    case .sourceApp:       rule.wrappedValue.condition = .sourceApp(newVal)
                    case .kindIs:          break
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
        case .kindIs:
            Picker("", selection: Binding(
                get: {
                    if case .kindIs(let k) = rule.wrappedValue.condition { return k }
                    return ClipKind.text
                },
                set: { rule.wrappedValue.condition = .kindIs($0) }
            )) {
                ForEach(ClipKind.allCases, id: \.self) { k in
                    Text(k.rawValue).tag(k)
                }
            }
            .labelsHidden()
        }
    }

    private func addNewRule() {
        guard rules.count < AutoCategorizer.maxCustomRules,
              let firstBoardId = pinboards.boards.first?.id else { return }
        rules.append(CustomCategoryRule(
            label: "新規ルール",
            condition: .contentContains(""),
            pinboardId: firstBoardId
        ))
    }
}

// MARK: - v0.9.5-beta: Per-App Retention Editor (B3)

@MainActor
private struct PerAppRetentionEditor: View {
    @ObservedObject var settings: SettingsStore
    @State private var manualBundleId: String = ""
    @State private var showingManualInput: Bool = false

    /// 表示 / 保存上の選択肢。`-1` = 無期限。
    private static let dayPresets: [(label: String, value: Int)] = [
        ("1 日", 1),
        ("7 日", 7),
        ("30 日", 30),
        ("90 日", 90),
        ("365 日", 365),
        ("無期限", -1)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.perAppRetentionRules.isEmpty {
                Text("ルールはまだありません。グローバル保持期間 (一般タブ) が全アプリに適用されます。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(settings.perAppRetentionRules) { rule in
                    ruleRow(rule)
                }
            }

            HStack(spacing: 8) {
                Button {
                    addFrontmostApp()
                } label: {
                    Label("最前面のアプリを追加", systemImage: "macwindow.badge.plus")
                }
                Button {
                    showingManualInput.toggle()
                    manualBundleId = ""
                } label: {
                    Label("Bundle ID を手入力", systemImage: "keyboard")
                }
            }
            .padding(.top, 4)

            if showingManualInput {
                HStack(spacing: 6) {
                    TextField("com.example.app", text: $manualBundleId)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Button("追加") {
                        let trimmed = manualBundleId.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        addRule(bundleId: trimmed, displayName: nil)
                        manualBundleId = ""
                        showingManualInput = false
                    }
                    .disabled(manualBundleId.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("キャンセル") {
                        manualBundleId = ""
                        showingManualInput = false
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: PerAppRetentionRule) -> some View {
        HStack(spacing: 8) {
            appIcon(for: rule.bundleId)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.displayName ?? friendlyName(for: rule.bundleId))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(rule.bundleId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Picker("", selection: bindingForDays(rule)) {
                ForEach(Self.dayPresets, id: \.value) { preset in
                    Text(preset.label).tag(preset.value)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Button(role: .destructive) {
                removeRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("このルールを削除")
        }
        .padding(.vertical, 2)
    }

    // MARK: helpers

    private func bindingForDays(_ rule: PerAppRetentionRule) -> Binding<Int> {
        Binding(
            get: { rule.days },
            set: { newValue in
                guard let idx = settings.perAppRetentionRules.firstIndex(where: { $0.id == rule.id }) else { return }
                settings.perAppRetentionRules[idx].days = newValue
            }
        )
    }

    private func addFrontmostApp() {
        let workspace = NSWorkspace.shared
        // Settings ウィンドウ自身が最前面の場合は、Pasty 自身を除外。
        guard let app = workspace.frontmostApplication,
              let bundleId = app.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier else {
            // Fallback: 候補一覧を表示 (今回はシンプルに手入力導線にフォールバック)
            showingManualInput = true
            return
        }
        let displayName = app.localizedName
        addRule(bundleId: bundleId, displayName: displayName)
    }

    private func addRule(bundleId: String, displayName: String?) {
        if settings.perAppRetentionRules.contains(where: { $0.bundleId == bundleId }) {
            return
        }
        settings.perAppRetentionRules.append(
            PerAppRetentionRule(
                bundleId: bundleId,
                displayName: displayName,
                days: 30
            )
        )
    }

    private func removeRule(id: String) {
        settings.perAppRetentionRules.removeAll { $0.id == id }
    }

    @ViewBuilder
    private func appIcon(for bundleId: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private func friendlyName(for bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: url),
           let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String) {
            return name
        }
        return bundleId.components(separatedBy: ".").last ?? bundleId
    }
}

// MARK: - v0.9.5-beta: OCR Language Editor (B6)

@MainActor
private struct OCRLanguageEditor: View {
    @ObservedObject var settings: SettingsStore
    @State private var pendingLanguage: String = "ja-JP"

    /// Vision が広くサポートする BCP-47 言語タグの代表。
    private static let availableLanguages: [(tag: String, label: String)] = [
        ("ja-JP", "日本語 (ja-JP)"),
        ("en-US", "English US (en-US)"),
        ("en-GB", "English UK (en-GB)"),
        ("zh-Hans", "中文 簡体 (zh-Hans)"),
        ("zh-Hant", "中文 繁體 (zh-Hant)"),
        ("ko-KR", "한국어 (ko-KR)"),
        ("fr-FR", "Français (fr-FR)"),
        ("de-DE", "Deutsch (de-DE)"),
        ("es-ES", "Español (es-ES)"),
        ("it-IT", "Italiano (it-IT)"),
        ("pt-BR", "Português BR (pt-BR)")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("認識言語")
                .font(.caption.weight(.semibold))

            // 現在登録済みの言語タグを chip 表示。
            FlowChipsView(
                items: settings.ocrLanguages,
                onRemove: { tag in
                    settings.ocrLanguages.removeAll { $0 == tag }
                }
            )

            HStack(spacing: 6) {
                Picker("", selection: $pendingLanguage) {
                    ForEach(Self.availableLanguages, id: \.tag) { lang in
                        Text(lang.label).tag(lang.tag)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Button("追加") {
                    addLanguage(pendingLanguage)
                }
                .disabled(settings.ocrLanguages.contains(pendingLanguage))
            }
            Text("上位の言語ほど優先されます。1 つ以上残してください。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func addLanguage(_ tag: String) {
        guard !settings.ocrLanguages.contains(tag) else { return }
        settings.ocrLanguages.append(tag)
    }
}

/// 単純な横並び chip ビュー (削除ボタン付き)。SwiftUI の `Layout` を避けて
/// 視覚的に折り返す軽量実装。並列で触っているファイルを増やしたくないので
/// この場で完結させる。
@MainActor
private struct FlowChipsView: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        if items.isEmpty {
            Text("(言語が登録されていません)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            // VStack + HStack で折り返し相当を実現。3 列固定で十分。
            let columns = 3
            let rows = items.chunked(into: columns)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<rows.count, id: \.self) { rowIdx in
                    HStack(spacing: 6) {
                        ForEach(rows[rowIdx], id: \.self) { tag in
                            chip(tag)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 11, design: .monospaced))
            Button {
                onRemove(tag)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("\(tag) を削除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.primary.opacity(0.07))
        )
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - v0.9.5-beta: Snippet Counter Editor (B9)

@MainActor
private struct SnippetCounterEditor: View {
    @ObservedObject var settings: SettingsStore
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("{{counter:name}} で参照される永続カウンタの一覧 + リセット")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.snippetCounters.isEmpty {
                    Text("カウンタはまだ使用されていません。スニペットで {{counter:invoice}} のように参照すると、ここに表示されます。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    let sortedKeys = settings.snippetCounters.keys.sorted()
                    ForEach(sortedKeys, id: \.self) { name in
                        counterRow(name: name, value: settings.snippetCounters[name] ?? 0)
                    }

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            resetAll()
                        } label: {
                            Label("全てリセット", systemImage: "arrow.counterclockwise.circle")
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .foregroundStyle(.tint)
                Text("スニペットカウンタ")
                    .font(.system(size: 12, weight: .medium))
                if !settings.snippetCounters.isEmpty {
                    Text("(\(settings.snippetCounters.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func counterRow(name: String, value: Int) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(minWidth: 40, alignment: .trailing)
                .foregroundStyle(.primary)
            Button("リセット") {
                resetOne(name: name)
            }
            .controlSize(.small)
            Button(role: .destructive) {
                removeOne(name: name)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("\(name) を削除")
        }
        .padding(.vertical, 1)
    }

    private func resetOne(name: String) {
        settings.snippetCounters[name] = 0
    }

    private func removeOne(name: String) {
        settings.snippetCounters.removeValue(forKey: name)
    }

    private func resetAll() {
        for key in settings.snippetCounters.keys {
            settings.snippetCounters[key] = 0
        }
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
