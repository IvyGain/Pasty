import SwiftUI
import Charts
import GRDB

// MARK: - Data Models

/// 日別キャプチャ件数の集計行。
private struct DailyCount: Identifiable, Equatable {
    let id = UUID()
    let day: Date
    let count: Int
}

/// 種類別 (text / rich text / link / image / file / color / other) の集計行。
private struct KindCount: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let count: Int
}

/// アプリ別ランキング行。
private struct AppCount: Identifiable, Equatable {
    let id = UUID()
    let bundleId: String?
    let appName: String
    let count: Int
}

/// 「最も再利用されたクリップ」行(paste_events 集計ベース)。
/// 名称は歴史的経緯で `LongLivedClip` だが、v0.4.2 以降は貼付回数ベース。
private struct LongLivedClip: Identifiable, Equatable {
    let id: Int64
    let preview: String
    let pasteCount: Int
}

/// ダッシュボード全体のスナップショット。
private struct InsightsSnapshot: Equatable {
    var todayCount: Int = 0
    var weekCount: Int = 0
    var totalPasteEvents: Int = 0
    var daily: [DailyCount] = []
    var kinds: [KindCount] = []
    var apps: [AppCount] = []
    var longLived: [LongLivedClip] = []
}

// MARK: - Insights Dashboard

@MainActor
struct InsightsDashboard: View {
    @ObservedObject var store: ClipStore

