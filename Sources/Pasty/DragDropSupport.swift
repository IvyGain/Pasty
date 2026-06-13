import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// 「履歴のクリップカード」を「フォルダタブ」に投げ込むための持ち運び型。
/// 単なる文字列ドラッグ (既存 `.draggable(clip.content)`) では「どのクリップ
/// だったか」を受け側が復元できないので、`clipId` を本人確認として運ぶ。
/// 一緒にプレビュー文字列も持って、別アプリへドロップした場合は素のテキスト
/// として落ちるよう `proposedRepresentation` でフォールバックも用意する。
struct ClipReference: Codable, Transferable {
    let clipId: Int64
    let preview: String
    let kindRaw: String

    init(clip: ClipItem) {
        self.clipId = clip.id ?? -1
        self.preview = clip.preview
        self.kindRaw = clip.kind.rawValue
    }

    static var transferRepresentation: some TransferRepresentation {
        // 1) Pasty 内で受けたい時は CodableRepresentation で復元可能。
        CodableRepresentation(contentType: .pastyClipReference)
        // 2) 外部アプリ (TextEdit, メモ, Slack…) に落とした時は素のテキスト。
        ProxyRepresentation(exporting: \.preview)
    }
}

extension UTType {
    /// Pasty 内のクリップ参照を運ぶための独自 UTI。
    /// Info.plist 登録はオプション（同一アプリ内のドラッグでは declaringId なくても効く）。
    static var pastyClipReference: UTType {
        UTType(exportedAs: "io.pasty.clip-reference")
    }
}

// MARK: - Folder tab drop receiver

/// 任意の View に「クリップ参照を投げ込まれたら指定フォルダに pin する」
/// ドロップターゲットを生やすモディファイア。
@MainActor
struct ClipReceiveDropTarget: ViewModifier {
    let pinboardId: Int64?               // nil = 何もしない（「履歴」タブなど）
    let pinboards: PinboardStore
    let store: ClipStore
    let visualFeedback: Bool

    @State private var isTargeted: Bool = false

    func body(content: Content) -> some View {
        content
            // ホバー中はカラフルなアクセント枠 + 軽い拡大で「ここに落とせる」を明示
            .scaleEffect(isTargeted ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.18) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : .clear,
                        style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [4, 3] : [])
                    )
                    .opacity(visualFeedback ? 1 : 0)
            )
            .dropDestination(for: ClipReference.self) { items, _ in
                guard let pid = pinboardId, !items.isEmpty else { return false }
                let boardName = pinboards.boards.first { $0.id == pid }?.name ?? "フォルダ"
                Task { @MainActor in
                    var added = 0
                    for ref in items where ref.clipId > 0 {
                        do {
                            try await pinboards.pin(clipId: ref.clipId, toBoard: pid)
                            added += 1
                        } catch {
                            NSLog("pin failed: \(error)")
                        }
                    }
                    let msg: String
                    if added == 1 {
                        msg = "📌 \(boardName) に定型文として保存"
                    } else if added > 1 {
                        msg = "📌 \(boardName) に \(added) 件を保存"
                    } else {
                        msg = "保存に失敗しました"
                    }
                    PasteToast.shared.show(targetApp: nil, customMessage: msg)
                    _ = store
                }
                return true
            } isTargeted: { hovering in
                isTargeted = hovering
            }
    }
}

extension View {
    /// `pinboardId` が non-nil の時、クリップ参照のドラッグ&ドロップで pin。
    @MainActor
    func acceptClipReferenceDrop(pinboardId: Int64?,
                                 pinboards: PinboardStore,
                                 store: ClipStore,
                                 visualFeedback: Bool = true) -> some View {
        modifier(ClipReceiveDropTarget(
            pinboardId: pinboardId,
            pinboards: pinboards,
            store: store,
            visualFeedback: visualFeedback
        ))
    }
}

// MARK: - External text/url drop → new clip

/// 外部アプリからのテキスト/URL/ファイルをドロップしたら新規クリップとして
/// 保存し、可能ならフォルダに pin する複合ドロップターゲット。
@MainActor
struct ExternalDropAddClip: ViewModifier {
    let pinboardId: Int64?
    let store: ClipStore
    let pinboards: PinboardStore?

    func body(content: Content) -> some View {
        content.onDrop(of: [.plainText, .url, .fileURL, .image], isTargeted: nil) { providers in
            handleProviders(providers)
            return true
        }
    }

    private func handleProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task { @MainActor in
                        if let clip = try? await store.createTextClip(
                            content: s, sourceAppName: "Drop"
                        ), let cid = clip.id, let pid = pinboardId {
                            try? await pinboards?.pin(clipId: cid, toBoard: pid)
                        }
                        PasteToast.shared.show(
                            targetApp: nil,
                            customMessage: "クリップを追加しました"
                        )
                    }
                }
            }
        }
    }
}

extension View {
    @MainActor
    func acceptExternalDropAsClip(pinboardId: Int64?,
                                  store: ClipStore,
                                  pinboards: PinboardStore?) -> some View {
        modifier(ExternalDropAddClip(
            pinboardId: pinboardId,
            store: store,
            pinboards: pinboards
        ))
    }
}
