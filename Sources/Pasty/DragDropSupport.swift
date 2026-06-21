import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Custom UTTypes

extension UTType {
    /// v0.8.8: フォルダタブの並び替えドラッグ専用の独自 UTType。
    /// `String` / `public.plain-text` には conform しないので、クリップ用の
    /// `.dropDestination(for: String.self)` (= `acceptClipReferenceDrop`) には
    /// 入らず、タブ間ギャップの `.dropDestination(for: PinboardDragItem.self)`
    /// だけが受け取る。逆にクリップドラッグはこの UTType に conform しないので、
    /// ギャップの縦線インジケータは反応しない。
    static let pastyPinboardTab = UTType(exportedAs: "app.pasty.pinboard-tab",
                                         conformingTo: .data)
}

// MARK: - PinboardDragItem

/// v0.8.8: フォルダタブを掴んで並び替える時の Transferable。
/// クリップドラッグの `String` 系 representation とは UTType レベルで分離されており、
/// `.acceptClipReferenceDrop` (= `dropDestination(for: String.self)`) には流れ込まない。
///
/// v0.9.4: `.onDrag { NSItemProvider() }` + `DropDelegate` 経路に移行したため、
/// JSON エンコード経由でも運べるよう `Codable` のままにしておく
/// (`registerDataRepresentation` 用に `JSONEncoder` で直接シリアライズする)。
struct PinboardDragItem: Codable, Transferable {
    let boardID: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pastyPinboardTab)
    }
}

// MARK: - PinboardReorderDelegate (v0.9.4)

/// v0.9.4: フォルダタブの並べ替えドロップを受け持つ `DropDelegate`。
///
/// 高レベル API (`.dropDestination(for: PinboardDragItem.self)`) は SwiftUI の
/// ヒットテスト解決を経由するため、`.draggable` / `.acceptClipReferenceDrop` の
/// **モディファイア順** に依存して経路が崩れる回帰が v0.8.8 - v0.9.3 で 4 連続
/// 発生した。中レベル API (`.onDrop(of:delegate:)` + `DropDelegate`) はビュー階層
/// の暗黙解決を経由しないため、モディファイア順から完全に切り離される。
///
/// - `validateDrop`: 専用 UTType `app.pasty.pinboard-tab` (= `PinboardDragItem`) のみ受理。
///   クリップドラッグの `String`/`plainText` 系 representation はここで弾かれる。
/// - `dropEntered`: `folderDropTargetIndex` を自身の `targetIndex` に切替。
///   次のギャップの `dropEntered` が即座に上書きするので、`dropExited` は no-op で問題ない。
/// - `performDrop`: `NSItemProvider.loadDataRepresentation` で JSON デコードした
///   `PinboardDragItem` を取り出し、`onReorder` に渡す。失敗時は state を必ずクリア。
struct PinboardReorderDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var folderDropTargetIndex: Int?
    @Binding var draggedBoardId: Int64?
    let onReorder: (Int64, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.pastyPinboardTab.identifier])
    }

    func dropEntered(info: DropInfo) {
        folderDropTargetIndex = targetIndex
    }

    func dropExited(info: DropInfo) {
        // noop; 次のギャップの dropEntered が即座に上書きするので、
        // ここで nil 化するとちらつきが発生する。
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.pastyPinboardTab.identifier]).first else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.pastyPinboardTab.identifier) { data, _ in
            guard let data = data,
                  let item = try? JSONDecoder().decode(PinboardDragItem.self, from: data) else {
                DispatchQueue.main.async {
                    self.draggedBoardId = nil
                    self.folderDropTargetIndex = nil
                }
                return
            }
            DispatchQueue.main.async {
                self.onReorder(item.boardID, self.targetIndex)
                self.draggedBoardId = nil
                self.folderDropTargetIndex = nil
            }
        }
        return true
    }
}

// MARK: - Payload encoding

