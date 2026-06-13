import Foundation
import CryptoKit

public struct LinkMetadata: Equatable, Codable {
    public let title: String?
    public let host: String
    public let faviconURL: URL?
    public let description: String?

    public init(title: String?, host: String, faviconURL: URL?, description: String?) {
        self.title = title
        self.host = host
        self.faviconURL = faviconURL
        self.description = description
    }
}

@MainActor
final class LinkMetadataFetcher {
    static let shared = LinkMetadataFetcher()

    // LRU memory cache (cap 128). Order-preserving keys for eviction.
    private var memoryCache: [URL: LinkMetadata] = [:]
    private var lruOrder: [URL] = []
    private let memoryCap = 128

    // Disk cache: 7-day TTL
    private let diskTTL: TimeInterval = 7 * 24 * 60 * 60
    private let diskCacheDir: URL

    // In-flight task sharing to coalesce concurrent fetches for the same URL.
    private var inFlight: [URL: Task<LinkMetadata?, Never>] = [:]

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("Pasty/link-cache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.diskCacheDir = dir
    }

    func fetch(url: URL) async -> LinkMetadata? {
        // Memory cache
        if let cached = memoryCache[url] {
            touchLRU(url)
            return cached
        }

        // Disk cache
        if let disk = loadFromDisk(url: url) {
            store(url: url, metadata: disk)
            return disk
        }

        // Coalesce in-flight
        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<LinkMetadata?, Never> { [weak self] in
            guard let self else { return nil }
            let result = await Self.performFetch(url: url)
            await MainActor.run {
                if let result {
                    self.store(url: url, metadata: result)
                    self.saveToDisk(url: url, metadata: result)
                }
                self.inFlight[url] = nil
            }
            return result
        }
        inFlight[url] = task
        return await task.value
    }

    // MARK: - LRU bookkeeping

    private func store(url: URL, metadata: LinkMetadata) {
        memoryCache[url] = metadata
        touchLRU(url)
        while lruOrder.count > memoryCap {
            let evict = lruOrder.removeFirst()
            memoryCache.removeValue(forKey: evict)
        }
    }

    private func touchLRU(_ url: URL) {
        if let idx = lruOrder.firstIndex(of: url) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(url)
    }

    // MARK: - Disk cache

    private func diskPath(for url: URL) -> URL {
        let key = sha256(url.absoluteString)
        return diskCacheDir.appendingPathComponent("\(key).json")
    }

    private func loadFromDisk(url: URL) -> LinkMetadata? {
        let path = diskPath(for: url)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        if Date().timeIntervalSince(mtime) > diskTTL {
            try? fm.removeItem(at: path)
            return nil
        }
        guard let data = try? Data(contentsOf: path),
              let meta = try? JSONDecoder().decode(LinkMetadata.self, from: data) else {
            return nil
        }
        return meta
    }

    private func saveToDisk(url: URL, metadata: LinkMetadata) {
        let path = diskPath(for: url)
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: path, options: .atomic)
        }
    }

    private func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Network + parsing

    private static func performFetch(url: URL) async -> LinkMetadata? {
        guard let host = url.host, !host.isEmpty else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Pasty/0.4", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let session = URLSession.shared
        let html: String
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // Even on non-2xx, fall back to host-level metadata below.
                return hostFallback(host: host, url: url)
            }
            // Only the first 64KB matters — <title>/<meta> live in <head>.
            let prefix = data.prefix(64 * 1024)
            // Try UTF-8 first, then latin1 as a permissive fallback.
            if let s = String(data: prefix, encoding: .utf8) {
                html = s
            } else if let s = String(data: prefix, encoding: .isoLatin1) {
                html = s
            } else {
                return hostFallback(host: host, url: url)
            }
        } catch {
            return nil
        }

        let title = extractTitle(from: html)
        let description = extractDescription(from: html)
        let favicon = extractFavicon(from: html, baseURL: url) ?? defaultFavicon(host: host)

        return LinkMetadata(
            title: title,
            host: host,
            faviconURL: favicon,
            description: description
        )
    }

    private static func hostFallback(host: String, url: URL) -> LinkMetadata {
        LinkMetadata(
            title: nil,
            host: host,
            faviconURL: defaultFavicon(host: host),
            description: nil
        )
    }

    private static func defaultFavicon(host: String) -> URL? {
        URL(string: "https://\(host)/favicon.ico")
    }

    // MARK: - HTML extraction (naive regex)

    private static func extractTitle(from html: String) -> String? {
        // Prefer og:title — usually cleaner than <title>.
        if let og = extractMetaContent(html: html, propertyOrName: "og:title") {
            return decodeEntities(og).trimmed()
        }
        let pattern = #"<title[^>]*>([\s\S]*?)</title>"#
        if let match = firstCaptureGroup(in: html, pattern: pattern) {
            return decodeEntities(match).trimmed()
        }
        return nil
    }

    private static func extractDescription(from html: String) -> String? {
        if let og = extractMetaContent(html: html, propertyOrName: "og:description") {
            return decodeEntities(og).trimmed()
        }
        if let desc = extractMetaContent(html: html, propertyOrName: "description") {
            return decodeEntities(desc).trimmed()
        }
        return nil
    }

    /// Finds a `<meta>` tag where either `property=` or `name=` equals `key` and returns its `content=`.
    private static func extractMetaContent(html: String, propertyOrName key: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        // Two orderings: content before property/name, or after. Try both.
        let patterns = [
            #"<meta[^>]+(?:property|name)\s*=\s*["']\#(escapedKey)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*>"#,
            #"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']\#(escapedKey)["'][^>]*>"#
        ]
        for pat in patterns {
            if let value = firstCaptureGroup(in: html, pattern: pat) {
                return value
            }
        }
        return nil
    }

    private static func extractFavicon(from html: String, baseURL: URL) -> URL? {
        // <link rel="icon" ...> with rel possibly "shortcut icon", "apple-touch-icon", etc.
        let patterns = [
            #"<link[^>]+rel\s*=\s*["'][^"']*\bicon\b[^"']*["'][^>]*href\s*=\s*["']([^"']+)["'][^>]*>"#,
            #"<link[^>]+href\s*=\s*["']([^"']+)["'][^>]*rel\s*=\s*["'][^"']*\bicon\b[^"']*["'][^>]*>"#
        ]
        for pat in patterns {
            if let href = firstCaptureGroup(in: html, pattern: pat) {
                return resolveURL(href: decodeEntities(href).trimmed(), base: baseURL)
            }
        }
        return nil
    }

    private static func resolveURL(href: String, base: URL) -> URL? {
        if href.hasPrefix("//") {
            return URL(string: "https:\(href)")
        }
        if let abs = URL(string: href), abs.scheme != nil {
            return abs
        }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }

    // MARK: - Regex + entity helpers

    private static func firstCaptureGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " ")
        ]
        for (k, v) in entities {
            out = out.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
        }
        // Numeric entities: &#1234; and &#x1A2B;
        out = decodeNumericEntities(out)
        return out
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 10 {
                let inner = s[s.index(after: i)..<semi]
                if inner.hasPrefix("#") {
                    let numPart = inner.dropFirst()
                    var scalar: UInt32?
                    if numPart.first == "x" || numPart.first == "X" {
                        scalar = UInt32(numPart.dropFirst(), radix: 16)
                    } else {
                        scalar = UInt32(numPart, radix: 10)
                    }
                    if let code = scalar, let us = Unicode.Scalar(code) {
                        result.append(Character(us))
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            result.append(s[i])
            i = s.index(after: i)
        }
        return result
    }
}

private extension String {
    func trimmed() -> String {
        let collapsed = self.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
