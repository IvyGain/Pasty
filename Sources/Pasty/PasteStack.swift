import Foundation
import SwiftUI

/// Paste-style "Stack" — pre-collect items, then paste them in order with
/// repeated ⌘V. Drag to reorder, swipe to drop. Lives entirely in memory.
@MainActor
final class PasteStack: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var reversed: Bool = false      // pop from tail instead of head

    func push(_ item: ClipItem) {
        items.append(item)
    }

    func reorder(_ from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
    }

    func clear() { items.removeAll() }

    /// Pops the next item per the current order and pastes it.
    /// Returns true if an item was pasted.
    @discardableResult
    func pasteNext(plain: Bool = false) -> Bool {
        guard !items.isEmpty else { return false }
        let item = reversed ? items.removeLast() : items.removeFirst()
        PasteAutomator.shared.paste(item, asPlainText: plain)
        return true
    }

    /// Concatenate stack into a single string with `separator` between
    /// items and paste it as one operation. Useful when you copied bits of
    /// a document in pieces and now want them stitched back together.
    func pasteAsDocument(separator: String = "\n") {
        let text = items.compactMap { $0.content }.joined(separator: separator)
        guard !text.isEmpty else { return }
        let synthetic = ClipItem(
            id: nil,
            createdAt: Date(),
            kind: .text,
            preview: String(text.prefix(120)),
            content: text,
            dataPath: nil,
            byteSize: Int64(text.utf8.count),
            sourceBundleId: "io.pasty.stack",
            sourceAppName: "Pasty Stack",
            contentHash: ""
        )
        PasteAutomator.shared.paste(synthetic)
        clear()
    }
}
