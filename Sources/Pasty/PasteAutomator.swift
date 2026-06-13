import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Writes a `ClipItem`'s payload back to the system pasteboard and then
/// posts `⌘V` to whichever app was frontmost before our panel appeared.
@MainActor
final class PasteAutomator {
    static let shared = PasteAutomator()
    private init() {}

    /// Returns true once Accessibility permission has been granted; false
    /// otherwise. Prompts the user the first time it's called.
    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Place `item` on the system pasteboard and (optionally) emit ⌘V to
    /// the frontmost application. `asPlainText` strips RTF and just keeps
    /// the plain string content.
    func paste(_ item: ClipItem, asPlainText: Bool = false, autoPaste: Bool = true) {
        place(item, asPlainText: asPlainText)
        guard autoPaste else { return }
        emitCommandV()
    }

    private func place(_ item: ClipItem, asPlainText: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text, .richText, .link, .color, .other:
            if let s = item.content {
                pb.setString(s, forType: .string)
                if item.kind == .richText, !asPlainText, let data = s.data(using: .utf8) {
                    pb.setData(data, forType: .rtf)
                }
            } else {
                pb.setString(item.preview, forType: .string)
            }
        case .file:
            if let s = item.content, let url = URL(string: s) {
                if url.isFileURL {
                    pb.writeObjects([url as NSURL])
                } else {
                    pb.setString(s, forType: .string)
                }
            }
        case .image:
            // P0 stored only metadata for images; once blob persistence ships
            // (P2 finish), we'll read the file and place it on the pasteboard.
            if let p = item.dataPath {
                let url = ClipBlobs.blobURL(for: p)
                if let data = try? Data(contentsOf: url) {
                    pb.setData(data, forType: .tiff)
                }
            }
        }
    }

    private func emitCommandV() {
        // Give the receiving app a beat to refocus after our panel closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src,
                               virtualKey: CGKeyCode(kVK_ANSI_V),
                               keyDown: true)
            down?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: src,
                             virtualKey: CGKeyCode(kVK_ANSI_V),
                             keyDown: false)
            up?.flags = .maskCommand
            up?.post(tap: .cghidEventTap)
        }
    }
}

/// Resolves blob paths used for binary (image / file) clips.
enum ClipBlobs {
    static var directory: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        return appSupport
            .appendingPathComponent("Pasty", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
    }

    static func blobURL(for relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }
}