/// クリップ参照を文字列でエンコードして D&D の payload として運ぶ。
/// 形式: `PASTY|<id>|<preview>`。
/// v0.9.0: 複数選択ドラッグ用に `PASTY-MULTI|<id1>|<id2>|...` 形式も追加。
/// preview は格納しない (受信側は ID から store で再解決する)。
enum ClipDnDPayload {
    static let marker = "PASTY|"
    static let multiMarker = "PASTY-MULTI|"

    static func encode(_ clip: ClipItem) -> String {
        let id = clip.id ?? -1
        return marker + "\(id)|" + clip.preview
    }

    /// 複数クリップを 1 つの payload にまとめる。受信側で `decodeMulti` を使う。
    static func encodeMulti(_ clips: [ClipItem]) -> String {
        let ids = clips.compactMap { $0.id }.map(String.init)
        return multiMarker + ids.joined(separator: "|")
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

    /// 複数 payload 用デコーダ。`PASTY-MULTI|id1|id2|...` を `[Int64]` に展開。
    static func decodeMulti(_ s: String) -> [Int64]? {
        guard s.hasPrefix(multiMarker) else { return nil }
        let rest = s.dropFirst(multiMarker.count)
        let ids = rest.split(separator: "|").compactMap { Int64($0) }.filter { $0 > 0 }
        return ids.isEmpty ? nil : ids
    }
}

// MARK: - Transferable wrapper

/// 内部 D&D (Pasty 内のフォルダタブにドロップしてピン) と
/// 外部 D&D (他アプリにドロップして貼付) を両立する Transferable。
///
/// - 内部受信側 (`dropDestination(for: String.self)`) は marker 付き文字列
///   `PASTY|<id>|<preview>` をデコードして clip 参照を復元する。
/// - 外部アプリ (Notion / Slack / Finder / Safari など) には marker を含まない
///   素のテキストや URL が渡るよう、複数の `ProxyRepresentation` を登録する。
///
/// v0.9.5-beta X1: 画像 / ファイル / 動画クリップを他アプリにドロップしたとき
/// preview 文字列 ("Screenshot" 等) しか渡らず、ホストアプリがカーソル位置に
/// 画像を貼れない不具合 (= Enter 経路と D&D 経路の挙動差) を解消するため、
/// `DataRepresentation` (画像 binary) と `FileRepresentation` (ファイル URL)
/// を追加する。非対応 kind では closure 内で throw し、その representation を
/// 無効化することで、テキスト経路へクリーンにフォールバックさせる。
struct ClipDragItem: Transferable {
    let clip: ClipItem

    static var transferRepresentation: some TransferRepresentation {
        // 内部 D&D 用: marker 付き文字列。dropDestination(for: String.self) で識別される。
        ProxyRepresentation(exporting: \ClipDragItem.markerString)

        // 外部 D&D (画像): blob の生バイナリを image content type で export。
        // TextEdit / Notes / Slack / Pages 等はこの representation を選んで
        // カーソル位置に画像を貼り付ける。
        // 非画像 kind では throw して当 representation を無効化する。
        DataRepresentation(exportedContentType: .png) { item in
            guard item.clip.kind == .image,
                  item.imageContentType == .png,
                  let data = item.imageData else {
                throw CocoaError(.featureUnsupported)
            }
            return data
        }
        DataRepresentation(exportedContentType: .jpeg) { item in
            guard item.clip.kind == .image,
                  item.imageContentType == .jpeg,
                  let data = item.imageData else {
                throw CocoaError(.featureUnsupported)
            }
            return data
        }
        DataRepresentation(exportedContentType: .tiff) { item in
            guard item.clip.kind == .image,
                  item.imageContentType == .tiff,
                  let data = item.imageData else {
                throw CocoaError(.featureUnsupported)
            }
            return data
        }
        DataRepresentation(exportedContentType: .gif) { item in
            guard item.clip.kind == .image,
                  item.imageContentType == .gif,
                  let data = item.imageData else {
                throw CocoaError(.featureUnsupported)
            }
            return data
        }

        // 外部 D&D (ファイル/動画/画像): 実ファイル URL も併せて提供する。
        // Finder にドロップすると blob ファイル自体がコピーされ、リッチエディタ
        // 系 (Pages / Keynote / Word) では「画像ファイルとして埋め込み」する経路
        // に乗る。Pasty の blob ストアの実体を晒すので `exporting` で済ませる
        // (オリジナルファイルとして扱われる)。
        FileRepresentation(exportedContentType: .data) { item in
            guard let url = item.imageFileURL else {
                throw CocoaError(.featureUnsupported)
            }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }

        // 外部テキスト D&D 用: marker なしの素のテキスト。
        // 上の DataRepresentation/FileRepresentation が選ばれなかった時のフォールバック。
        ProxyRepresentation(exporting: \ClipDragItem.plainText)
        // 外部 URL D&D 用: link kind の時のみ有意味な URL を返す。
        ProxyRepresentation(exporting: \ClipDragItem.linkURL)
    }

