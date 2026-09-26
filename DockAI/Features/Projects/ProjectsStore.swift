// tRPC: project.list, project.start, project.stop, project.restart
import SwiftUI

/// The project list and what acts on it: the web's `useProjects`,
/// `useProjectListMutations` and `useProjectBulkActions`.
@MainActor
final class ProjectsStore: ObservableObject {
    @Published private(set) var projects: [JSON]?
    @Published var error: Error?
    @Published private(set) var busyIds: Set<String> = []
    @Published private(set) var bulkRunning = false
    /// Live status from `container:status` events, until the next load.
    @Published private(set) var liveStatus: [String: String] = [:]

    func load(_ api: TRPCClient?) async {
        guard let api else { return }
        do {
            let list = try await api.query("project.list")
            projects = list.array
            liveStatus = [:]
            error = nil
        } catch { self.error = error }
    }

    func status(_ p: JSON) -> String? {
        if let id = p["id"].string, let s = liveStatus[id] { return s }
        return p["status"].string
    }

    /// Running first, then most recently updated — `byProjectOrder`, so this
    /// agrees with the web's sidebar and dashboard.
    func sorted(matching search: String) -> [JSON] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = (projects ?? []).filter { p in
            q.isEmpty
                || (p["name"].string ?? "").lowercased().contains(q)
                || (p["slug"].string ?? "").lowercased().contains(q)
                || (Proj.repoName(p["githubRepoUrl"].string) ?? "").lowercased().contains(q)
        }
        return rows.sorted { a, b in
            let ra = status(a) == "RUNNING" ? 0 : 1, rb = status(b) == "RUNNING" ? 0 : 1
            if ra != rb { return ra < rb }
            return (a["updatedAt"].date ?? .distantPast) > (b["updatedAt"].date ?? .distantPast)
        }
    }

    /// An SSE event: a status change moves the row at once, anything else
    /// about a project reloads the list (as the web invalidates it).
    func handle(_ event: JSON, api: TRPCClient?) {
        let type = event["type"].string
        if type == "container:status", let id = event["projectId"].string, let s = event["data"]["status"].string {
            liveStatus[id] = s
            if s == "RUNNING" || s == "STOPPED" || s == "ERROR" { Task { await load(api) } }
        } else if type == "project:updated" {
            Task { await load(api) }
        }
    }

    func act(_ action: String, id: String, api: TRPCClient?) async {
        guard let api else { return }
        busyIds.insert(id)
        defer { busyIds.remove(id) }
        do { _ = try await api.mutate("project.\(action)", .from(["id": id])) } catch { self.error = error }
        await load(api)
    }

    /// Start, stop or restart several, one after another — each start pulls an
    /// image and each restart recreates a worker, and firing them all at once
    /// is how a home server falls over. Returns "name: reason" per failure.
    func bulk(_ action: String, projects targets: [JSON], api: TRPCClient?) async -> [String] {
        guard let api else { return [] }
        bulkRunning = true
        var failures: [String] = []
        for p in targets {
            guard let id = p["id"].string else { continue }
            do { _ = try await api.mutate("project.\(action)", .from(["id": id])) }
            catch { failures.append("\(p["name"].string ?? id): \(error.localizedDescription)") }
        }
        bulkRunning = false
        await load(api)
        return failures
    }
}
