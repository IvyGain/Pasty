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
}