    /// 既存の "PASTY|<id>|<preview>" 形式。内部 dropDestination 受信側で剥がす。
    /// `ClipDnDPayload.decode` と互換になるよう、preview 内の `|` は空白に置換する。
    var markerString: String {
        let id = clip.id ?? -1
        let preview = clip.preview.replacingOccurrences(of: "|", with: " ")
        return "PASTY|\(id)|\(preview)"
    }

    /// 外部アプリにドロップする時の素の内容。
    var plainText: String {
        clip.content ?? clip.preview
    }

    /// link kind なら URL、それ以外は about:blank をダミーで返す
    /// (Transferable の挙動上、受け手が URL を期待しなければ他の representation が選ばれる)。
    var linkURL: URL {
        if clip.kind == .link, let raw = clip.content, let u = URL(string: raw) {
            return u
        }
        return URL(string: "about:blank")!
    }

    // MARK: - v0.9.5-beta X1: image / file binary representation helpers

    /// 画像クリップの blob 実体を Data として読み出す。
    /// 非画像 kind / dataPath 無し / 読込失敗時は nil。
    var imageData: Data? {
        guard clip.kind == .image, let p = clip.dataPath else { return nil }
        let url = ClipBlobs.blobURL(for: p)
        return try? Data(contentsOf: url)
    }

    /// 画像/ファイル/動画クリップの blob 実体ファイル URL。
    /// 非バイナリ kind / dataPath 無しは nil。Finder ドロップ・FileRepresentation 用。
    var imageFileURL: URL? {
        guard clip.kind == .image || clip.kind == .file || clip.kind == .video,
              let p = clip.dataPath else { return nil }
        return ClipBlobs.blobURL(for: p)
    }

    /// blob ファイル拡張子から推定する画像 UTType。
    /// 未知 / 拡張子無しは `.png` を既定とする (PasteboardObserver は PNG 保存が主)。
    var imageContentType: UTType {
        guard let url = imageFileURL else { return .png }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "tiff", "tif": return .tiff
        case "gif": return .gif
        case "png": return .png
        default: return .png
        }
    }
}

// MARK: - Multi-clip drag wrapper (v0.9.0)

/// 複数選択中にドラッグした時の Transferable。
/// - 内部 D&D 用: `PASTY-MULTI|<id1>|<id2>|...` の 1 行 marker。
///   `acceptClipReferenceDrop` の `dropDestination(for: String.self)` 経路で
///   `ClipDnDPayload.decodeMulti` により ID 配列に展開される。
/// - 外部 D&D 用: 各クリップの plain text を改行で繋いだ 1 個の文字列。
///   Notion / Slack / メモなど他アプリには「全件分」がまとめて貼られる。
struct MultiClipDragItem: Transferable {
    let clips: [ClipItem]

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \MultiClipDragItem.markerString)
        ProxyRepresentation(exporting: \MultiClipDragItem.plainText)
    }

    var markerString: String {
        ClipDnDPayload.encodeMulti(clips)
    }

    /// 外部アプリ向けに「選んだ順」で全件のテキストを改行連結。
    var plainText: String {
        clips.map { $0.content ?? $0.preview }.joined(separator: "\n")
    }
}

