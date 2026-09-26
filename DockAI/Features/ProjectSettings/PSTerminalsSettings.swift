// tRPC: project.tmuxSessions, project.killTmuxSession, project.sshSessions, project.killSshSession, project.sshConnectionHistory, project.generateSshAccess
import SwiftUI

/// Settings → Terminals & SSH (TerminalsSettings.tsx): the worker's tmux
/// terminals, its SSH connections and their history, and how to connect.
struct PSTerminalsSettings: View {
    let slug: String
    let project: JSON
    @State private var tab = "terminals"

    var body: some View {
        if !project.psRunning {
            ContentUnavailableView("Terminals & SSH", systemImage: "terminal", description: Text("Start the project to manage its terminals."))
        } else {
            List {
                Section {
                    Picker("View", selection: $tab) {
                        Label("Terminals", systemImage: "terminal").tag("terminals")
                        Label("SSH", systemImage: "wifi").tag("ssh")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                if tab == "terminals" { PSTmuxList(slug: slug) } else { PSSshPanel(slug: slug) }
            }
        }
    }
}

private struct PSTmuxList: View {
    let slug: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var sessions: [JSON]?
    @State private var error: Error?

    var body: some View {
        Section {
            if let error { ErrorBanner(error: error) { Task { await load() } } }
            else if let sessions {
                if sessions.isEmpty { Text("No terminals running.").foregroundStyle(.secondary) }
                ForEach(sorted(sessions), id: \.self) { s in row(s) }
            } else { ProgressView() }
        } header: {
            Text("Terminals")
        } footer: {
            Text("Swipe a row to end it. Ending a shell kills its tmux session.")
        }
        .errorAlert(action)
        .task { await load() }
        .refreshable { await load() }
    }

    private func sorted(_ s: [JSON]) -> [JSON] {
        s.sorted {
            let a = $0["attached"].bool == true, b = $1["attached"].bool == true
            if a != b { return a }
            return ($0["name"].string ?? "") < ($1["name"].string ?? "")
        }
    }

    /// `dockai-rc` is the Remote Control supervisor; ending it takes the project off the Claude app.
    private func kind(_ name: String) -> (label: String, claude: Bool, rc: Bool) {
        if name == "dockai-rc" { return ("Remote Control server", true, true) }
        if name.hasPrefix("claude-") { return ("Claude", true, false) }
        if name.hasPrefix("resume-") { return ("Claude (resumed)", true, false) }
        if name.hasPrefix("shell-") { return ("Shell", false, false) }
        return (name, false, false)
    }

    private func row(_ s: JSON) -> some View {
        let name = s["name"].string ?? ""
        let k = kind(name)
        let attached = s["attached"].bool == true
        let created = s["createdAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
        return HStack(alignment: .top) {
            Image(systemName: k.claude ? "sparkles" : "terminal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(k.label)
                if k.rc {
                    Text("Serves this project to the Claude app, which loses it until you start it again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    StatePill(text: attached ? "Connected" : "Background", tone: attached ? .ok : .neutral)
                    if !k.rc {
                        Text("\(name)\(created.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? "")")
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .swipeActions {
            Button(k.rc ? "Stop server" : "Kill", role: .destructive) {
                action.run {
                    _ = try await model.api?.mutate("project.killTmuxSession", .from(["slug": slug, "sessionName": name]))
                    await load()
                }
            }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { sessions = try await api.query("project.tmuxSessions", .from(["slug": slug])).array; error = nil } catch { self.error = error }
    }
}

private struct PSSshPanel: View {
    let slug: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var active: [JSON]?
    @State private var history: [JSON]?
    @State private var activeError: Error?
    @State private var historyError: Error?
    @State private var access: JSON = .null
    @State private var showAll = false

    var body: some View {
        Group {
            Section {
                if let activeError { ErrorBanner(error: activeError) { Task { await load() } } }
                else if let active {
                    if active.isEmpty { Text("No active SSH connections.").foregroundStyle(.secondary) }
                    ForEach(Array(active.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("SSH")
                            HStack(spacing: 6) {
                                StatePill(text: "Connected", tone: .accent)
                                Text("\(s["user"].string ?? "")@\(s["tty"].string ?? "") · \(s["date"].string ?? "")")
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button("Disconnect", role: .destructive) {
                                let tty = s["tty"].string ?? ""
                                action.run {
                                    _ = try await model.api?.mutate("project.killSshSession", .from(["slug": slug, "tty": tty]))
                                    await load()
                                }
                            }
                        }
                    }
                } else { ProgressView() }
            } header: {
                Text("Active connections")
            }

            Section {
                if access.isNull {
                    Button {
                        action.run {
                            access = try await model.api?.mutate("project.generateSshAccess", .from(["slug": slug])) ?? .null
                        }
                    } label: { Label("How to connect", systemImage: "key") }
                } else {
                    if let setup = access["setupCommand"].string {
                        PSCommandRow(label: "Once per computer", command: setup, hint: "Teaches ssh and VS Code about DockAI hosts.")
                    }
                    if let cmd = access["command"].string { PSCommandRow(label: "Connect", command: cmd) }
                    if let editor = access["editorCommand"].string { PSCommandRow(label: "Open in your editor", command: editor) }
                }
            } header: {
                Text("SSH access")
            } footer: {
                Text("Your registered SSH key is the only credential; the connection goes through DockAI's authenticated tunnel.")
            }

            Section {
                if let historyError { ErrorBanner(error: historyError) { Task { await load() } } }
                else if let history {
                    if history.isEmpty {
                        VStack(alignment: .leading) {
                            Text("No connection history.")
                            Text("Register a key, then connect with dockai claude or ssh.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(showAll ? history : Array(history.prefix(5)), id: \.self) { e in historyRow(e) }
                    if history.count > 5 {
                        Button(showAll ? "Show less" : "Show all \(history.count) connections") { showAll.toggle() }
                    }
                } else { ProgressView() }
            } header: {
                Text("Connection history")
            }
        }
        .errorAlert(action)
        .task { await load() }
    }

    private func historyRow(_ e: JSON) -> some View {
        let isActive = e["disconnectedAt"].isNull
        var duration = ""
        if let a = e["connectedAt"].date, let b = e["disconnectedAt"].date {
            let secs = Int(b.timeIntervalSince(a))
            let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
            duration = h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m" : "\(s)s"
        }
        return HStack {
            Circle().fill(isActive ? Color.accentColor : .secondary).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(e["targetLabel"].string ?? "Shell")
                Text(e["connectedAt"].date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(isActive ? "active" : duration).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { active = try await api.query("project.sshSessions", .from(["slug": slug])).array; activeError = nil } catch { activeError = error }
        do { history = try await api.query("project.sshConnectionHistory", .from(["slug": slug])).array; historyError = nil } catch { historyError = error }
    }
}
