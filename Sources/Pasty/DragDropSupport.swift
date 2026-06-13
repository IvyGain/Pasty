import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Payload encoding

/// クリップ参照を文字列でエンコードして D&D の payload として運ぶ。
/// 形式: `PASTY|<id>|<preview>`。
enum ClipDnDPayload {
    static let marker = "PASTY|"

    static func encode(_ clip: ClipItem) -> String {
        let id = clip.id ?? -1
        return marker + "\(id)|" + clip.preview
    }

    static func decode(_ s: String) -> (id: Int64, preview: String)? {
        guard s.hasPrefix(marker) else { return nil }
        let rest = s.dropFirst(marker.count)
        guard let pipeIdx = rest.firstIndex(of: "|") else { return nil }
        let idStr = String(rest[..<pipeIdx])
        let preview = String(rest[rest.index(after: pipeIdx)...])
        guard let id = Int64(idStr), id > 0 else { return nil }
        return (id, preview)
    }
}

// MARK: - Draggable extension

@MainActor
extension View {
    /// クリップを掴むときの draggable + ミニカード型ドラッグプレビュー。
    /// `additionalSelected` に「同時にドラッグする他のクリップ」を渡すと、
    /// 奥に重なる層として表示される（複数選択ドラッグ用）。
    func draggableClip(_ clip: ClipItem,
                       additionalSelected: [ClipItem] = []) -> some View {
        self.draggable(ClipDnDPayload.encode(clip)) {
            ClipDragCard(primary: clip, others: additionalSelected)
        }
    }
}

/// ドラッグ中にカーソルに付いてくるミニカード。
/// 単体: 1 枚のカード。
/// 複数選択: 主たるカードの後ろに 2-3 枚を **少しズラして奥に** 重ねる。
@MainActor
struct ClipDragCard: View {
    let primary: ClipItem
    var others: [ClipItem] = []   // 追加で選択中のクリップ

    @State private var hidden: Bool = false

    private static let cardWidth: CGFloat = 220
    private static let cardHeight: CGFloat = 100

    var body: some View {
        ZStack {
            // 奥のカード（最大 2 枚分、少しずつズラす）
            ForEach(Array(others.prefix(2).enumerated()).reversed(), id: \.offset) { idx, clip in
                miniCard(for: clip, depth: idx + 1)
                    .offset(x: CGFloat(idx + 1) * 8, y: CGFloat(idx + 1) * 8)
                    .opacity(0.85 - Double(idx) * 0.15)
                    .scaleEffect(1.0 - CGFloat(idx + 1) * 0.04)
                    .zIndex(-Double(idx + 1))
            }
            // 一番手前のメインカード
            miniCard(for: primary, depth: 0)
                .zIndex(0)

            // 件数バッジ（複数選択時のみ）
            if !others.isEmpty {
                Text("\(others.count + 1)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                    )
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 6, x: 0, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topTrailing)
                    .offset(x: 10, y: -10)
            }
        }
        .frame(width: Self.cardWidth + 24, height: Self.cardHeight + 24)
        // フォルダにホバー中はドラッグカードを非表示に → フォルダが見えるように。
        .opacity(hidden ? 0 : 1)
        .scaleEffect(hidden ? 0.6 : 1.0)
        .animation(.easeOut(duration: 0.18), value: hidden)
        .onReceive(NotificationCenter.default.publisher(for: .pastyDragTargetHovered)) { _ in
            hidden = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .pastyDragTargetUnhovered)) { _ in
            hidden = false
        }
    }

    @ViewBuilder
    private func miniCard(for clip: ClipItem, depth: Int) -> some View {
        let kindColor = KindPalette.detectedColor(for: clip)
        let kindLabel = KindPalette.detectedLabel(for: clip)
        VStack(spacing: 0) {
            // 上部カラーバンド
            ZStack {
                LinearGradient(colors: [kindColor, kindColor.opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 6) {
                    Text(kindLabel)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                    Spacer()
                    if let bid = clip.sourceBundleId,
                       let icon = SourceAppIconCache.shared.icon(forBundleID: bid) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 3,
                                                        style: .continuous))
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 22)

            // 本文
            HStack(alignment: .top) {
                if clip.kind == .image, let p = clip.dataPath,
                   let img = ImageBlobCache.shared.image(for: p) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Text(clip.pinDisplayTitle ?? clip.preview)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28 - Double(depth) * 0.04),
                radius: 14 - CGFloat(depth) * 3,
                x: 0, y: 6 - CGFloat(depth) * 1)
    }
}