// MARK: - Draggable extension

@MainActor
extension View {
    /// クリップを掴むときの draggable + ミニカード型ドラッグプレビュー。
    /// `additionalSelected` に「同時にドラッグする他のクリップ」を渡すと、
    /// 奥に重なる層として表示される（複数選択ドラッグ用）。
    ///
    /// v0.9.0 A-4: `additionalSelected` が非空の時は `MultiClipDragItem` を露出し、
    /// 内部 D&D 経路 (`acceptClipReferenceDrop`) には全件分の ID をまとめた
    /// `PASTY-MULTI|...` 1 行 payload を、外部アプリには改行連結したテキストを渡す。
    /// 空の時は従来の 1 件 `ClipDragItem` のまま (回帰なし)。
    @ViewBuilder
    func draggableClip(_ clip: ClipItem,
                       additionalSelected: [ClipItem] = []) -> some View {
        if additionalSelected.isEmpty {
            self.draggable(ClipDragItem(clip: clip)) {
                MiniClipDragPreview(count: 1)
            }
        } else {
            // 「掴んだクリップを先頭」にして選択順を維持。重複排除のため
            // additionalSelected から primary を除外して連結する。
            let ordered = [clip] + additionalSelected.filter { $0.id != clip.id }
            self.draggable(MultiClipDragItem(clips: ordered)) {
                MiniClipDragPreview(count: ordered.count)
            }
        }
    }
}

// MARK: - MiniClipDragPreview (v0.9.4)

/// v0.9.4: クリップドラッグ時の **薄く小さな** プレビュー。
///
/// v0.9.3 までの `ClipDragCard` (220×100 + 3 層シャドウ + 件数バッジ) は
/// フォルダタブ上にホバーした瞬間に「タブが完全に見えなくなる」ため、
/// どのフォルダに落ちるかが分からないという UX 上の致命傷を抱えていた。
/// 並列で `pastyDragTargetHovered` 通知で隠す回避策を入れていたが、
/// 出し入れのちらつきが残っていた。
///
/// v0.9.4 では 80×24pt の薄い `regularMaterial` 矩形 + 件数バッジに置き換え、
/// 元々のフォルダタブのハイライト (`acceptClipReferenceDrop` 側の
/// scale/ring/+ バッジ) を主役に戻す。プレビュー側は完全に脇役へ。
@MainActor
struct MiniClipDragPreview: View {
    let count: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10))
                    Text(count == 1 ? "1 件" : "\(count) 件")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.primary.opacity(0.85))
            )
            .frame(width: 80, height: 24)
            .opacity(0.55)
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
    /// v0.9.4: 外部 (例: `folderTab`) にホバー状態を伝搬する optional binding。
    /// `nil` の時は完全に no-op (後方互換)。
    let externalIsTargeted: Binding<Bool>?

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
                // v0.9.4: フォルダタブ側の overlay/scale を駆動するため、
                // 外部 binding にもホバー状態を伝搬する。
                externalIsTargeted?.wrappedValue = hovering
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
                // v0.9.0 A-4: 複数選択ドラッグから来た PASTY-MULTI marker は
                // 1 つの文字列に複数 ID を詰め込んでいるので、ループで個別に pin。
                if let ids = ClipDnDPayload.decodeMulti(s) {
                    for cid in ids {
                        do {
                            try await pinboards.pin(clipId: cid, toBoard: pid)
                            pinned += 1
                        } catch {
                            NSLog("D&D multi pin failed: \(error)")
                        }
                    }
                } else if let payload = ClipDnDPayload.decode(s) {
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
                                 visualFeedback: Bool = true,
                                 isTargeted: Binding<Bool>? = nil) -> some View {
        modifier(ClipReceiveDropTarget(
            pinboardId: pinboardId,
            pinboards: pinboards,
            store: store,
            visualFeedback: visualFeedback,
            externalIsTargeted: isTargeted
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
