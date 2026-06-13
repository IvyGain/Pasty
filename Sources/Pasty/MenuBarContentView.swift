import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var pinboards: PinboardStore
    @ObservedObject var observer: PasteboardObserver
    @ObservedObject var coordinator: PanelCoordinator
    @ObservedObject var settings: SettingsStore
    @ObservedObject var selection: SelectionModel
    @Environment(\.openSettings) private var openSettings

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var visibleClips: [ClipItem] { Array(store.recent.prefix(10)) }

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
            if selection.hasSelection {
                Divider()
                multiSelectBar
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .padding(.vertical, 6)
        .onAppear { selection.clearAll() }
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
            let primary = settings.primarySurface
            row(title: "\(primary == .spotlight ? "Spotlight" : "Strip")…  ⇧⌘V",
                systemImage: primary.iconName) {
                coordinator.togglePrimary()
            }
            row(title: "\(primary == .spotlight ? "Strip" : "Spotlight")…  ⌥⇧V",
                systemImage: (primary == .spotlight
                              ? SettingsStore.PrimarySurface.strip.iconName
                              : SettingsStore.PrimarySurface.spotlight.iconName)) {
                coordinator.toggleSecondary()
            }
            row(title: settings.isPaused ? "Resume capture" : "Pause capture for 60 s",
                systemImage: settings.isPaused ? "play.circle" : "pause.circle") {
                if settings.isPaused { settings.resume() }
                else                  { settings.pause(forSeconds: 60) }
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
        VStack(alignment: .leading, spacing: 0) {
            if selection.multiMode {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.tint).font(.caption)
                    Text("Multi-select: click to toggle · ⇧-click for range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleClips.enumerated()), id: \.element.id) { idx, clip in
                        ClipRow(
                            clip: clip,
                            timeFormatter: Self.timeFormatter,
                            isSelected: selection.isSelected(clip.id ?? -1),
                            multiMode: selection.multiMode
                        )
                        .onTapGesture {
                            handleTap(at: idx, modifiers: CurrentInput.modifierFlags)
                        }
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private var multiSelectBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text("\(selection.count) selected").font(.callout.weight(.medium))
            Spacer()
            Button("Each") { pasteSelected(join: false) }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Joined") { pasteSelected(join: true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                selection.clearAll()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
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

    // MARK: - Tap routing

    private func handleTap(at index: Int, modifiers: NSEvent.ModifierFlags) {
        // Shift-click：範囲選択
        if modifiers.contains(.shift) {
            selection.shiftTap(at: index, in: visibleClips)
            return
        }
        // ⌘-click：個別トグル
        if modifiers.contains(.command) {
            selection.commandTap(at: index, in: visibleClips)
            return
        }
        // 通常クリック
        let result = selection.tap(at: index, in: visibleClips)
        switch result {
        case .pasteSingle(let clip):
            PasteAutomator.shared.paste(clip, autoPaste: settings.autoPaste)
        case .toggled, .noop: break
        }
    }

    private func pasteSelected(join: Bool) {
        let items = selection.selectedItems(from: visibleClips)
        guard !items.isEmpty else { return }
        selection.clearAll()
        if join {
            PasteAutomator.shared.pasteSequence(
                items, strategy: .join(separator: "\n"))
        } else {
            PasteAutomator.shared.pasteSequence(
                items, strategy: .sequence(delayBetween: 0.12))
        }
    }
}

private struct ClipRow: View {
    let clip: ClipItem
    let timeFormatter: DateFormatter
    let isSelected: Bool
    let multiMode: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if multiMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
            } else {
                Image(systemName: clip.kind.iconName)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
            }
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
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
    }
}

