import Foundation
import AppKit
import GRDB
import UniformTypeIdentifiers

// MARK: - Archive DTOs

/// Top-level container for an export archive. Stable on-disk shape.
public struct PastyExportArchive: Codable {
    public let version: Int                       // 1
    public let exportedAt: Date
    public let appVersion: String
    public let clips: [ExportedClip]
    public let pinboards: [ExportedPinboard]
    public let pinboardItems: [ExportedPinboardItem]
}

public struct ExportedClip: Codable {
    public let id: Int64
    public let createdAt: Date
    public let kind: String              // ClipKind rawValue
    public let preview: String
    public let content: String?
    public let imageDataBase64: String?  // image blob base64 encoded inline
    public let byteSize: Int64
    public let sourceBundleId: String?
    public let sourceAppName: String?
    public let contentHash: String
}

public struct ExportedPinboard: Codable {
    public let id: Int64
    public let name: String
    public let colorHex: String
    public let sortOrder: Int
    public let createdAt: Date
}

public struct ExportedPinboardItem: Codable {
    public let pinboardId: Int64
    public let clipId: Int64
    public let sortOrder: Int
    /// フォルダ内でユーザーが付けたカード名 (`pinboard_items.title`)。
    /// 旧アーカイブ (v1.0) には無いので optional。
    public let title: String?
}

// MARK: - Policy / Summary

public enum ConflictPolicy {
    case skipDuplicates       // contentHash match → skip
    case overwrite            // contentHash match → replace existing row
    case keepBoth             // always insert (suffix preview with importedAt)
}

public struct ImportSummary {
    public let clipsAdded: Int
    public let clipsSkipped: Int
    public let pinboardsAdded: Int
    public let pinboardItemsAdded: Int
}

// MARK: - Errors

public enum ImportExportError: LocalizedError {
    case unsupportedVersion(Int)
    case malformedArchive(String)
    case fileIO(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported archive version: \(v). This Pasty build only understands version 1."
        case .malformedArchive(let detail):
            return "The archive is malformed: \(detail)"
        case .fileIO(let detail):
            return "File I/O failed: \(detail)"
        }
    }
}

// MARK: - Manager

/// Pure logic + IO for exporting and importing the whole Pasty corpus
/// (clips + pinboards + pinboard memberships) as a single JSON archive.
/// No SwiftUI here — UI hosts can call into this from their actions.
@MainActor
final class ImportExportManager {
    static let shared = ImportExportManager()
    private init() {}

    private let archiveVersion = 1

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: Export

    /// Build the archive payload from current SQLite state.
    func exportAll(store: ClipStore, pinboards: PinboardStore) async throws -> Data {
        let dbWriter = store.dbWriter

        // Pull raw rows in one read.
        let snapshot: (clips: [ClipItem], boards: [Pinboard], items: [PinboardItem]) =
            try await dbWriter.read { db in
                let clips = try ClipItem.order(ClipItem.Columns.createdAt.asc).fetchAll(db)
                let boards = try Pinboard.order(Pinboard.Columns.sortOrder.asc).fetchAll(db)
                let items = try PinboardItem.order(PinboardItem.Columns.sortOrder.asc).fetchAll(db)
                return (clips, boards, items)
            }

        let exportedClips: [ExportedClip] = snapshot.clips.compactMap { clip in
            guard let id = clip.id else { return nil }

            var b64: String? = nil
            if clip.kind == .image, let rel = clip.dataPath {
                let url = ClipBlobs.blobURL(for: rel)
                if let data = try? Data(contentsOf: url) {
                    b64 = data.base64EncodedString()
                }
            }

            return ExportedClip(
                id: id,
                createdAt: clip.createdAt,
                kind: clip.kind.rawValue,
                preview: clip.preview,
                content: clip.content,
                imageDataBase64: b64,
                byteSize: clip.byteSize,
                sourceBundleId: clip.sourceBundleId,
                sourceAppName: clip.sourceAppName,
                contentHash: clip.contentHash
            )
        }

        let exportedBoards: [ExportedPinboard] = snapshot.boards.compactMap { p in
            guard let id = p.id else { return nil }
            return ExportedPinboard(
                id: id,
                name: p.name,
                colorHex: p.colorHex,
                sortOrder: p.sortOrder,
                createdAt: p.createdAt
            )
        }

        let exportedItems: [ExportedPinboardItem] = snapshot.items.map {
            ExportedPinboardItem(
                pinboardId: $0.pinboardId,
                clipId: $0.clipId,
                sortOrder: $0.sortOrder,
                title: $0.title
            )
        }

        let archive = PastyExportArchive(
            version: archiveVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            clips: exportedClips,
            pinboards: exportedBoards,
            pinboardItems: exportedItems
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            return try encoder.encode(archive)
        } catch {
            throw ImportExportError.fileIO("encode failed: \(error.localizedDescription)")
        }
    }

