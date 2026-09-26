// tRPC: project.list, agentRun.listSchedules, agentRun.runScheduleNow, project.start, project.stop
import AppIntents
import Foundation

/// Shortcuts and Siri: run an automation, start or stop a project. They run
/// in the app's process with the paired device token from the Keychain, and
/// the server applies the same rules as for the dashboard (`use` on the
/// project for all three).

enum IntentAPI {
    static func client() throws -> TRPCClient {
        guard let c = Credentials.load() else {
            throw TRPCError(code: "UNAUTHORIZED", message: "Open DockAI and pair this iPhone first.")
        }
        return TRPCClient(credentials: c)
    }
}

// MARK: - Project

struct ProjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static var defaultQuery = ProjectQuery()

    let id: String
    let slug: String
    let name: String
    var status: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(slug)\(status.map { " · \($0.capitalized)" } ?? "")")
    }

    init(id: String, slug: String, name: String, status: String? = nil) {
        self.id = id; self.slug = slug; self.name = name; self.status = status
    }

    init?(_ json: JSON) {
        guard let id = json["id"].string, let slug = json["slug"].string else { return nil }
        self.init(id: id, slug: slug, name: json["name"].string ?? slug, status: json["status"].string)
    }
}

struct ProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        try await all().filter { $0.name.localizedCaseInsensitiveContains(string) || $0.slug.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] { try await all() }

    func all() async throws -> [ProjectEntity] {
        try await IntentAPI.client().query("project.list").array.compactMap(ProjectEntity.init)
    }
}

// MARK: - Automation

struct AutomationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Automation"
    static var defaultQuery = AutomationQuery()

    let id: String
    let name: String
    let projectId: String
    let projectSlug: String
    let projectName: String
    var enabled: Bool = true

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(projectName)\(enabled ? "" : " · Paused")")
    }
}

struct AutomationQuery: EntityQuery {
    /// The project already chosen in Run automation, so its automations are offered first.
    @IntentParameterDependency<RunAutomationIntent>(\.$project) var runIntent

    func entities(for identifiers: [String]) async throws -> [AutomationEntity] {
        try await load(try await ProjectQuery().all()).filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AutomationEntity] {
        if let project = runIntent?.project { return try await load([project]) }
        return try await load(try await ProjectQuery().all())
    }

    private func load(_ projects: [ProjectEntity]) async throws -> [AutomationEntity] {
        let api = try IntentAPI.client()
        var out: [AutomationEntity] = []
        for p in projects {
            // A project this user may not read the automations of is skipped, not fatal.
            guard let rows = try? await api.query("agentRun.listSchedules", .from(["projectId": p.id])).array else { continue }
            for s in rows {
                guard let id = s["id"].string else { continue }
                out.append(AutomationEntity(id: id, name: s["name"].string ?? "Automation", projectId: p.id, projectSlug: p.slug, projectName: p.name, enabled: s["enabled"].bool ?? true))
            }
        }
        return out
    }
}

// MARK: - Intents

/// Run an automation now — `agentRun.runScheduleNow`, the Agent tab's Run now.
struct RunAutomationIntent: AppIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Run automation"
    static var description = IntentDescription("Runs one of a project's automations now.")

    @Parameter(title: "Project") var project: ProjectEntity
    @Parameter(title: "Automation") var automation: AutomationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$automation) in \(\.$project)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard automation.projectId == project.id else {
            throw TRPCError(code: "BAD_REQUEST", message: "“\(automation.name)” belongs to \(automation.projectName), not \(project.name).")
        }
        let firedAt = Date.now
        _ = try await IntentAPI.client().mutate("agentRun.runScheduleNow", .from(["id": automation.id]))
        await RunActivityController.shared.trackAutomation(
            scheduleId: automation.id, projectId: project.id, slug: project.slug, projectName: project.name, name: automation.name, firedAt: firedAt)
        return .result(dialog: "Started “\(automation.name)” in \(project.name).")
    }
}

/// Start a project's worker — `project.start`.
struct StartProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "Start project"
    static var description = IntentDescription("Starts a DockAI project's worker.")

    @Parameter(title: "Project") var project: ProjectEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$project)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await IntentAPI.client().mutate("project.start", .from(["id": project.id]))
        return .result(dialog: "Starting \(project.name).")
    }
}

/// Stop a project's worker — `project.stop`.
struct StopProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop project"
    static var description = IntentDescription("Stops a DockAI project's worker. Its conversations and files are kept.")

    @Parameter(title: "Project") var project: ProjectEntity

    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$project)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await IntentAPI.client().mutate("project.stop", .from(["id": project.id]))
        return .result(dialog: "Stopping \(project.name).")
    }
}

struct DockAIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAutomationIntent(),
            phrases: ["Run an automation in \(.applicationName)", "Run a \(.applicationName) automation"],
            shortTitle: "Run automation",
            systemImageName: "bolt.fill")
        AppShortcut(
            intent: StartProjectIntent(),
            phrases: ["Start \(\.$project) in \(.applicationName)", "Start a \(.applicationName) project"],
            shortTitle: "Start project",
            systemImageName: "play.fill")
        AppShortcut(
            intent: StopProjectIntent(),
            phrases: ["Stop \(\.$project) in \(.applicationName)", "Stop a \(.applicationName) project"],
            shortTitle: "Stop project",
            systemImageName: "stop.fill")
    }
}
