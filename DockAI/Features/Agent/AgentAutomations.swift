// tRPC: agentRun.listSchedules, agentRun.updateSchedule, agentRun.deleteSchedule, agentRun.runScheduleNow
import SwiftUI

/// What the create/edit page is opened for.
enum AgentAutomationTarget: Hashable {
    case new
    case edit(JSON)
}

/// The project's automations (`AgentSchedules.tsx`): one row per automation,
/// with its timing, what it runs, its last exit and error, and its controls —
/// the enable switch, Run now, Edit and a two-tap Delete. Creating or editing
/// is a page of its own, as on the web.
struct AgentAutomationsList: View {
    let projectId: String
    let slug: String
    var onCount: (Int) -> Void = { _ in }

    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var rows: [JSON]?
    @State private var loadError: Error?
    @State private var target: AgentAutomationTarget?

    var body: some View {
        Group {
            if let rows {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label("No automations", systemImage: "clock")
                    } description: {
                        Text("Run the agent or a command once, on a timetable, or when a check sees a change.")
                    } actions: {
                        Button { target = .new } label: { Label("New automation", systemImage: "plus") }
                            .buttonStyle(.bordered)
                    }
                } else {
                    List {
                        Section {
                            ForEach(rows, id: \.self) { row in
                                AgentAutomationRow(
                                    row: row,
                                    onToggle: { setEnabled(row, $0) },
                                    onRunNow: { runNow(row) },
                                    onEdit: { target = .edit(row) },
                                    onDelete: { delete(row) }
                                )
                            }
                        } footer: {
                            Text("An automation runs the agent or a command once, on a timetable, or when something changes.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            } else if let loadError {
                ErrorBanner(error: loadError, retry: { Task { await load() } }).padding()
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { target = .new } label: { Label("New automation", systemImage: "plus") }
            }
        }
        .navigationDestination(item: $target) { t in
            AgentAutomationForm(projectId: projectId, slug: slug, target: t) {
                target = nil
                Task { await load() }
            }
        }
        .task { await load() }
        .errorAlert(action)
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list = try await api.query("agentRun.listSchedules", .from(["projectId": projectId])).array
            rows = list
            loadError = nil
            onCount(list.count)
        } catch {
            loadError = error
        }
    }

    private func setEnabled(_ row: JSON, _ enabled: Bool) {
        guard let api = model.api, let id = row["id"].string else { return }
        // Shown at once; a refusal springs back on the reload.
        if let i = rows?.firstIndex(of: row), case .object(var o) = row {
            o["enabled"] = .bool(enabled)
            rows?[i] = .object(o)
        }
        action.run {
            defer { Task { await load() } }
            _ = try await api.mutate("agentRun.updateSchedule", .from(["id": id, "enabled": enabled]))
        }
    }

    private func runNow(_ row: JSON) {
        guard let api = model.api, let id = row["id"].string else { return }
        action.run {
            _ = try await api.mutate("agentRun.runScheduleNow", .from(["id": id]))
            RunActivityController.shared.trackAutomation(scheduleId: id, projectId: projectId, slug: slug, projectName: slug, name: row["name"].string ?? "Automation")
            await load()
        }
    }

    private func delete(_ row: JSON) {
        guard let api = model.api, let id = row["id"].string else { return }
        action.run {
            _ = try await api.mutate("agentRun.deleteSchedule", .from(["id": id]))
            await load()
        }
    }
}

/// One automation. The prompt (or command) wraps on its own lines, since it
/// is what tells two automations apart; the error is shown in full under the
/// row, not truncated into the meta line.
struct AgentAutomationRow: View {
    let row: JSON
    let onToggle: (Bool) -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var enabled: Bool { row["enabled"].bool ?? false }
    private var running: Bool { row["runningRunId"].string != nil }
    private var isCommand: Bool { row["action"].string == "command" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row["name"].string ?? "—").font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Toggle(enabled ? "Pause automation" : "Resume automation", isOn: Binding(get: { enabled }, set: onToggle))
                    .labelsHidden()
            }

            Text(Self.timing(row)).font(.caption.monospaced()).foregroundStyle(.secondary)

            if isCommand {
                Text("$ \(row["command"].string ?? "")").font(.callout.monospaced()).lineLimit(3)
            } else {
                Text(row["prompt"].string ?? "").font(.callout).lineLimit(3)
            }

            // Meta line: next and last, on change, running, last exit, failed.
            HStack(spacing: 6) {
                Text("Next \(enabled ? AgentFormat.dateTime(row["nextRunAt"].date) : "paused") · last \(AgentFormat.dateTime(row["lastRunAt"].date))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                if !(row["trigger"].string ?? "").isEmpty { StatePill(text: "On change") }
                if running { StatePill(text: "Running", tone: .accent) }
                if isCommand, let code = row["lastExitCode"].int, code != -1 {
                    StatePill(text: "Last exit \(code)", tone: code == 0 ? .ok : .warn)
                }
                if row["lastError"].string != nil {
                    Label("Failed", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }

            if let err = row["lastError"].string, !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            // What the command printed last, behind a disclosure: the exit
            // pill answers "did it work"; the output is for when it did not.
            if isCommand, let out = row["lastOutput"].string, !out.isEmpty {
                DisclosureGroup("Last output") {
                    ScrollView {
                        Text(out).font(.caption2.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                .font(.caption)
            }

            HStack(spacing: 16) {
                Button(action: onRunNow) { Label("Run now", systemImage: "play.fill") }
                    .disabled(running)
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                Spacer()
                ConfirmButton(title: "Delete", confirmTitle: "Confirm delete", action: onDelete)
            }
            .font(.callout)
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    /// What a row says about when: a date for a one-time automation, the cron
    /// otherwise, with its zone when it is not UTC.
    static func timing(_ row: JSON) -> String {
        if row["kind"].string == "once" {
            return "Once · \(AgentFormat.dateTime(row["runAt"].date))"
        }
        let cron = row["cron"].string ?? ""
        let tz = row["timezone"].string ?? "UTC"
        return tz != "UTC" && !tz.isEmpty ? "\(cron) · \(tz)" : cron
    }
}
