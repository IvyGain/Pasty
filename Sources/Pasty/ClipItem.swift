import Foundation
import GRDB

enum ClipKind: String, Codable {
    case text
    case richText
    case image
    case file
    case link
    case color
    case other
}

struct ClipItem: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: Int64?
    var createdAt: Date
    var kind: ClipKind
    var preview: String        // short summary shown in lists (text, file name, url, etc.)
    var content: String?       // raw text content (nil for binary kinds)
    var dataPath: String?      // relative path under blob dir for images/files
    var byteSize: Int64
    var sourceBundleId: String?
    var sourceAppName: String?
    var contentHash: String    // sha256 for dedupe

    /// Non-stored. フォルダ内で表示する「ユーザーが付けたカード名」。
    /// `PinboardStore.items(in:)` がメモリ上で詰めるだけで、`clips` テーブル
    /// には保存されない（`pinboard_items.title` 由来）。
    var pinDisplayTitle: String? = nil

    static let databaseTableName = "clips"

    enum Columns: String, ColumnExpression {
        case id, createdAt, kind, preview, content, dataPath, byteSize
        case sourceBundleId, sourceAppName, contentHash
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, kind, preview, content, dataPath, byteSize
        case sourceBundleId, sourceAppName, contentHash
        // pinDisplayTitle はあえて含めない（DB / Codable から除外）。
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Shared utilities (kept here after SpotlightPanel.swift was removed)

import AppKit

enum CurrentInput {
    @MainActor static var modifierFlags: NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? []
    }
}

extension ClipKind {
    /// SF Symbol name used wherever a clip needs an icon fallback.
    var iconName: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .color: return "paintpalette"
        case .other: return "questionmark.square"
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
