import SwiftUI

@MainActor
struct HotkeySettingsView: View {
    @ObservedObject var store = HotkeyStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("グローバルショートカット")
                    .font(.headline)
                Text("各アクションの右側をクリックして、新しいキーを 1 回押すと記録されます。Esc でキャンセル、Delete で「設定なし」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Image(systemName: actionIcon(action))
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.japaneseLabel).font(.callout)
                            Text(action.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HotkeyRecorderField(
                            descriptor: Binding(
                                get: { store.descriptor(for: action) },
                                set: { store.update(action, to: $0) }
                            )
                        )
                        .frame(width: 160)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.4)
                }

                HStack {
                    Spacer()
                    Button("デフォルトに戻す") { store.resetAll() }
                        .controlSize(.small)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private func actionIcon(_ a: HotkeyAction) -> String {
        switch a {
        case .primarySurface:   return "rectangle.bottomthird.inset.filled"
        case .secondarySurface: return "rectangle.center.inset.filled"
        case .pauseCapture:     return "pause.circle"
        case .undoPaste:        return "arrow.uturn.backward.circle"
        case .aiRewrite:        return "pencil.and.scribble"
        case .aiTranslate:      return "globe"
        case .aiSummarize:      return "text.append"
        case .aiReformat:       return "arrow.left.arrow.right"
        case .aiEmailify:       return "envelope"
        }
    }
}
