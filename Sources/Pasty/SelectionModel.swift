import Foundation
import SwiftUI

/// クリップ選択状態。SpotlightPanel / StripPanel / MenuBarContentView から
/// 同じインスタンスを共有することで、どのサーフェスからでも同じ選択ロジック
/// （Shift で範囲、⌘ で個別、Space でトグル、⌘A で全選択）が動く。
@MainActor
final class SelectionModel: ObservableObject {
    /// 「複数選択モード」が ON のとき、行クリックは選択トグルになる（貼付は別ボタン）。
    /// OFF のとき、行クリックは即座に貼付。Shift+クリックや ⌘A をすると自動で ON に切り替わる。
    @Published var multiMode: Bool = false

    /// 選択中の clipId — **選択した順序** を保持する配列。Set ではなく
    /// 配列なのは、結合貼付が「ユーザーが選んだ順」で行われるようにするため。
    @Published private(set) var orderedSelectedIDs: [Int64] = []

    /// 既存呼び出し互換のための薄いラッパ。
    var selectedIDs: Set<Int64> { Set(orderedSelectedIDs) }

    /// キーボードカーソル位置（results 配列内のインデックス）。
    @Published var cursorIndex: Int = 0

    /// Shift+矢印 / Shift+クリック の範囲選択アンカー。
    @Published var anchorIndex: Int? = nil

    var hasSelection: Bool { !orderedSelectedIDs.isEmpty }
    var count: Int { orderedSelectedIDs.count }

    func isSelected(_ id: Int64) -> Bool { orderedSelectedIDs.contains(id) }

    /// 選択された順番 (1 始まり)。未選択の場合は nil。
    func order(of id: Int64) -> Int? {
        guard let idx = orderedSelectedIDs.firstIndex(of: id) else { return nil }
        return idx + 1
    }

    func clearAll() {
        orderedSelectedIDs.removeAll()
        anchorIndex = nil
        multiMode = false
    }

    /// 単純クリック — 既に選択がある場合だけトグル、それ以外は何もしない（即貼付は呼び出し側）。
    func tap(at index: Int, in items: [ClipItem]) -> TapResult {
        guard items.indices.contains(index) else { return .noop }
        cursorIndex = index
        let id = items[index].id ?? -1

        if multiMode {
            // 複数選択モード中はトグル
            toggle(id: id)
            anchorIndex = index
            return .toggled
        } else {
            // 通常モード：選択は捨てて即貼付
            return .pasteSingle(items[index])
        }
    }

    /// ⌘+クリック — 個別選択。multiMode に自動遷移。
    func commandTap(at index: Int, in items: [ClipItem]) {
        guard items.indices.contains(index) else { return }
        let id = items[index].id ?? -1
        multiMode = true
        cursorIndex = index
        anchorIndex = index
        toggle(id: id)
    }

    /// ⇧+クリック — アンカーから範囲選択。
    func shiftTap(at index: Int, in items: [ClipItem]) {
        guard items.indices.contains(index) else { return }
        multiMode = true
        let from = anchorIndex ?? cursorIndex
        cursorIndex = index
        selectRange(from: from, to: index, in: items, additive: true)
    }

    /// Space — 現在のカーソル位置をトグル（キーボードでの複数選択）。
    func toggleCursor(in items: [ClipItem]) {
        guard items.indices.contains(cursorIndex) else { return }
        let id = items[cursorIndex].id ?? -1
        multiMode = true
        toggle(id: id)
        anchorIndex = cursorIndex
    }

    /// ↑/↓ — カーソルを動かすだけ（選択は変えない）。
    func moveCursor(by delta: Int, in items: [ClipItem]) {
        guard !items.isEmpty else { return }
        cursorIndex = (cursorIndex + delta).clamped(to: 0...(items.count - 1))
    }

    /// ⇧+↑/↓ — カーソルを動かしつつアンカーから現在地までの範囲を選択。
    func extend(by delta: Int, in items: [ClipItem]) {
        guard !items.isEmpty else { return }
        if anchorIndex == nil { anchorIndex = cursorIndex }
        multiMode = true
        cursorIndex = (cursorIndex + delta).clamped(to: 0...(items.count - 1))
        if let anchor = anchorIndex {
            selectRange(from: anchor, to: cursorIndex, in: items, additive: false)
        }
    }

    /// ⌘A — 表示中の全件を選択。
    func selectAll(in items: [ClipItem]) {
        multiMode = true
        orderedSelectedIDs = items.compactMap { $0.id }
        anchorIndex = 0
        cursorIndex = max(0, items.count - 1)
    }

    /// 選択中のアイテムを **選択した順序** で取り出す (結合貼付・順次貼付で使用)。
    func selectedItems(from items: [ClipItem]) -> [ClipItem] {
        orderedSelectedIDs.compactMap { id in items.first(where: { $0.id == id }) }
    }

    // MARK: - private

    private func toggle(id: Int64) {
        if let idx = orderedSelectedIDs.firstIndex(of: id) {
            orderedSelectedIDs.remove(at: idx)
            if orderedSelectedIDs.isEmpty { multiMode = false }
        } else {
            orderedSelectedIDs.append(id)
        }
    }

    private func selectRange(from: Int, to: Int, in items: [ClipItem], additive: Bool) {
        let lo = min(from, to), hi = max(from, to)
        let ids = items[lo...hi].compactMap { $0.id }
        if additive {
            for id in ids where !orderedSelectedIDs.contains(id) {
                orderedSelectedIDs.append(id)
            }
        } else {
            orderedSelectedIDs = ids
        }
    }

    enum TapResult {
        case noop
        case toggled
        case pasteSingle(ClipItem)
    }
}