    @State private var snapshot: InsightsSnapshot = .init()
    @State private var isLoading: Bool = true
    @State private var loadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView("読み込み中…")
                            .padding(.vertical, 40)
                        Spacer()
                    }
                } else if let err = loadError {
                    InsightsCard(title: "エラー") {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    summaryCard
                    dailyChartCard
                    kindDistributionCard
                    appRankingCard
                    longLivedClipsCard
                }
            }
            .padding(16)
        }
        .background(VisualEffectBackground())
        .task(id: store.totalCount) {
            await reload()
        }
    }

    // MARK: Cards

    private var summaryCard: some View {
        InsightsCard(title: "サマリー") {
            HStack(spacing: 12) {
                StatTile(
                    label: "今日",
                    value: snapshot.todayCount,
                    unit: "件",
                    accent: .accentColor
                )
                StatTile(
                    label: "今週",
                    value: snapshot.weekCount,
                    unit: "件",
                    accent: .blue
                )
                SavedTimeTile(pasteEvents: snapshot.totalPasteEvents)
            }
        }
    }

    private var dailyChartCard: some View {
        InsightsCard(title: "日別キャプチャ数（直近 14 日）") {
            if snapshot.daily.isEmpty {
                EmptyStateText("まだデータがありません")
            } else {
                Chart(snapshot.daily) { row in
                    BarMark(
                        x: .value("日付", row.day, unit: .day),
                        y: .value("件数", row.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 180)
            }
        }
    }

    private var kindDistributionCard: some View {
        InsightsCard(title: "種類別分布") {
            if snapshot.kinds.isEmpty {
                EmptyStateText("まだデータがありません")
            } else {
                Chart(snapshot.kinds) { row in
                    BarMark(
                        x: .value("件数", row.count),
                        y: .value("種類", row.label)
                    )
                    .foregroundStyle(by: .value("種類", row.label))
                    .cornerRadius(3)
                }
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(snapshot.kinds.count, 1)) * 28 + 20)
            }
        }
    }

    private var appRankingCard: some View {
        InsightsCard(title: "ソースアプリランキング（Top 10）") {
            if snapshot.apps.isEmpty {
                EmptyStateText("まだデータがありません")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snapshot.apps.enumerated()), id: \.element.id) { idx, row in
                        HStack(spacing: 10) {
                            Text("\(idx + 1).")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            appIcon(for: row.bundleId)
                                .frame(width: 18, height: 18)
                            Text(row.appName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Text("\(row.count) 件")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        if idx < snapshot.apps.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    /// v0.4.2: paste_events テーブルを集計した「最も再利用されたクリップ」Top 10。
    /// 旧フォールバック (createdAt ASC) は廃止。データが無い時は空状態を出す。
    private var longLivedClipsCard: some View {
        InsightsCard(title: "最も再利用されたクリップ（Top 10）") {
            if snapshot.longLived.isEmpty {
                EmptyStateText("貼付履歴がまだありません")
            } else {
                longLivedList
            }
        }
    }

    private var longLivedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(snapshot.longLived.enumerated()), id: \.element.id) { idx, clip in
                HStack(spacing: 10) {
                    Text("\(idx + 1).")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    Text(clip.preview)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text("\(clip.pasteCount) 回")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if idx < snapshot.longLived.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func appIcon(for bundleId: String?) -> some View {
        if let bid = bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Data Loading

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            let result = try await Self.loadSnapshot(dbWriter: store.dbWriter)
            self.snapshot = result
        } catch {
            self.loadError = error.localizedDescription
        }
        isLoading = false
    }

    nonisolated private static func loadSnapshot(dbWriter: any DatabaseWriter) async throws -> InsightsSnapshot {
        try await dbWriter.read { db in
            var snap = InsightsSnapshot()

            // Note: `paste_count` カラムは未実装のため、再利用回数ベースのランキングは
            // 取得できない。代わりに最古のクリップ 10 件を読み出す(UI 側で表示)。

            let calendar = Calendar.current
            let now = Date()
            let startOfToday = calendar.startOfDay(for: now)
            // 週の始まりはシステム Calendar に従う。
            let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday

            // 今日 / 今週
            // v0.9.6-beta (follow-up #3): exclude soft-deleted rows from every
            // clips aggregation so Insights doesn't keep counting tombstones.
            snap.todayCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM clips WHERE createdAt >= ? AND deleted_at IS NULL",
                arguments: [startOfToday]
            ) ?? 0
            snap.weekCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM clips WHERE createdAt >= ? AND deleted_at IS NULL",
                arguments: [startOfWeek]
            ) ?? 0

            // B7: 累計 paste_events 件数 (節約時間タイル用)
            snap.totalPasteEvents = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM paste_events"
            ) ?? 0

            // 直近 14 日 (日別集計)
            let from = calendar.date(byAdding: .day, value: -13, to: startOfToday) ?? startOfToday
            let dailyRows = try Row.fetchAll(db, sql: """
                SELECT date(createdAt) AS d, COUNT(*) AS c
                FROM clips
                WHERE createdAt >= ? AND deleted_at IS NULL
                GROUP BY d
                ORDER BY d ASC
                """, arguments: [from])

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC") // GRDB's date() uses UTC

            var counts: [Date: Int] = [:]
            for row in dailyRows {
                guard let dayStr: String = row["d"],
                      let parsed = formatter.date(from: dayStr) else { continue }
                // Re-anchor to local calendar start-of-day for the chart
                let localDay = calendar.startOfDay(for: parsed)
                counts[localDay] = row["c"]
            }
            var daily: [DailyCount] = []
            for i in 0..<14 {
                guard let day = calendar.date(byAdding: .day, value: i, to: from) else { continue }
                let dayStart = calendar.startOfDay(for: day)
                daily.append(DailyCount(day: dayStart, count: counts[dayStart] ?? 0))
            }
            snap.daily = daily

            // 種類別分布: ClipKind の raw を表示用ラベルにまとめる。
            let kindRows = try Row.fetchAll(db, sql: """
                SELECT kind, COUNT(*) AS c FROM clips
                WHERE deleted_at IS NULL
                GROUP BY kind
                """)
            var bucket: [String: Int] = [:]
            for row in kindRows {
                let raw: String = row["kind"] ?? "other"
                let count: Int = row["c"] ?? 0
                let label = displayLabel(forKindRaw: raw)
                bucket[label, default: 0] += count
            }
            snap.kinds = bucket
                .map { KindCount(label: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }

            // アプリ別 Top 10
            let appRows = try Row.fetchAll(db, sql: """
                SELECT sourceBundleId, sourceAppName, COUNT(*) AS c
                FROM clips
                WHERE deleted_at IS NULL
                GROUP BY COALESCE(sourceAppName, sourceBundleId, 'Unknown')
                ORDER BY c DESC
                LIMIT 10
                """)
            snap.apps = appRows.map { row in
                let bid: String? = row["sourceBundleId"]
                let name: String? = row["sourceAppName"]
                let cnt: Int = row["c"] ?? 0
                let display = name ?? bid ?? "Unknown"
                return AppCount(bundleId: bid, appName: display, count: cnt)
            }

            // 「最も再利用されたクリップ」Top 10
            //   = paste_events を clipId で集計し、件数 desc で 10 件。
            //   v0.4.2 で paste_events が入ったので、createdAt フォールバックは廃止。
            let longLivedRows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.preview, COUNT(pe.id) AS cnt
                FROM clips c
                JOIN paste_events pe ON pe.clipId = c.id
                WHERE c.deleted_at IS NULL
                GROUP BY c.id
                ORDER BY cnt DESC
                LIMIT 10
                """)
            snap.longLived = longLivedRows.compactMap { (row: Row) -> LongLivedClip? in
                guard let id: Int64 = row["id"] else { return nil }
                let preview: String = row["preview"] ?? ""
                let cnt: Int = row["cnt"] ?? 0
                return LongLivedClip(id: id, preview: preview, pasteCount: cnt)
            }

            return snap
        }
    }

    /// ClipKind raw → 表示ラベル。`richText` だけ "rich text" に整形し、
    /// それ以外は raw 値をそのまま使う(`text` / `link` / `image` / `file` / `color` / `other`)。
    /// 旧バージョンの未知 raw 値はすべて `other` に寄せる。
    nonisolated private static func displayLabel(forKindRaw raw: String) -> String {
        switch raw {
        case ClipKind.richText.rawValue: return "rich text"
        case ClipKind.text.rawValue,
             ClipKind.link.rawValue,
             ClipKind.image.rawValue,
             ClipKind.file.rawValue,
             ClipKind.color.rawValue,
             ClipKind.other.rawValue,
             ClipKind.video.rawValue:
            return raw
        default:
            return "other"
        }
    }
}

// MARK: - Reusable Sub-views

private struct InsightsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PastyTheme.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(PastyTheme.strokeOpacity), lineWidth: 1)
        )
    }
}

private struct StatTile: View {
    let label: String
    let value: Int
    let unit: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                Text(unit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.08))
        )
    }
}

/// B7: paste_events 件数 × 28 秒で「累計節約時間」をざっくり可視化するタイル。
/// 28 秒は「手動で履歴を辿って 1 件を貼り付けるのにかかる平均時間」のヒューリスティック。
private struct SavedTimeTile: View {
    let pasteEvents: Int

    private static let secondsPerPaste: Int = 28

    private var totalSeconds: Int { pasteEvents * Self.secondsPerPaste }

    private var formatted: String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .short
        if totalSeconds < 60 {
            return "\(totalSeconds) 秒"
        }
        return f.string(from: TimeInterval(totalSeconds)) ?? "0 分"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Text("節約時間")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            Text(formatted)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .help("1 回の貼付を約 \(Self.secondsPerPaste) 秒節約として換算した累計 (paste_events ベース)")
    }
}

private struct EmptyStateText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }
}
