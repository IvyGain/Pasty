import Foundation
import os

enum PerfLog {
    static var enabled: Bool = false
    private static let log = OSLog(subsystem: "io.pasty.perf", category: "hot-path")

    @discardableResult
    static func timing<T>(_ label: String, _ block: () throws -> T) rethrows -> T {
        guard enabled else { return try block() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        NSLog("[perf] \(label)=\(ms)ms")
        os_log("%{public}@=%dms", log: log, type: .info, label, ms)
        return result
    }

    /// v0.9.9-beta (B4): emit ad-hoc perf-only diagnostics (e.g. soft-delete
    /// density, table sizes). No-ops when `enabled` is false so production
    /// builds pay zero cost.
    static func log(_ msg: String) {
        guard enabled else { return }
        NSLog("[perf] \(msg)")
        os_log("%{public}@", log: log, type: .info, msg)
    }
}
