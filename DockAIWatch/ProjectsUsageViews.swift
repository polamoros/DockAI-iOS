// tRPC: project.list, project.start, project.usage, project.claudeSessions
import SwiftUI

/// Each project's status, with Start for a stopped one the person may drive.
struct WatchProjectsView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        NavigationStack {
            List(Array(model.projects.enumerated()), id: \.offset) { _, p in
                NavigationLink { WatchProjectDetail(project: p) } label: { HStack {
                    Circle().fill(color(p["status"].string)).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(p["name"].string ?? "").font(.footnote).lineLimit(1)
                        Text(label(p["status"].string)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // The iPhone's rule (Proj.canDrive / startable): a viewer only watches.
                    if ["STOPPED", "ERROR"].contains(p["status"].string ?? ""), p["role"].string != "VIEWER", let id = p["id"].string {
                        Button { Task { await model.start(projectId: id) } } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Start \(p["name"].string ?? "")")
                    }
                } }
            }
            .navigationTitle("Projects")
            .refreshable { await model.refresh() }
        }
    }

    private func label(_ s: String?) -> String {
        switch s {
        case "RUNNING": "Running"
        case "STARTING", "CREATING": "Starting…"
        case "STOPPING": "Stopping…"
        case "ERROR": "Error"
        default: "Stopped"
        }
    }

    private func color(_ s: String?) -> Color {
        switch s {
        case "RUNNING": .green
        case "STARTING", "CREATING", "STOPPING": .orange
        case "ERROR": .red
        default: .gray
        }
    }
}

/// The account's session-window and weekly meters, with reset times.
struct WatchUsageView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                if model.usage.isEmpty {
                    Text("No running project to read usage through.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.usage) { u in
                    Section(u.name) {
                        Meter(title: "Session", pct: u.sessionPct, resets: u.sessionResetsAt)
                        Meter(title: "Week", pct: u.weeklyPct, resets: u.weeklyResetsAt)
                    }
                }
            }
            .navigationTitle("Usage")
        }
    }
}

private struct Meter: View {
    let title: String
    let pct: Double?
    let resets: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "–").font(.footnote.monospacedDigit())
            }
            ProgressView(value: min(max(pct ?? 0, 0), 100), total: 100).tint((pct ?? 0) >= 90 ? .red : (pct ?? 0) >= 70 ? .orange : .accentColor)
            if let resets { Text("Resets \(resets, style: .relative)").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// One project: its status, Start, a new conversation, and its conversations —
/// tapping one makes it the Ask target and opens Ask.
private struct WatchProjectDetail: View {
    @EnvironmentObject var model: WatchModel
    let project: JSON
    @State private var list: [JSON] = []
    @State private var loading = true
    @State private var creating = false

    private var slug: String { project["slug"].string ?? "" }
    private var name: String { project["name"].string ?? slug }

    var body: some View {
        List {
            if ["STOPPED", "ERROR"].contains(project["status"].string ?? ""), project["role"].string != "VIEWER", let id = project["id"].string {
                Button { Task { await model.start(projectId: id) } } label: { Label("Start", systemImage: "play.fill") }
            }
            Button {
                creating = true
                Task { await model.newConversation(slug: slug, projectName: name); creating = false }
            } label: { Label(creating ? "Starting…" : "New conversation", systemImage: "plus.bubble") }
            .disabled(creating || project["status"].string != "RUNNING")
            Button { model.askIn(slug: slug, projectName: name, sessionId: nil, title: nil) } label: {
                Label("One-off question", systemImage: "bolt")
            }
            Section("Conversations") {
                if loading { ProgressView() }
                if !loading && list.isEmpty { Text("None yet").font(.caption2).foregroundStyle(.secondary) }
                ForEach(Array(list.enumerated()), id: \.offset) { _, s in
                    Button { model.askIn(slug: slug, projectName: name, sessionId: s["id"].string, title: WatchModel.title(s)) } label: {
                        HStack {
                            if !s["remoteState"].isNull { Circle().fill(.green).frame(width: 6, height: 6) }
                            Text(WatchModel.title(s)).lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle(name)
        .task { list = await model.conversations(slug: slug); loading = false }
    }
}

