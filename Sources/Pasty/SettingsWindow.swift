import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var pinboards: PinboardStore

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            captureTab
                .tabItem { Label("Capture", systemImage: "doc.on.clipboard") }
            uiTab
                .tabItem { Label("Surfaces", systemImage: "rectangle.3.group") }
            pinboardsTab
                .tabItem { Label("Pinboards", systemImage: "pin") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
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
        }
        .padding()
    }

    private var uiTab: some View {
        Form {
            Toggle("Bottom strip (⌥⇧V)", isOn: $settings.stripPanelEnabled)
            Toggle("Notch-hover dropdown", isOn: $settings.notchHoverEnabled)
            Text("Tip: hover the notch (or top-centre on non-notched Macs) to slide the panel down. Drag a card downward to paste with the mouse.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            Text("Pasty keeps everything on this Mac. There is no cloud account, no telemetry, and no analytics by default.")
                .font(.callout)
            Divider()
            Button("Open Application Support folder") {
                if let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                    NSWorkspace.shared.open(appSupport.appendingPathComponent("Pasty"))
                }
            }
            Button("Wipe all clips") {
                // Note: ClipStore is wired up at the app level; an action
                // command/notification could trigger the wipe.
                NotificationCenter.default.post(name: .pastyWipeAll, object: nil)
            }
            .foregroundStyle(.red)
        }
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

extension Notification.Name {
    static let pastyWipeAll = Notification.Name("pasty.wipeAll")
    static let pastyOpenSettings = Notification.Name("pasty.openSettings")
}
