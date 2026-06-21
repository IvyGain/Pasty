import XCTest
import GRDB
@testable import Pasty

final class ClipStoreTests: XCTestCase {
    @MainActor
    func testInsertPersistsAndDedupes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        let dbWriter = try DatabaseQueue(path: dbURL.path)
        let store = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)

        let item = ClipItem(
            id: nil,
            createdAt: Date(),
            kind: .text,
            preview: "hello",
            content: "hello",
            dataPath: nil,
            byteSize: 5,
            sourceBundleId: nil,
            sourceAppName: nil,
            contentHash: "abc"
        )

        let inserted = try await store.insert(item)
        XCTAssertNotNil(inserted)
        XCTAssertEqual(store.recent.count, 1)
        XCTAssertEqual(store.totalCount, 1)

        // Same hash, expected dedupe.
        let duplicate = try await store.insert(item)
        XCTAssertNil(duplicate)
        XCTAssertEqual(store.totalCount, 1)
    }

    @MainActor
    func testFTS5SearchFindsByContent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        let dbWriter = try DatabaseQueue(path: dbURL.path)
        let store = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)

        try await store.insert(.init(
            id: nil, createdAt: Date(), kind: .text,
            preview: "Pasty is fast", content: "Pasty is fast and OSS",
            dataPath: nil, byteSize: 21, sourceBundleId: nil, sourceAppName: nil,
            contentHash: "h1"
        ))
        try await store.insert(.init(
            id: nil, createdAt: Date(), kind: .text,
            preview: "Unrelated note", content: "Unrelated note about ramen",
            dataPath: nil, byteSize: 28, sourceBundleId: nil, sourceAppName: nil,
            contentHash: "h2"
        ))

        let hits = try await store.search(query: "Pasty")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.preview, "Pasty is fast")
    }

    /// v0.9.5-beta (B6): OCR でタグ付けされた画像クリップが FTS5 検索で
    /// ヒットすることを確認する。migration v8 が clips_fts に
    /// extractedOCRText を含めていることの統合テスト。
    @MainActor
    func testFTS5SearchHitsExtractedOCRText() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        let dbWriter = try DatabaseQueue(path: dbURL.path)
        let store = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)

        // 画像クリップを 1 件挿入。preview/content は OCR キーワードを含まない。
        try await store.insert(.init(
            id: nil, createdAt: Date(), kind: .image,
            preview: "Image 128 KB", content: nil,
            dataPath: "images/abc.png", byteSize: 131072,
            sourceBundleId: nil, sourceAppName: nil,
            contentHash: "img-hash-1"
        ))
        guard let inserted = store.recent.first, let id = inserted.id else {
            XCTFail("expected an inserted image clip"); return
        }

        // 検索キーワードが preview/content に居ないことを最初に確認。
        let before = try await store.search(query: "quarterly")
        XCTAssertTrue(before.isEmpty, "should not hit before OCR text is attached")

        // OCR 結果を後付け。trigger 経由で clips_fts も更新されるはず。
        try await store.updateOCRText(clipId: id, text: "Quarterly revenue dashboard, Q3 results")

        let hits = try await store.search(query: "quarterly")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, id)
        XCTAssertEqual(hits.first?.extractedOCRText, "Quarterly revenue dashboard, Q3 results")
    }

    /// v0.9.5-beta (B3): cleanupOld がアプリ別ルールとグローバル既定を
    /// 期待通りに分岐させることを検証する。
    ///
    /// シナリオ:
    /// - `com.slack`: rule で 1 日保持 → 古い slack クリップは soft delete
    /// - `com.notes`: rule で -1 (無期限) → 古い notes クリップは保護される
    /// - `com.other`: rule なし → グローバル 7 日にぶつかって soft delete
    /// - 新しい (1時間前) クリップは全て生き残る
    @MainActor
    func testCleanupOldRespectsPerAppRules() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        let dbWriter = try DatabaseQueue(path: dbURL.path)
        let store = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)

        // backdated rows を直接 SQL で seed する (insert() は now を強制するため)。
        // createdAt は ISO-8601 で比較されるので Date 値で渡せば lexicographic で OK。
        let now = Date()
        let tenDaysAgo  = now.addingTimeInterval(-10 * 86400)
        let oneHourAgo  = now.addingTimeInterval(-3600)

        func seed(createdAt: Date, bundleId: String?, hash: String) throws {
            try dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO clips
                    (createdAt, kind, preview, content, byteSize,
                     sourceBundleId, sourceAppName, contentHash, updated_at)
                    VALUES (?, 'text', ?, ?, ?, ?, ?, ?, 0)
                    """, arguments: [
                        createdAt, hash, hash, Int64(hash.utf8.count),
                        bundleId, bundleId, hash
                    ])
            }
        }

        try seed(createdAt: tenDaysAgo, bundleId: "com.slack", hash: "old-slack")
        try seed(createdAt: oneHourAgo, bundleId: "com.slack", hash: "new-slack")
        try seed(createdAt: tenDaysAgo, bundleId: "com.notes", hash: "old-notes")
        try seed(createdAt: tenDaysAgo, bundleId: "com.other", hash: "old-other")
        try seed(createdAt: oneHourAgo, bundleId: "com.other", hash: "new-other")
        try seed(createdAt: tenDaysAgo, bundleId: nil,          hash: "old-null")

        let rules: [PerAppRetentionRule] = [
            PerAppRetentionRule(bundleId: "com.slack", days: 1),
            PerAppRetentionRule(bundleId: "com.notes", days: -1)   // 無期限
        ]
        let affected = try await store.cleanupOld(globalDays: 7, perAppRules: rules)

        // 期待: old-slack (slack rule)、old-other (global)、old-null (global) → 3 件
        XCTAssertEqual(affected, 3, "expected 3 soft-deletes (old-slack, old-other, old-null)")

        // どの hash が deleted_at をセットされたか直接検証
        let deletedHashes: Set<String> = try await dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT contentHash FROM clips WHERE deleted_at IS NOT NULL")
            return Set(rows.compactMap { $0["contentHash"] as String? })
        }
        XCTAssertEqual(deletedHashes, ["old-slack", "old-other", "old-null"])

        let aliveHashes: Set<String> = try await dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT contentHash FROM clips WHERE deleted_at IS NULL")
            return Set(rows.compactMap { $0["contentHash"] as String? })
        }
        // old-notes は -1 (無期限) で保護、new-slack / new-other は若くて保護
        XCTAssertEqual(aliveHashes, ["new-slack", "old-notes", "new-other"])
    }

    /// globalDays <= 0 かつ perAppRules も全件無期限なら、何も削除されない。
    @MainActor
    func testCleanupOldNoOpWhenAllInfinite() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        let dbWriter = try DatabaseQueue(path: dbURL.path)
        let store = try ClipStore(dbWriter: dbWriter, blobDirectory: tempDir)

        try await store.insert(.init(
            id: nil, createdAt: Date().addingTimeInterval(-365 * 86400),
            kind: .text, preview: "ancient", content: "ancient", dataPath: nil,
            byteSize: 7, sourceBundleId: "com.slack", sourceAppName: "Slack",
            contentHash: "ancient-1"
        ))

        let affected = try await store.cleanupOld(
            globalDays: -1,   // 無期限 (= グローバル cleanup 無効)
            perAppRules: [PerAppRetentionRule(bundleId: "com.slack", days: -1)]
        )
        XCTAssertEqual(affected, 0)

        let aliveCount: Int = try await dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips WHERE deleted_at IS NULL") ?? -1
        }
        XCTAssertEqual(aliveCount, 1)
    }
}
