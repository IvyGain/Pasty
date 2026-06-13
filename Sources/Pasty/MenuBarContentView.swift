import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var pinboards: PinboardStore
    @ObservedObject var observer: PasteboardObserver
    @ObservedObject var coordinator: PanelCoordinator
    @ObservedObject var settings: SettingsStore
    @Environment(\.openSettings) private var openSettings

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            actions
            Divider()
            if store.recent.isEmpty {
                emptyState
            } else {
                clipList
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.tint)
            Text("Pasty").font(.headline)
            Spacer()
            Text("\(store.totalCount) clips")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(title: "Search…  ⇧⌘V", systemImage: "magnifyingglass") {
                coordinator.showSpotlight()
            }
            row(title: "Strip…  ⌥⇧V", systemImage: "rectangle.bottomthird.inset.filled") {
                coordinator.showStrip()
            }
            row(title: settings.isPaused ? "Resume capture" : "Pause capture for 60 s",
                systemImage: settings.isPaused ? "play.circle" : "pause.circle") {
                if settings.isPaused {
                    settings.resume()
                } else {
                    settings.pause(forSeconds: 60)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func row(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.tint)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Copy something to begin")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var clipList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.recent.prefix(10)) { clip in
                    Button(action: { paste(clip) }) {
                        ClipRow(clip: clip, timeFormatter: Self.timeFormatter)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(settings.isPaused ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(settings.isPaused ? "Paused" : "Watching")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.top, 6)
    }

    private func paste(_ clip: ClipItem) {
        PasteAutomator.shared.paste(clip, autoPaste: settings.autoPaste)
    }
}

private struct ClipRow: View {
    let clip: ClipItem
    let timeFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: clip.kind.iconName)
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.preview)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(clip.kind.rawValue.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let app = clip.sourceAppName {
                        Text("· \(app)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(timeFormatter.string(from: clip.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
