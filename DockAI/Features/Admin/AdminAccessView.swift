// tRPC: admin.privileged.list, admin.privileged.setManageProjects, admin.privileged.setManageProjectsExec, admin.privileged.setHostAccess, admin.privileged.setDeployTarget, admin.deployTargets.list, admin.system.getSettings, admin.system.updateSettings, admin.system.githubRefreshToken
import SwiftUI

/// Admin → Access (pages/admin/AccessSection.tsx): the per-project grants an
/// operator gives over DockAI itself, how workers get Docker, and the GitHub
/// App token.
struct AdminAccessView: View {
    @EnvironmentObject var model: AppModel
    @State private var projects: [JSON]?
    @State private var targets: [JSON] = []
    @State private var error: Error?
    @State private var targetsError: Error?

    var body: some View {
        List {
            Section {
                if let error {
                    ErrorBanner(error: error, retry: { Task { await load() } })
                } else if let projects {
                    if projects.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No projects yet")
                            Text("Grants appear here once a project exists.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(projects, id: \.self) { p in
                        NavigationLink {
                            AdminGrantsView(project: p, targets: targets, onChange: { Task { await load() } })
                        } label: { grantRow(p) }
                    }
                } else {
                    ProgressView()
                }
                if let targetsError {
                    ErrorBanner(error: TRPCError(code: "", message: "Could not load the deploy targets: \(targetsError.localizedDescription)"), retry: { Task { await load() } })
                }
            } header: { Text("Project grants") } footer: {
                Text("What an operator grants a project over DockAI itself: managing other projects, running commands in them, its own Docker daemon. Meant for the project where you develop DockAI itself; leave it off everywhere else.")
            }

            AdminWorkerDockerSection()
            AdminGitHubTokenSection()
        }
        .navigationTitle("Access")
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func grantRow(_ p: JSON) -> some View {
        let target = targets.first { $0["id"].string != nil && $0["id"].string == p["deployTargetId"].string }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(p["name"].string ?? "").lineLimit(1)
                Text(p["slug"].string ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                if p["manageProjects"].bool == true { StatePill(text: "Manage", tone: .accent) }
                if p["manageProjectsExec"].bool == true { StatePill(text: "Exec", tone: .warn) }
                if p["hostAccess"].bool == true { StatePill(text: "Own Docker daemon", tone: .warn) }
                if let target { StatePill(text: "Deploys \(target["name"].string ?? "")") }
                if p["manageProjects"].bool != true && p["manageProjectsExec"].bool != true && p["hostAccess"].bool != true && target == nil {
                    Text("No grants").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let email = p["user"]["email"].string { Text(email).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { projects = try await api.query("admin.privileged.list").array; error = nil }
        catch { self.error = error }
        do { targets = try await api.query("admin.deployTargets.list").array; targetsError = nil }
        catch { targetsError = error }
    }
}

/// One project's grants.
private struct AdminGrantsView: View {
    let project: JSON
    let targets: [JSON]
    let onChange: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var manage = false
    @State private var exec = false
    @State private var host = false
    @State private var target = ""

    private var projectId: String { project["id"].string ?? "" }

    var body: some View {
        Form {
            Section {
                Toggle("Manage", isOn: bind($manage) { v in
                    try await set("admin.privileged.setManageProjects", v)
                    // Turning Manage off turns Exec off with it (server-side).
                    if !v { exec = false }
                })
            } footer: { Text("Lets this project's conversations list, start, stop and restart your other projects.") }
            Section {
                Toggle("Exec", isOn: bind($exec) { v in try await set("admin.privileged.setManageProjectsExec", v) })
                    .disabled(!manage)
            } footer: {
                Text(manage ? "Exec also runs commands inside the other workers, reaching their .env and credentials." : "Turn Manage on first — Exec adds to it.")
            }
            Section {
                Toggle("Own Docker daemon", isOn: bind($host) { v in try await set("admin.privileged.setHostAccess", v) })
            } footer: { Text("Gives this project a real Docker daemon that reaches the host — grant it only to a project you wrote.") }
            Section {
                Picker("Deploy target", selection: Binding(get: { target }, set: { v in
                    let old = target
                    target = v
                    action.run {
                        do {
                            guard let api = model.api else { return }
                            _ = try await api.mutate("admin.privileged.setDeployTarget", .from(["projectId": projectId, "targetId": v.isEmpty ? nil : v]))
                            onChange()
                        } catch { target = old; throw error }
                    }
                })) {
                    Text("No deploy").tag("")
                    ForEach(targets, id: \.self) { tg in Text(tg["name"].string ?? "").tag(tg["id"].string ?? "") }
                }
            } footer: { Text("Pick the Compose stack a project may redeploy with dockai-deploy.") }
        }
        .navigationTitle(project["slug"].string ?? "Grants")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert(action)
        .onAppear {
            manage = project["manageProjects"].bool ?? false
            exec = project["manageProjectsExec"].bool ?? false
            host = project["hostAccess"].bool ?? false
            target = project["deployTargetId"].string ?? ""
        }
    }

    /// A toggle that saves on change and reverts if the server refuses.
    private func bind(_ value: Binding<Bool>, save: @escaping (Bool) async throws -> Void) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { v in
            value.wrappedValue = v
            action.run {
                do { try await save(v); onChange() } catch { value.wrappedValue = !v; throw error }
            }
        })
    }

    private func set(_ path: String, _ enabled: Bool) async throws {
        guard let api = model.api else { return }
        _ = try await api.mutate(path, .from(["projectId": projectId, "enabled": enabled]))
    }
}

/// Whether workers try rootless Docker, and what the host said when one did.
private struct AdminWorkerDockerSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var settings: JSON?
    @State private var error: Error?

    var body: some View {
        Section {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } })
            } else if let settings {
                Toggle("Try rootless Docker", isOn: Binding(get: { settings["enableRootlessDind"].bool ?? true }, set: { v in
                    action.run {
                        guard let api = model.api else { return }
                        _ = try await api.mutate("admin.system.updateSettings", .from(["enableRootlessDind": v]))
                        await load()
                    }
                })).disabled(action.busy)
                let r = settings["rootlessDindResult"]
                if !r.isNull {
                    let when = AdminFormat.dateTime(r["at"].date)
                    if r["supported"].bool == true {
                        Text("Working on this host — last checked \(when).").font(.caption).foregroundStyle(.green)
                    } else {
                        Text("Grant Own Docker daemon per project instead: this host’s kernel refused rootless Docker — last checked \(when)").font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                ProgressView()
            }
        } header: { Text("Worker Docker") } footer: {
            Text("Gives a project docker compose without a privileged worker, where the kernel allows it. Where the kernel refuses it, grant Own Docker daemon per project instead.")
        }
        .errorAlert(action)
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { settings = try await api.query("admin.system.getSettings"); error = nil }
        catch { self.error = error }
    }
}

private struct AdminGitHubTokenSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var result: JSON?

    var body: some View {
        Section {
            Button {
                action.run {
                    guard let api = model.api else { return }
                    result = try await api.mutate("admin.system.githubRefreshToken")
                }
            } label: {
                HStack { if action.busy { ProgressView() }; Label("Refresh token", systemImage: "arrow.clockwise") }
            }.disabled(action.busy)
            if let result {
                let refreshed = result["refreshed"].array.compactMap(\.string)
                if refreshed.isEmpty { Text("No GitHub connection has an App installation.").font(.caption).foregroundStyle(.secondary) }
                else { Text("New token for \(refreshed.joined(separator: ", "))").font(.caption).foregroundStyle(.green) }
                ForEach(result["failed"].array.compactMap(\.string), id: \.self) { f in
                    Text(f).font(.caption).foregroundStyle(.red)
                }
            }
        } header: { Text("GitHub App token") } footer: {
            Text("Mint a new installation token after changing the App's permissions on GitHub.")
        }
        .errorAlert(action)
    }
}
