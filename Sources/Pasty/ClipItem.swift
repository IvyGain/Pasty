import Foundation
import GRDB

enum ClipKind: String, Codable, CaseIterable {
    case text
    case richText
    case image
    case file
    case link
    case color
    case other
    case video
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
        case .video: return "play.rectangle"
        }
    }
}

// MARK: - Filter helpers

/// 一般的な拡張子を kind カテゴリにマップする。フィルター UI が kind の厳密一致
/// だけだと、CleanShot 等が `.file` で投げた PNG が「画像」に出ない / mp4 が
/// 「動画」に出ない、という体感ズレが起きる。拡張子セットを用意して fuzzy 判定
/// に切り替える。
enum FileKindClass {
    static let image: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif",
        "bmp", "icns", "avif", "raw", "psd"
    ]
    static let video: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "webm", "mpg", "mpeg",
        "wmv", "flv", "3gp", "hevc"
    ]
    static let audio: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "opus"
    ]
    static let document: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md",
        "rtf", "csv", "json", "yaml", "yml", "html", "xml"
    ]
}

extension ClipItem {
    /// クリップから推定される拡張子 (lowercased、`.` なし)。
    /// `dataPath` / `content` / `preview` のいずれかから拾う。`nil` の場合は
    /// 拡張子の判定がつかない (text や rich text)。
    var fileExtension: String? {
        // dataPath が "images/<hash>.png" のように拡張子付きで保存されているケース
        if let p = dataPath, let ext = extractExtension(from: p) {
            return ext
        }
        // file kind は content にフルパスが入っている
        if kind == .file, let c = content, let ext = extractExtension(from: c) {
            return ext
        }
        // それ以外は preview からも一応試す (text なら空文字で返るはず)
        if let ext = extractExtension(from: preview) {
            return ext
        }
        return nil
    }

    /// フィルタチップでの「このクリップは選んだ kind に属するか」判定。
    /// 厳密一致に加えて、`.file` でも拡張子から推定して image/video/file に振り分ける。
    func matchesFilter(_ kind: ClipKind) -> Bool {
        if self.kind == kind { return true }
        // ファイル系の fuzzy 判定
        guard let ext = fileExtension?.lowercased() else { return false }
        switch kind {
        case .image:
            return FileKindClass.image.contains(ext)
        case .video:
            return FileKindClass.video.contains(ext)
        case .file:
            // 「ファイル」フィルタは、画像/動画にカテゴライズされなかった
            // その他の拡張子つきデータをまとめて拾う。
            return !FileKindClass.image.contains(ext)
                && !FileKindClass.video.contains(ext)
                && !ext.isEmpty
        case .link:
            // テキストでも URL 形式なら link 扱い
            let raw = (content ?? preview).trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil
        default:
            return false
        }
    }

    private func extractExtension(from raw: String) -> String? {
        // file://, 絶対パス, ファイル名のどれでも抜き取れるよう URL に通す
        let candidate: URL?
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file://") {
            candidate = URL(string: trimmed)
        } else if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else if trimmed.hasPrefix("~") {
            candidate = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        } else {
            // 単独ファイル名 (例: "screenshot.png") もここに来る
            candidate = URL(fileURLWithPath: trimmed)
        }
        guard let url = candidate else { return nil }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
