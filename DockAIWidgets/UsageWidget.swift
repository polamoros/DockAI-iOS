// tRPC: project.list, project.usage
import SwiftUI
import WidgetKit

/// The usage meters the web shows in its sidebar and on a project's Overview
/// (SidebarUsageFooter.tsx): per Claude account, the five-hour session window
/// and the weekly one, each with when it resets. Usage is per account, read
/// through a running project that uses it (`project.usage` needs a running
/// worker), so accounts with no running project are not shown — the same
/// rule as the web.
struct AccountUsage: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var sessionPct: Double?
    var sessionResetsAt: Date?
    var weeklyPct: Double?
    var weeklyResetsAt: Date?
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let accounts: [AccountUsage]
    /// Why there is nothing to show, when there is nothing.
    let note: String?
    /// True when the numbers are the last good ones, not fresh.
    var stale = false
}

enum UsageFetcher {
    private static var defaults: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "DockAIAppGroup") as? String).flatMap(UserDefaults.init(suiteName:))
    }

    static func fetch() async -> UsageEntry {
        guard let credentials = Credentials.load() else {
            return UsageEntry(date: .now, accounts: [], note: "Open DockAI to pair this iPhone.")
        }
        let api = TRPCClient(credentials: credentials)
        do {
            let projects = try await api.query("project.list").array
            var seen = Set<String>()
            var picks: [(slug: String, accountId: String, name: String)] = []
            for p in projects where p["status"].string == "RUNNING" {
                guard let acc = p["claudeAccountId"].string, !seen.contains(acc), let slug = p["slug"].string else { continue }
                seen.insert(acc)
                picks.append((slug, acc, p["claudeAccount"]["label"].string ?? "Claude"))
            }
            var accounts: [AccountUsage] = []
            for pick in picks {
                guard let u = try? await api.query("project.usage", .from(["slug": pick.slug])), !u.isNull, u["source"].string != "error" else { continue }
                let s = u["fiveHour"], w = u["sevenDay"]
                if s.isNull && w.isNull { continue }
                accounts.append(AccountUsage(
                    id: pick.accountId, name: pick.name,
                    sessionPct: s["utilization"].double, sessionResetsAt: s["resetsAt"].date,
                    weeklyPct: w["utilization"].double, weeklyResetsAt: w["resetsAt"].date))
            }
            if let data = try? JSONEncoder().encode(accounts) { defaults?.set(data, forKey: "widget.usage") }
            return UsageEntry(date: .now, accounts: accounts, note: accounts.isEmpty ? "No running project to read usage through." : nil)
        } catch {
            // Keep showing the last numbers rather than a blank widget.
            if let data = defaults?.data(forKey: "widget.usage"), let last = try? JSONDecoder().decode([AccountUsage].self, from: data), !last.isEmpty {
                return UsageEntry(date: .now, accounts: last, note: nil, stale: true)
            }
            return UsageEntry(date: .now, accounts: [], note: error.localizedDescription)
        }
    }
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, accounts: [AccountUsage(id: "p", name: "Claude", sessionPct: 42, sessionResetsAt: .now.addingTimeInterval(7200), weeklyPct: 18, weeklyResetsAt: .now.addingTimeInterval(86400 * 3))], note: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await UsageFetcher.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let entry = await UsageFetcher.fetch()
            // The server caches usage for five minutes; a quarter hour is plenty for a glance.
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DockAIUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude usage")
        .description("Each Claude account's session and weekly usage, and when they reset.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("DockAI", systemImage: "gauge.medium").font(.caption.weight(.semibold))
                Text(entry.note ?? "No usage yet.").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let shown = Array(entry.accounts.prefix(family == .systemSmall ? 1 : 2))
            VStack(alignment: .leading, spacing: 8) {
                if family == .systemSmall {
                    account(shown[0], showName: entry.accounts.count > 1)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(shown) { a in account(a, showName: true).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                Spacer(minLength: 0)
                if entry.stale {
                    Text("Last known · \(entry.date, style: .time)").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func account(_ a: AccountUsage, showName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(showName ? a.name : "Claude usage").font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary).lineLimit(1)
            if let p = a.sessionPct { meter("Session", p, a.sessionResetsAt) }
            if let p = a.weeklyPct { meter("Weekly", p, a.weeklyResetsAt) }
        }
    }

    private func meter(_ label: String, _ pct: Double, _ resets: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(pct.rounded()))%").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(meterColor(pct))
            }
            ProgressView(value: min(max(pct, 0), 100), total: 100).tint(meterColor(pct))
            if let resets, resets > .now {
                (Text("Resets in ") + Text(resets, style: .relative)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// The web's thresholds for a usage colour: accent, warning from 70%, danger from 90% (ui/meter.tsx).
    private func meterColor(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 70 ? .orange : .accentColor }
}
