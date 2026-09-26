// tRPC: project.claudeInfo, project.usage, project.usageHistory
import SwiftUI

/// One card for Claude: who is signed in, on what plan and CLI version; the
/// session and weekly meters; then, behind disclosures, the rest of usage
/// (per-model windows, extra usage, history) and what this project spent.
struct OverviewClaudeCard: View {
    let slug: String
    let accountLabel: String?
    @EnvironmentObject var model: AppModel
    @State private var info: JSON?
    @State private var infoError: Error?
    @State private var usage: JSON?
    @State private var usageError: Error?
    @State private var usageFetched: Date?
    @State private var showUsage = false
    @State private var showProject = false

    var body: some View {
        ProjCard("Claude", systemImage: "sparkles") {
            if info == nil && infoError == nil { ProgressView() }
        } content: {
            if let infoError, info == nil {
                ErrorBanner(error: infoError) { Task { await loadInfo() } }
            } else if let info {
                header(info)
                if info["authenticated"].bool == false {
                    Text("Not signed in — sign this account in under Settings → Claude accounts.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            meters
            DisclosureGroup("Usage", isExpanded: $showUsage) {
                UsageDetailsView(usage: usage, fetched: usageFetched, reload: { Task { await loadUsage() } })
                    .padding(.top, 6)
            }.font(.subheadline)
            if let info {
                DisclosureGroup("This project", isExpanded: $showProject) {
                    ProjectTokenStats(info: info).padding(.top, 6)
                }.font(.subheadline)
            }
        }
        .task {
            // Who is signed in rarely changes; a minute is plenty.
            while !Task.isCancelled {
                await loadInfo()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .task {
            while !Task.isCancelled {
                await loadUsage()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    private static let windows: [(String, String)] = [
        ("fiveHour", "Session"), ("sevenDay", "Weekly"), ("sevenDaySonnet", "Sonnet"),
        ("sevenDayOpus", "Opus"), ("sevenDayOauthApps", "OAuth apps"),
    ]

    private func header(_ info: JSON) -> some View {
        HStack(spacing: 6) {
            if let accountLabel { Text(accountLabel).lineLimit(1) }
            if let plan = info["subscription"].string { Text(ProjPlanLabel.label(plan)) }
            if let v = info["claudeVersion"].string {
                Text(v).font(.caption.monospaced())
                if info["isLatest"].bool == true { StatePill(text: "Latest", tone: .ok) }
                else if info["latestVersion"].string != nil { StatePill(text: "Update available", tone: .warn) }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var meters: some View {
        if let usage {
            if usage["source"].string == "error" {
                Text(usage["error"].string ?? "Usage is unavailable right now.").font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Self.windows.indices, id: \.self) { i in
                        let item = Self.windows[i]
                        let w = usage[item.0]
                        if let pct = w["utilization"].double {
                            ProjMeter(label: item.1, pct: pct, caption: w["resetsIn"].string.map { "Resets in \($0)" })
                        }
                    }
                    ForEach(usage["scoped"].array, id: \.self) { w in
                        if let pct = w["utilization"].double {
                            ProjMeter(label: w["name"].string ?? "Model", pct: pct, caption: w["resetsIn"].string.map { "Resets in \($0)" })
                        }
                    }
                }
            }
        } else if let usageError {
            ErrorBanner(error: usageError) { Task { await loadUsage() } }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func loadInfo() async {
        guard let api = model.api else { return }
        do {
            let v = try await api.query("project.claudeInfo", .from(["slug": slug]))
            if v.isNull { infoError = TRPCError(code: "EMPTY", message: "The worker did not answer about Claude.") }
            else { info = v; infoError = nil }
        } catch { infoError = error }
    }

    private func loadUsage() async {
        guard let api = model.api else { return }
        do {
            let v = try await api.query("project.usage", .from(["slug": slug]))
            if v.isNull { usageError = TRPCError(code: "EMPTY", message: "Usage could not be read from the worker.") }
            else { usage = v; usageError = nil; usageFetched = .now }
        } catch { usageError = error }
    }
}

/// The CLI's plan identifiers as words (`default_claude_max_20x` → "Max 20x").
enum ProjPlanLabel {
    static func label(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("max") && s.contains("20x") { return "Max 20x" }
        if s.contains("max") && s.contains("5x") { return "Max 5x" }
        if s.contains("max") { return "Max" }
        if s.contains("pro") { return "Pro" }
        if s.contains("team") { return "Team" }
        if s.contains("enterprise") { return "Enterprise" }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// The rest of usage: what the card's meters do not already say.
private struct UsageDetailsView: View {
    let usage: JSON?
    let fetched: Date?
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let extra = usage?["extraUsage"], extra["isEnabled"].bool == true {
                if let pct = extra["utilization"].double {
                    ProjMeter(label: "Monthly overage", pct: pct, caption: "Resets at the start of the month")
                } else {
                    Text("Extra usage is on; nothing spent this month.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            UsageHistorySpark()
            HStack {
                if let fetched { Text("Updated \(fetched.relative)") }
                if let source = usage?["source"].string, source != "error" { Text(source == "cached" ? "· cached" : "· live") }
                Spacer()
                Button("Refresh", action: reload).font(.caption)
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Session and weekly usage over time, drawn as two lines.
private struct UsageHistorySpark: View {
    @EnvironmentObject var model: AppModel
    @State private var hours = 24
    @State private var points: [JSON]?
    @State private var error: Error?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Over time").font(.caption.weight(.medium))
                Spacer()
                Picker("Period", selection: $hours) {
                    Text("24h").tag(24)
                    Text("7d").tag(168)
                    Text("30d").tag(720)
                }.pickerStyle(.segmented).frame(maxWidth: 180)
            }
            if let points {
                if points.isEmpty {
                    Text("No usage history yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ZStack {
                        ProjSparkLine(values: points.map { $0["sessionPct"].double }).stroke(Color.accentColor, lineWidth: 1.5)
                        ProjSparkLine(values: points.map { $0["weeklyPct"].double }).stroke(Color.purple, lineWidth: 1.5)
                    }
                    .frame(height: 70)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 12) {
                        Label("Session", systemImage: "circle.fill").foregroundStyle(Color.accentColor)
                        Label("Weekly", systemImage: "circle.fill").foregroundStyle(.purple)
                    }.font(.caption2).labelStyle(.titleAndIcon)
                }
            } else if let error {
                ErrorBanner(error: error) { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .task(id: hours) { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { points = try await api.query("project.usageHistory", .from(["hours": hours])).array; error = nil }
        catch { self.error = error }
    }
}

/// What this project spent, and the account facts nobody reads twice.
private struct ProjectTokenStats: View {
    let info: JSON
    var body: some View {
        let u = info["usage"]
        VStack(spacing: 6) {
            if let email = info["accountEmail"].string { ProjFact(label: "Account", value: email) }
            if let org = info["orgName"].string { ProjFact(label: "Organization", value: org) }
            if let tier = info["rateLimitTier"].string { ProjFact(label: "Rate limit", value: ProjPlanLabel.label(tier)) }
            if let extra = info["extraUsage"].string, !extra.isEmpty, extra != "out_of_credits" {
                ProjFact(label: "Extra usage", value: extra.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            if let plan = info["subscription"].string { ProjFact(label: "Plan", value: ProjPlanLabel.label(plan)) }
            if (u["totalInput"].double ?? 0) + (u["totalOutput"].double ?? 0) > 0 {
                ProjFact(label: "Conversations", value: "\(u["sessionCount"].int ?? 0)", mono: true)
                ProjFact(label: "Input tokens", value: Self.number(u["totalInput"].double), mono: true)
                ProjFact(label: "Output tokens", value: Self.number(u["totalOutput"].double), mono: true)
                if (u["cacheCreation"].double ?? 0) > 0 || (u["cacheRead"].double ?? 0) > 0 {
                    ProjFact(label: "Cache create / read", value: "\(Self.number(u["cacheCreation"].double)) / \(Self.number(u["cacheRead"].double))", mono: true)
                }
                ForEach(u["models"].object.keys.sorted(), id: \.self) { name in
                    ProjFact(label: Self.shortModel(name), value: "\(u["models"][name].int ?? 0)", mono: true)
                }
            } else {
                Text("No tokens spent in this project yet.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    static func number(_ v: Double?) -> String {
        (v ?? 0).formatted(.number.precision(.fractionLength(0)))
    }
    static func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "").split(separator: "-").prefix(2).joined(separator: "-")
    }
}

/// A 0–100 series as a line across its frame; gaps (nil) break the line.
struct ProjSparkLine: Shape {
    let values: [Double?]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let n = max(values.count - 1, 1)
        var started = false
        for (i, v) in values.enumerated() {
            guard let v else { started = false; continue }
            let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(n),
                            y: rect.minY + rect.height * (1 - CGFloat(min(max(v, 0), 100)) / 100))
            if started { path.addLine(to: p) } else { path.move(to: p); started = true }
        }
        return path
    }
}
