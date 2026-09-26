// tRPC: device.pending
import SwiftUI
import WidgetKit

/// Two complications (openspec/changes/watch-app): how many things are
/// waiting on the person, and the weekly usage. The watch app writes both
/// into the app group after each refresh and reloads these timelines; the
/// timeline also asks the server for the count itself every 15 minutes.
struct WatchEntry: TimelineEntry {
    let date: Date
    let needsYou: Int?
    let weeklyPct: Double?
}

private enum Shared {
    static var defaults: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "DockAIAppGroup") as? String).flatMap(UserDefaults.init(suiteName:))
    }
    static func stored() -> WatchEntry {
        let d = defaults
        let hasCount = d?.object(forKey: "watch.needsYou") != nil
        let hasWeekly = d?.object(forKey: "watch.weekly") != nil
        return WatchEntry(date: .now, needsYou: hasCount ? d?.integer(forKey: "watch.needsYou") : nil, weeklyPct: hasWeekly ? d?.double(forKey: "watch.weekly") : nil)
    }
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: .now, needsYou: 2, weeklyPct: 42) }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Shared.stored())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        Task {
            var entry = Shared.stored()
            if let c = Credentials.load(), let p = try? await TRPCClient(credentials: c).query("device.pending") {
                let n = p["permissions"].array.count + p["questions"].array.count + p["blocked"].array.count
                Shared.defaults?.set(n, forKey: "watch.needsYou")
                entry = WatchEntry(date: .now, needsYou: n, weeklyPct: entry.weeklyPct)
            }
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}

struct NeedsYouComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DockAINeedsYou", provider: WatchProvider()) { e in
            NeedsYouFace(entry: e).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Needs you")
        .description("What is waiting on you in DockAI.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

struct WeeklyUsageComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DockAIWeekly", provider: WatchProvider()) { e in
            WeeklyFace(entry: e).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Weekly usage")
        .description("Your Claude weekly usage.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

private struct NeedsYouFace: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchEntry
    var body: some View {
        let n = entry.needsYou
        switch family {
        case .accessoryInline:
            Text(n.map { $0 == 0 ? "DockAI: nothing waiting" : "DockAI: \($0) waiting" } ?? "DockAI")
        case .accessoryCorner:
            Image(systemName: (n ?? 0) > 0 ? "hand.raised.fill" : "checkmark.circle")
                .widgetLabel(n.map { "\($0) waiting" } ?? "DockAI")
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: (n ?? 0) > 0 ? "hand.raised.fill" : "checkmark").font(.caption)
                    Text(n.map(String.init) ?? "–").font(.title3.monospacedDigit().bold())
                }
            }
        }
    }
}

private struct WeeklyFace: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchEntry
    var body: some View {
        let pct = entry.weeklyPct
        let text = pct.map { "\(Int($0.rounded()))%" } ?? "–"
        switch family {
        case .accessoryInline:
            Text("Claude week \(text)")
        case .accessoryCorner:
            Text(text).widgetLabel { Gauge(value: min(max(pct ?? 0, 0), 100), in: 0...100) { Text("Week") } }
        default:
            Gauge(value: min(max(pct ?? 0, 0), 100), in: 0...100) { Text("Week") } currentValueLabel: { Text(text) }
                .gaugeStyle(.accessoryCircularCapacity)
        }
    }
}

/// One tap from the watch face to Ask (`dockai://ask`).
struct AskComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DockAIAsk", provider: WatchProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title3)
            }
            .widgetURL(URL(string: "dockai://ask"))
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Ask")
        .description("Speak to Claude in a project.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

@main
struct DockAIWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        NeedsYouComplication()
        WeeklyUsageComplication()
        AskComplication()
    }
}
