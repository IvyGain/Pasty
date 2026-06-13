import Foundation
import SwiftUI

/// Tiny diff engine — Wu-style LCS line diff used to compare two clips.
/// Not optimised; perfectly fine for the lengths a clipboard manager
/// actually deals with (kBs, not MBs).
enum DiffEngine {
    enum Op: Equatable {
        case keep(String)
        case insert(String)
        case delete(String)
    }

    static func diff(_ a: String, _ b: String) -> [Op] {
        let aLines = a.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let bLines = b.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let n = aLines.count, m = bLines.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                lcs[i + 1][j + 1] = aLines[i] == bLines[j]
                    ? lcs[i][j] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && aLines[i - 1] == bLines[j - 1] {
                ops.append(.keep(aLines[i - 1])); i -= 1; j -= 1
            } else if j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
                ops.append(.insert(bLines[j - 1])); j -= 1
            } else {
                ops.append(.delete(aLines[i - 1])); i -= 1
            }
        }
        return ops.reversed()
    }
}

struct DiffView: View {
    let left: ClipItem
    let right: ClipItem

    var body: some View {
        let ops = DiffEngine.diff(left.content ?? left.preview,
                                  right.content ?? right.preview)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(ops.enumerated()), id: \.offset) { _, op in
                    switch op {
                    case .keep(let s):
                        line(" \(s)", color: .secondary, bg: .clear)
                    case .insert(let s):
                        line("+\(s)", color: .green, bg: Color.green.opacity(0.12))
                    case .delete(let s):
                        line("-\(s)", color: .red, bg: Color.red.opacity(0.12))
                    }
                }
            }
            .padding(8)
        }
        .background(VisualEffectBackground())
        .frame(minWidth: 520, minHeight: 360)
    }

    private func line(_ s: String, color: Color, bg: Color) -> some View {
        Text(s.isEmpty ? " " : s)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(bg)
    }
}
