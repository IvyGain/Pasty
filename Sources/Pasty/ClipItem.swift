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

    static let databaseTableName = "clips"

    enum Columns: String, ColumnExpression {
        case id, createdAt, kind, preview, content, dataPath, byteSize
        case sourceBundleId, sourceAppName, contentHash
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