// MARK: - Drop target modifier

@MainActor
struct ClipReceiveDropTarget: ViewModifier {
    let pinboardId: Int64?
    let pinboards: PinboardStore
    let store: ClipStore
    let visualFeedback: Bool

    @State private var isTargeted: Bool = false
    @State private var pulse: Bool = false

    func body(content: Content) -> some View {
        content
            // 大きめに拡大して「光っているフォルダ」をアピール
            .scaleEffect(isTargeted ? 1.24 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isTargeted)
            // 多層の脈動グロー（背景）
            .background(
                ZStack {
                    // 外側の大きなソフトグロー
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(isTargeted ? (pulse ? 0.55 : 0.30) : 0))
                        .blur(radius: isTargeted ? 14 : 0)
                        .scaleEffect(isTargeted ? 1.55 : 1.0)
                    // 内側のリング
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(isTargeted ? (pulse ? 0.35 : 0.20) : 0))
                        .blur(radius: isTargeted ? 6 : 0)
                        .scaleEffect(isTargeted ? 1.20 : 1.0)
                }
                .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                           value: pulse)
            )
            // 実線のアクセント枠
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor : .clear,
                                  lineWidth: isTargeted ? 2 : 0)
                    .opacity(visualFeedback ? 1 : 0)
            )
            // フォルダタブの **上** に「+ 追加」バッジを表示。
            .overlay(alignment: .top) {
                if isTargeted {
                    AddBadge()
                        .offset(y: -26)
                        .transition(.scale(scale: 0.4, anchor: .bottom)
                                    .combined(with: .opacity))
                }
            }
            .zIndex(isTargeted ? 100 : 0)
            .dropDestination(for: String.self) { strings, _ in
                handleDropped(strings: strings)
                return true
            } isTargeted: { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isTargeted = hovering
                }
                pulse = hovering
                // ドラッグカードを「フォルダの上だけ消して」フォルダがよく見えるように。
                // 通知で DragDropOverlayController に隠す/出すを伝える。
                NotificationCenter.default.post(
                    name: hovering
                        ? .pastyDragTargetHovered
                        : .pastyDragTargetUnhovered,
                    object: nil
                )
            }
    }

    private func handleDropped(strings: [String]) {
        guard let pid = pinboardId else { return }
        let boardName = pinboards.boards.first { $0.id == pid }?.name ?? "フォルダ"
        Task { @MainActor in
            var pinned = 0
            var added = 0
            for s in strings {
                if let payload = ClipDnDPayload.decode(s) {
                    do {
                        try await pinboards.pin(clipId: payload.id, toBoard: pid)
                        pinned += 1
                    } catch {
                        NSLog("D&D pin failed: \(error)")
                    }
                } else {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let clip = try? await store.createTextClip(
                        content: s, sourceAppName: "Drop"
                    ), let cid = clip.id {
                        try? await pinboards.pin(clipId: cid, toBoard: pid)
                        added += 1
                    }
                }
            }
            let total = pinned + added
            let msg: String
            if total == 0 {
                msg = "ドロップを受け取れませんでした"
            } else if added > 0 && pinned > 0 {
                msg = "📌 \(boardName) に \(total) 件を保存"
            } else if added > 0 {
                msg = "📌 \(boardName) に新しい定型文を追加"
            } else if pinned == 1 {
                msg = "📌 \(boardName) に定型文として保存"
            } else {
                msg = "📌 \(boardName) に \(pinned) 件を保存"
            }
            PasteToast.shared.show(targetApp: nil, customMessage: msg)
            _ = store
        }
    }
}

/// ドロップ可能を示す「+ 追加」バッジ。脈動する。
@MainActor
private struct AddBadge: View {
    @State private var bounce: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14, weight: .bold))
            Text("追加")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        )
        .shadow(color: Color.accentColor.opacity(0.45), radius: 8, x: 0, y: 4)
        .scaleEffect(bounce ? 1.08 : 1.0)
        .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true),
                   value: bounce)
        .onAppear { bounce = true }
    }
}

extension View {
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

    @MainActor
    func acceptExternalDropAsClip(pinboardId: Int64?,
                                  store: ClipStore,
                                  pinboards: PinboardStore?) -> some View {
        Group {
            if let pinboards {
                self.acceptClipReferenceDrop(
                    pinboardId: pinboardId,
                    pinboards: pinboards,
                    store: store,
                    visualFeedback: false
                )
            } else {
                self
            }
        }
    }
}
