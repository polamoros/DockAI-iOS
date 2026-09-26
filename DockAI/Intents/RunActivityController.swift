// tRPC: agentRun.get, agentRun.listSchedules, project.list
import ActivityKit
import Foundation

/// Starts and feeds the run Live Activity (`RunActivityAttributes`, drawn by
/// the widget extension) for an agent run or an automation started from the
/// app — the Agent tab, or the Run automation shortcut.
///
/// Updates come from polling the server while the app is alive. The server
/// does not send `liveactivity` pushes yet (by design: "Live
/// Activity updates use apns-push-type: liveactivity"), so once iOS suspends
/// the app the activity keeps its last state until the app next runs; it is
/// marked stale after ten minutes without news so the lock screen says so.
@MainActor
final class RunActivityController {
    static let shared = RunActivityController()
    private var tasks: [String: Task<Void, Never>] = [:]
    /// The app's live events: a run's lines as they are written
    /// (`agentRun:chunk`) — its saved output exists only once it ends.
    weak var events: EventStream?
    private var subscriptions: [String: UUID] = [:]

    /// A run started in the app's Agent tab: its project's name and slug
    /// looked up here, since the composer knows only the id.
    func trackRun(runId: String, projectId: String, title: String = "Run") {
        guard enabled else { return }
        Task {
            let projects = (try? await api()?.query("project.list"))?.array ?? []
            let p = projects.first { $0["id"].string == projectId }
            track(runId: runId, slug: p?["slug"].string ?? "", projectName: p?["name"].string ?? "DockAI", title: title)
        }
    }

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Follow an agent run by its id (`agentRun.start` returns it).
    func track(runId: String, slug: String, projectName: String, title: String = "Run") {
        guard enabled, tasks[runId] == nil, let activity = start(slug: slug, projectName: projectName, title: title) else { return }
        listen(runId, activity: activity)
        tasks[runId] = Task { [weak self] in
            await self?.followRun(runId, activity: activity)
            self?.tasks[runId] = nil
            if let id = self?.subscriptions.removeValue(forKey: runId) { self?.events?.off(id) }
        }
    }

    /// Follow an automation fired with `agentRun.runScheduleNow`, which answers
    /// only `{started: true}`. An agent automation's run is found through the
    /// schedule's `runningRunId` once the server claims it (starting a stopped
    /// project first can take a while); a command automation has no run, so
    /// its result is read off the schedule's `lastRunAt`/`lastExitCode`/`lastOutput`.
    func trackAutomation(scheduleId: String, projectId: String, slug: String, projectName: String, name: String, firedAt: Date = .now) {
        let key = "schedule:\(scheduleId)"
        guard enabled, tasks[key] == nil, let activity = start(slug: slug, projectName: projectName, title: name) else { return }
        tasks[key] = Task { [weak self] in
            await self?.followAutomation(scheduleId, projectId: projectId, firedAt: firedAt, activity: activity)
            self?.tasks[key] = nil
        }
    }

    // MARK: -