    /// Present a save panel and write the archive there. Returns the chosen URL
    /// or `nil` if the user cancelled.
    func exportWithSavePanel(store: ClipStore, pinboards: PinboardStore) async throws -> URL? {
        let data = try await exportAll(store: store, pinboards: pinboards)

        let panel = NSSavePanel()
        panel.title = "Export Pasty Archive"
        panel.nameFieldStringValue = "Pasty-Export-\(Self.fileTimestamp()).json"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImportExportError.fileIO("write failed: \(error.localizedDescription)")
        }
        return url
    }

    // MARK: Import

    /// Decode an archive blob and merge it into the live stores.
    func importAll(from data: Data,
                   store: ClipStore,
                   pinboards: PinboardStore,
                   conflictPolicy: ConflictPolicy) async throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let archive: PastyExportArchive
        do {
            archive = try decoder.decode(PastyExportArchive.self, from: data)
        } catch {
            throw ImportExportError.malformedArchive(error.localizedDescription)
        }

        guard archive.version == archiveVersion else {
            throw ImportExportError.unsupportedVersion(archive.version)
        }

        let dbWriter = store.dbWriter
        let importedAt = Date()

        struct WriteResult {
            var clipsAdded = 0
            var clipsSkipped = 0
            var pinboardsAdded = 0
            var pinboardItemsAdded = 0
        }

        let result: WriteResult = try await dbWriter.write { db in
            var r = WriteResult()

            // Map archive clip id -> new local clip id (so pinboard_items can be remapped).
            var clipIdMap: [Int64: Int64] = [:]

            for exp in archive.clips {
                // Re-materialise image blob to disk if present.
                var dataPath: String? = nil
                if exp.kind == ClipKind.image.rawValue,
                   let b64 = exp.imageDataBase64,
                   let imageData = Data(base64Encoded: b64) {
                    dataPath = ClipBlobs.writeImage(imageData, hash: exp.contentHash)
                }

                let kind = ClipKind(rawValue: exp.kind) ?? .other

                // Conflict detection by contentHash.
                let existingId: Int64? = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM clips WHERE contentHash = ? LIMIT 1",
                    arguments: [exp.contentHash]
                )

                switch conflictPolicy {
                case .skipDuplicates where existingId != nil:
                    r.clipsSkipped += 1
                    if let eid = existingId { clipIdMap[exp.id] = eid }
                    continue

                case .overwrite where existingId != nil:
                    guard let eid = existingId else { break }
                    try db.execute(
                        sql: """
                            UPDATE clips
                               SET createdAt = ?, kind = ?, preview = ?, content = ?,
                                   dataPath = ?, byteSize = ?, sourceBundleId = ?, sourceAppName = ?
                             WHERE id = ?
                            """,
                        arguments: [
                            exp.createdAt, kind.rawValue, exp.preview, exp.content,
                            dataPath, exp.byteSize, exp.sourceBundleId, exp.sourceAppName,
                            eid
                        ]
                    )
                    clipIdMap[exp.id] = eid
                    r.clipsAdded += 1
                    continue

                default:
                    break
                }

                // Decide the preview / hash for keepBoth duplicates.
                var preview = exp.preview
                var contentHash = exp.contentHash
                if conflictPolicy == .keepBoth, existingId != nil {
                    let suffix = " (imported \(Self.shortStamp(importedAt)))"
                    preview = exp.preview + suffix
                    // Salt the hash so dedupe in ClipStore.insert doesn't drop it on next paste.
                    contentHash = exp.contentHash + ":imp:" + String(Int(importedAt.timeIntervalSince1970))
                }

                var item = ClipItem(
                    id: nil,
                    createdAt: exp.createdAt,
                    kind: kind,
                    preview: preview,
                    content: exp.content,
                    dataPath: dataPath,
                    byteSize: exp.byteSize,
                    sourceBundleId: exp.sourceBundleId,
                    sourceAppName: exp.sourceAppName,
                    contentHash: contentHash
                )
                try item.insert(db)
                if let newId = item.id {
                    clipIdMap[exp.id] = newId
                }
                r.clipsAdded += 1
            }

            // Pinboards: match by name to avoid duplicates; otherwise insert.
            var boardIdMap: [Int64: Int64] = [:]
            for exp in archive.pinboards {
                let existingId: Int64? = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM pinboards WHERE name = ? LIMIT 1",
                    arguments: [exp.name]
                )
                if let eid = existingId {
                    boardIdMap[exp.id] = eid
                    continue
                }

                let nextOrder = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM pinboards"
                ) ?? 0
                var board = Pinboard(
                    id: nil,
                    name: exp.name,
                    colorHex: exp.colorHex,
                    sortOrder: nextOrder,
                    createdAt: exp.createdAt
                )
                try board.insert(db)
                if let newId = board.id {
                    boardIdMap[exp.id] = newId
                    r.pinboardsAdded += 1
                }
            }

            // Pinboard memberships: remap ids; skip dangling references.
            for exp in archive.pinboardItems {
                guard let newBoardId = boardIdMap[exp.pinboardId],
                      let newClipId = clipIdMap[exp.clipId] else { continue }

                // Skip if (board, clip) link already exists.
                let already: Int64? = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM pinboard_items WHERE pinboardId = ? AND clipId = ? LIMIT 1",
                    arguments: [newBoardId, newClipId]
                )
                if already != nil { continue }

                let nextOrder = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM pinboard_items WHERE pinboardId = ?",
                    arguments: [newBoardId]
                ) ?? 0

                var item = PinboardItem(
                    id: nil,
                    pinboardId: newBoardId,
                    clipId: newClipId,
                    sortOrder: nextOrder,
                    title: exp.title?.isEmpty == false ? exp.title : nil
                )
                try item.insert(db)
                r.pinboardItemsAdded += 1
            }

            return r
        }

        // Refresh observable state in the live stores.
        do { try pinboards.reload() } catch { /* non-fatal */ }
        // ClipStore exposes no public reload helper; re-trigger via a no-op write to bump
        // its published `recent` list. The simplest path: perform a harmless write that
        // forces reloadInitial via its insert path is invasive — instead we rely on the
        // user reopening the panel. (ClipStore.reloadInitial is private by design.)

        return ImportSummary(
            clipsAdded: result.clipsAdded,
            clipsSkipped: result.clipsSkipped,
            pinboardsAdded: result.pinboardsAdded,
            pinboardItemsAdded: result.pinboardItemsAdded
        )
    }

    /// Present an open panel, then import the chosen archive. Returns `nil` if cancelled.
    func importWithOpenPanel(store: ClipStore,
                             pinboards: PinboardStore,
                             conflictPolicy: ConflictPolicy) async throws -> ImportSummary? {
        let panel = NSOpenPanel()
        panel.title = "Import Pasty Archive"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportExportError.fileIO("read failed: \(error.localizedDescription)")
        }

        return try await importAll(
            from: data,
            store: store,
            pinboards: pinboards,
            conflictPolicy: conflictPolicy
        )
    }

    // MARK: Helpers

    private static func fileTimestamp(_ date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: date)
    }

    nonisolated private static func shortStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}
