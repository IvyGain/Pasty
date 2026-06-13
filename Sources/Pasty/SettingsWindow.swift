import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var pinboards: PinboardStore
    var store: ClipStore? = nil

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("一般", systemImage: "gear") }
            captureTab
                .tabItem { Label("キャプチャ", systemImage: "doc.on.clipboard") }
            uiTab
                .tabItem { Label("サーフェス", systemImage: "rectangle.3.group") }
            pinboardsTab
                .tabItem { Label("フォルダ", systemImage: "folder") }
            hotkeysTab
                .tabItem { Label("ショートカット", systemImage: "command") }
            insightsTab
                .tabItem { Label("インサイト", systemImage: "chart.bar") }
            privacyTab
                .tabItem { Label("プライバシー", systemImage: "lock.shield") }
            aboutTab
                .tabItem { Label("Pastyについて", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 460)
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
            Section("⇧⌘V で開くサーフェス") {
                Picker("⇧⌘V で開く", selection: $settings.primarySurface) {
                    ForEach(SettingsStore.PrimarySurface.allCases) { surface in
                        Label(surface.jpLabel, systemImage: surface.iconName).tag(surface)
                    }
                }
                .pickerStyle(.inline)
                Text("⌥⇧V でもう一方のサーフェスを開きます。どちらも同じ履歴・選択状態を共有します。ノッチホバーは別途、画面上端でいつでも有効です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Capture") {
                Toggle("Capture clipboard automatically", isOn: $settings.capturingEnabled)
                Toggle("Auto-paste after selecting an item", isOn: $settings.autoPaste)
                Stepper("Keep history for \(settings.maxRetentionDays) days",
                        value: $settings.maxRetentionDays, in: 1...365)
            }
            Section("Language") {
                Picker("", selection: $settings.locale) {
                    Text("Auto").tag("auto")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var captureTab: some View {
        Form {
            if settings.isPaused {
                Label("Capture is paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                Button("Resume now") { settings.resume() }
            } else {
                Button("Pause for 60 s")  { settings.pause(forSeconds: 60) }
                Button("Pause for 10 min") { settings.pause(forSeconds: 600) }
            }
            Divider()
            Text("Apps to ignore (bundle id)")
                .font(.headline)
            ForEach(Array(settings.ignoredBundleIds).sorted(), id: \.self) { id in
                HStack {
                    Text(id).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Remove") {
                        settings.ignoredBundleIds.remove(id)
                    }
                }
            }
            HStack {
                TextField("com.example.app", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                Button("Add front app") {
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

            Section("フィードバック") {
                Toggle("貼付完了トースト", isOn: $settings.toastEnabled)
                Toggle("Stack ピル表示", isOn: $settings.stackPillEnabled)
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
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var pinboardsTab: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(pinboards.boards) { board in
                    HStack {
                        Circle().fill(Color(hex: board.colorHex)).frame(width: 12, height: 12)
                        Text(board.name)
                        Spacer()
                        Button("Delete") {
                            guard let id = board.id else { return }
                            Task { try? await pinboards.delete(id: id) }
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            Button("New pinboard") {
                Task {
                    try? await pinboards.create(name: "Untitled", colorHex: "#7C8CF8")
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
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Pasty")
                .font(.title.weight(.semibold))
            Text("Open-source clipboard manager for macOS")
                .foregroundStyle(.secondary)
            Text("MIT License · github.com/IvyGain/Pasty")
                .font(.caption)
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

extension Notification.Name {
    static let pastyWipeAll = Notification.Name("pasty.wipeAll")
    static let pastyOpenSettings = Notification.Name("pasty.openSettings")
}
