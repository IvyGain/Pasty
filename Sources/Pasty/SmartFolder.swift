import Foundation
import Combine

// MARK: - SmartFolder

/// A saved dynamic search expressed as a `SearchQuery` DSL string.
///
/// Built-in folders (today, week, images, links, code, snippets, large) are
/// hard-coded and always present. User-defined folders are persisted as JSON
/// in `UserDefaults` under `pasty.smartFolders.custom`.
public struct SmartFolder: Identifiable, Hashable, Codable {
    public let id: String          // built-in: "today", "week", ... / user: UUID
    public var name: String        // 日本語表示名
    public var colorHex: String
    public var systemImage: String // SF Symbol
    public var query: String       // DSL: "type:image source:Safari >7d"
    public var isBuiltIn: Bool
    public var sortOrder: Int

    public init(
        id: String,
        name: String,
        colorHex: String,
        systemImage: String,
        query: String,
        isBuiltIn: Bool,
        sortOrder: Int
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.systemImage = systemImage
        self.query = query
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }
}

// MARK: - Built-in catalogue

extension SmartFolder {
    /// IDs of the seven hard-coded built-in folders.
    public enum BuiltInID {
        public static let today    = "today"
        public static let week     = "week"
        public static let images   = "images"
        public static let links    = "links"
        public static let code     = "code"
        public static let snippets = "snippets"
        public static let large    = "large"
    }

    /// The seven built-in smart folders, in display order.
    public static let builtIns: [SmartFolder] = [
        SmartFolder(
            id: BuiltInID.today,
            name: "今日",
            colorHex: "#5AC8FA",
            systemImage: "calendar",
            // SearchEngine treats `>Nd` as "within the last N days".
            // "Today" == within the last 1 day.
            query: ">1d",
            isBuiltIn: true,
            sortOrder: 0
        ),
        SmartFolder(
            id: BuiltInID.week,
            name: "今週",
            colorHex: "#34C759",
            systemImage: "calendar.badge.clock",
            query: ">7d",
            isBuiltIn: true,
            sortOrder: 1
        ),
        SmartFolder(
            id: BuiltInID.images,
            name: "画像",
            colorHex: "#FF375F",
            systemImage: "photo",
            query: "type:image",
            isBuiltIn: true,
            sortOrder: 2
        ),
        SmartFolder(
            id: BuiltInID.links,
            name: "リンク",
            colorHex: "#BF5AF2",
            systemImage: "link",
            query: "type:link",
            isBuiltIn: true,
            sortOrder: 3
        ),
        SmartFolder(
            id: BuiltInID.code,
            name: "コード",
            colorHex: "#FF9F0A",
            systemImage: "chevron.left.forwardslash.chevron.right",
            query: "type:code",
            isBuiltIn: true,
            sortOrder: 4
        ),
        SmartFolder(
            id: BuiltInID.snippets,
            name: "定型文",
            colorHex: "#FFD60A",
            systemImage: "text.badge.checkmark",
            query: "source:Pasty",
            isBuiltIn: true,
            sortOrder: 5
        ),
        SmartFolder(
            id: BuiltInID.large,
            name: "大容量",
            colorHex: "#86868B",
            systemImage: "archivebox",
            // Empty query => fetch all recent; the store applies a >100KB
            // byteSize filter as a post-processing step.
            query: "",
            isBuiltIn: true,
            sortOrder: 6
        )
    ]
}

// MARK: - Store

/// In-memory + UserDefaults-backed registry of smart folders.
///
/// Built-in folders are always present and never persisted; only custom
/// folders are written to `UserDefaults`. Mutating APIs reject changes that
/// target built-in folders (rename / setColor / delete / reorder will
/// silently no-op when the target is built-in, except `reorder` which
/// operates on the merged list and persists the resulting custom order).
@MainActor
public final class SmartFolderStore: ObservableObject {
    public static let shared = SmartFolderStore()

    @Published public private(set) var folders: [SmartFolder]

    private let defaults: UserDefaults
    private let storageKey = "pasty.smartFolders.custom"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let custom = Self.loadCustom(from: defaults, key: storageKey)
        self.folders = Self.merge(builtIns: SmartFolder.builtIns, custom: custom)
    }

    // MARK: Mutations

    /// Create a new user-defined smart folder.
    public func createCustom(name: String, colorHex: String, query: String) {
        let nextOrder = (folders.map { $0.sortOrder }.max() ?? -1) + 1
        let folder = SmartFolder(
            id: UUID().uuidString,
            name: name,
            colorHex: colorHex,
            systemImage: "folder",
            query: query,
            isBuiltIn: false,
            sortOrder: nextOrder
        )
        folders.append(folder)
        sortAndPersist()
    }

    public func rename(id: String, to newName: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }),
              !folders[idx].isBuiltIn else { return }
        folders[idx].name = newName
        sortAndPersist()
    }

    public func setColor(id: String, to colorHex: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }),
              !folders[idx].isBuiltIn else { return }
        folders[idx].colorHex = colorHex
        sortAndPersist()
    }

    public func delete(id: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }),
              !folders[idx].isBuiltIn else { return }
        folders.remove(at: idx)
        sortAndPersist()
    }

    /// Reorder the merged folder list. Sort orders are reassigned densely
    /// from 0..<count, and the resulting order is persisted for custom
    /// folders (built-ins keep their hard-coded identity but inherit the new
    /// numeric sortOrder so subsequent sorts behave as expected).
    public func reorder(from source: Int, to destination: Int) {
        guard folders.indices.contains(source) else { return }
        let clampedDestination = max(0, min(destination, folders.count - 1))
        guard source != clampedDestination else { return }

        let moved = folders.remove(at: source)
        folders.insert(moved, at: clampedDestination)

        for i in folders.indices {
            folders[i].sortOrder = i
        }
        persist()
    }

    // MARK: Dynamic evaluation

    /// Evaluate the folder's DSL query against the live `ClipStore`.
    ///
    /// The "large" built-in additionally filters by `byteSize > 100 KiB`
    /// after the search engine returns its candidates.
    func items(for folder: SmartFolder, store: ClipStore) async throws -> [ClipItem] {
        let parsed = SearchQuery.parse(folder.query)
        var results = try await SearchEngine.run(parsed, store: store)
        if folder.id == SmartFolder.BuiltInID.large {
            results = results.filter { $0.byteSize > 100 * 1024 }
        }
        return results
    }

    // MARK: Persistence

    private static func loadCustom(from defaults: UserDefaults, key: String) -> [SmartFolder] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([SmartFolder].self, from: data)
            // Defensive: drop any rows that look like built-ins.
            return decoded.filter { !$0.isBuiltIn }
        } catch {
            return []
        }
    }

    private func persist() {
        let custom = folders.filter { !$0.isBuiltIn }
        do {
            let data = try JSONEncoder().encode(custom)
            defaults.set(data, forKey: storageKey)
        } catch {
            // Encoding failure on plain Codable types is not expected; ignore.
        }
    }

    private func sortAndPersist() {
        folders.sort { $0.sortOrder < $1.sortOrder }
        persist()
    }

    private static func merge(builtIns: [SmartFolder], custom: [SmartFolder]) -> [SmartFolder] {
        let combined = builtIns + custom
        return combined.sorted { $0.sortOrder < $1.sortOrder }
    }
}