    private func start(slug: String, projectName: String, title: String) -> Activity<RunActivityAttributes>? {
        let attributes = RunActivityAttributes(slug: slug, projectName: projectName, title: title)
        let state = RunActivityAttributes.ContentState(status: "pending", lastLine: "", startedAt: .now, finishedAt: nil)
        return try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(600)), pushType: nil)
    }

    private func api() -> TRPCClient? { Credentials.load().map(TRPCClient.init(credentials:)) }

    private func followRun(_ runId: String, activity: Activity<RunActivityAttributes>) async {
        guard let api = api() else { return }
        var state = activity.content.state
        let deadline = Date.now.addingTimeInterval(3 * 3600)
        while !Task.isCancelled && Date.now < deadline {
            if let run = try? await api.query("agentRun.get", .from(["runId": runId])) {
                state.status = run["status"].string ?? state.status
                if let d = run["startedAt"].date { state.startedAt = d }
                state.finishedAt = run["finishedAt"].date
                let line = Self.lastLine(ndjson: run["output"].string ?? "")
                state.lastLine = line ?? run["error"].string ?? state.lastLine
                if state.finished { await end(activity, state); return }
                await activity.update(ActivityContent(state: state, staleDate: .now.addingTimeInterval(600)))
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        await end(activity, state)
    }

    private func followAutomation(_ scheduleId: String, projectId: String, firedAt: Date, activity: Activity<RunActivityAttributes>) async {
        guard let api = api() else { return }
        var state = activity.content.state
        let deadline = Date.now.addingTimeInterval(20 * 60)
        while !Task.isCancelled && Date.now < deadline {
            let list = (try? await api.query("agentRun.listSchedules", .from(["projectId": projectId])))?.array ?? []
            if let s = list.first(where: { $0["id"].string == scheduleId }) {
                if let runId = s["runningRunId"].string {
                    await followRun(runId, activity: activity)
                    return
                }
                // A command automation (or an agent run that finished between polls):
                // the schedule's own record of its last run, once it is newer than the tap.
                if let last = s["lastRunAt"].date, last >= firedAt.addingTimeInterval(-5) {
                    if s["action"].string == "command" {
                        let code = s["lastExitCode"].int
                        state.status = code == 0 ? "completed" : "failed"
                        let out = (s["lastOutput"].string ?? "").split(whereSeparator: \.isNewline).last.map(String.init)
                        state.lastLine = out ?? (code.map { "Exited \($0)" } ?? "")
                    } else {
                        state.status = s["lastError"].string == nil ? "completed" : "failed"
                        state.lastLine = s["lastError"].string ?? ""
                    }
                    state.finishedAt = .now
                    await end(activity, state)
                    return
                }
                state.status = s["action"].string == "command" ? "running" : "pending"
                await activity.update(ActivityContent(state: state, staleDate: .now.addingTimeInterval(600)))
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        await end(activity, state)
    }

    /// Each line the run writes, while the app is alive: the lock screen
    /// shows what it is doing now, not only whether it is running.
    private func listen(_ runId: String, activity: Activity<RunActivityAttributes>) {
        guard let events, subscriptions[runId] == nil else { return }
        subscriptions[runId] = events.on { event in
            guard event["type"].string == "agentRun:chunk", event["data"]["runId"].string == runId,
                  let line = event["data"]["line"].string, let said = Self.lastLine(ndjson: line) else { return }
            Task { @MainActor in
                var state = activity.content.state
                guard !state.finished else { return }
                state.lastLine = said
                if state.status == "pending" { state.status = "running" }
                await activity.update(ActivityContent(state: state, staleDate: .now.addingTimeInterval(600)))
            }
        }
    }

    private func end(_ activity: Activity<RunActivityAttributes>, _ state: RunActivityAttributes.ContentState) async {
        var s = state
        if !s.finished { s.lastLine = s.lastLine.isEmpty ? "Open DockAI for the result." : s.lastLine }
        if s.finished && s.finishedAt == nil { s.finishedAt = .now }
        await activity.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(15 * 60)))
    }

    /// The last thing a run said, from its NDJSON output: the result, an
    /// error, the last line of assistant text, or the tool it is using.
    nonisolated static func lastLine(ndjson: String) -> String? {
        for raw in ndjson.split(whereSeparator: \.isNewline).reversed() {
            guard let data = raw.data(using: .utf8), var ev = try? JSONDecoder().decode(JSON.self, from: data) else { continue }
            // The runner wraps each SDK message: {"type":"message","message":{…}}.
            if ev["type"].string == "message" { ev = ev["message"] }
            switch ev["type"].string {
            case "result":
                if let r = ev["result"].string, let l = lastNonEmptyLine(r) { return l }
            case "error":
                if let e = ev["error"].string { return e }
            case "assistant":
                for block in ev["message"]["content"].array.reversed() {
                    if block["type"].string == "text", let t = block["text"].string, let l = lastNonEmptyLine(t) { return l }
                    if block["type"].string == "tool_use", let n = block["name"].string { return "Using \(n)…" }
                }
            default: continue
            }
        }
        return nil
    }

    nonisolated private static func lastNonEmptyLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}
