// tRPC: admin.system.deployStatus, admin.system.deploy, admin.deployTargets.list, admin.deployTargets.create, admin.deployTargets.rotateToken, admin.deployTargets.delete, admin.deployTargets.run, admin.system.claudeCode, admin.system.claudeCodeCheck, admin.system.claudeCodeUpdate
import SwiftUI

/// Admin → Deploy (pages/admin/DeploySection.tsx): DockAI itself, the other
/// Compose stacks on this host, and the Claude CLI inside the workers.
struct AdminDeployView: View {
    var body: some View {
        List {
            AdminDeploySection()
            AdminDeployTargetsSection()
            AdminClaudeCodeSection()
        }
        .navigationTitle("Deploy")
    }
}

// MARK: - DockAI itself

private struct AdminDeploySection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var status: JSON?
    @State private var statusError: Error?
    @State private var deployed = false

    private var running: Bool { status?["state"].string == "running" }
    /// The orchestrator is being replaced: its status call fails once a deploy started.
    private var restarting: Bool { statusError != nil && deployed }

    var body: some View {
        Section {
            if status == nil && statusError == nil {
                ProgressView()
            } else {
                if restarting || (status?["state"].string.map { $0 != "idle" } ?? false) {
                    AdminDeployStatePill(state: status?["state"].string, exitCode: status?["exitCode"].int, restarting: restarting)
                }
                if let s = status, s["configured"].bool == false {
                    Label("Set DOCKAI_COMPOSE_DIR on the orchestrator (the host path of the compose directory) to enable this.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let statusError, !deployed { ErrorBanner(error: statusError, retry: { Task { await load() } }) }
                if running {
                    HStack { ProgressView(); Text("Deploying…") }
                } else {
                    ConfirmButton(title: "Deploy latest", confirmTitle: "Yes, deploy now", role: nil) {
                        action.run {
                            guard let api = model.api else { return }
                            _ = try await api.mutate("admin.system.deploy")
                            deployed = true
                            await load()
                        }
                    }
                    .disabled(status?["configured"].bool != true || action.busy)
                }
                if let log = status?["log"].string, !log.isEmpty {
                    AdminLogDisclosure(title: "Deploy log", log: log, running: running)
                }
            }
        } header: { Text("Deploy DockAI") } footer: {
            Text("Pull the latest images and recreate the stack; the dashboard drops for about a minute.")
        }
        .errorAlert(action)
        .task {
            // Poll: every 3s while running or while the orchestrator is restarting, else every minute.
            while !Task.isCancelled {
                await load()
                let fast = running || statusError != nil
                try? await Task.sleep(nanoseconds: (fast ? 3 : 60) * 1_000_000_000)
            }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { status = try await api.query("admin.system.deployStatus"); statusError = nil }
        catch { statusError = error }
    }
}

// MARK: - Deploy targets

private struct AdminDeployTargetsSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var targets: [JSON]?
    @State private var error: Error?
    @State private var name = ""
    @State private var dir = ""
    @State private var token: (name: String, token: String)?
    @State private var snippetFor: String?
    @State private var confirmRotate: JSON?
    @State private var confirmDelete: JSON?

    var body: some View {
        Section {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } })
            } else if let targets {
                if targets.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No deploy targets")
                        Text("Add a Compose stack on this host and DockAI can redeploy it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(targets, id: \.self) { tg in targetRow(tg) }
            } else {
                ProgressView()
            }

            if let token {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Token for \(token.name) — shown once. Put it in the repo as the DOCKAI_DEPLOY_TOKEN secret.").font(.callout)
                    Text(token.token).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        AdminCopyButton(text: token.token)
                        Spacer()
                        Button("Done") { self.token = nil }
                    }.buttonStyle(.borderless)
                }
            }
        } header: { Text("Deploy targets") } footer: {
            Text("Compose stacks on this host that DockAI redeploys on request, or from a repo's CI.")
        }

        Section {
            TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
            TextField("Compose directory", text: $dir).textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
            Button("Add") {
                action.run {
                    guard let api = model.api else { return }
                    let r = try await api.mutate("admin.deployTargets.create", .from(["name": name, "composeDir": dir]))
                    token = (r["name"].string ?? name, r["token"].string ?? "")
                    name = ""; dir = ""
                    await load()
                }
            }.disabled(name.isEmpty || !dir.hasPrefix("/") || action.busy)
        } header: { Text("Add a deploy target") } footer: { Text("The host path of the stack's docker-compose.yml.") }
        .errorAlert(action)
        .confirmationDialog("Rotate? CI breaks until updated", isPresented: Binding(get: { confirmRotate != nil }, set: { if !$0 { confirmRotate = nil } }), titleVisibility: .visible) {
            Button("New token") {
                guard let tg = confirmRotate else { return }
                action.run {
                    guard let api = model.api else { return }
                    let r = try await api.mutate("admin.deployTargets.rotateToken", .from(["id": tg["id"].string]))
                    token = (r["name"].string ?? tg["name"].string ?? "", r["token"].string ?? "")
                }
            }
        }
        .confirmationDialog("Delete \(confirmDelete?["name"].string ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let tg = confirmDelete else { return }
                action.run {
                    guard let api = model.api else { return }
                    _ = try await api.mutate("admin.deployTargets.delete", .from(["id": tg["id"].string]))
                    await load()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                let busy = targets?.contains { $0["status"]["state"].string == "running" } ?? false
                try? await Task.sleep(nanoseconds: (busy ? 3 : 60) * 1_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func targetRow(_ tg: JSON) -> some View {
        let tgName = tg["name"].string ?? ""
        let state = tg["status"]["state"].string ?? "idle"
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tgName).font(.body.monospaced())
                Spacer()
                if state != "idle" { AdminDeployStatePill(state: state, exitCode: tg["status"]["exitCode"].int) }
            }
            Text(tg["composeDir"].string ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
            Group {
                if let at = tg["lastRunAt"].date {
                    Text("last run \(AdminFormat.dateTime(at))" + (tg["lastRunBy"].string.map { " by \($0)" } ?? ""))
                } else {
                    Text("never run")
                }
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button {
                    action.run {
                        guard let api = model.api else { return }
                        _ = try await api.mutate("admin.deployTargets.run", .from(["name": tgName]))
                        await load()
                    }
                } label: { Label("Run", systemImage: "play") }.disabled(state == "running")
                Button { snippetFor = snippetFor == tgName ? nil : tgName } label: { Label("CI snippet", systemImage: "chevron.left.forwardslash.chevron.right") }
                Menu {
                    Button { confirmRotate = tg } label: { Label("New token", systemImage: "arrow.triangle.2.circlepath") }
                    Button(role: .destructive) { confirmDelete = tg } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }.buttonStyle(.borderless).font(.callout)
            if snippetFor == tgName {
                let snippet = ciSnippet(tgName)
                Text(snippet).font(.caption2.monospaced()).textSelection(.enabled)
                AdminCopyButton(text: snippet).buttonStyle(.borderless)
            }
            if let log = tg["status"]["log"].string, !log.isEmpty, state != "idle" {
                AdminLogDisclosure(title: "Deploy log", log: log, running: state == "running")
            }
        }
    }

    private func ciSnippet(_ target: String) -> String {
        let base = model.credentials?.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return """
        # GitHub Actions — after the job that publishes the images:
          deploy:
            needs: build
            runs-on: ubuntu-latest
            steps:
              - run: >-
                  curl -fsS -X POST "\(base)/api/deploy/\(target)?wait=1"
                  -H "Authorization: Bearer $DOCKAI_DEPLOY_TOKEN"
                env:
                  DOCKAI_DEPLOY_TOKEN: ${{ secrets.DOCKAI_DEPLOY_TOKEN }}

        # By hand:  dockai deploy \(target)
        """
    }

    private func load() async {
        guard let api = model.api else { return }
        do { targets = try await api.query("admin.deployTargets.list").array; error = nil }
        catch { self.error = error }
    }
}

// MARK: - Claude Code in the workers

private struct AdminClaudeCodeSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var status: JSON?
    @State private var error: Error?
    @State private var done: (ok: Int, total: Int)?
    @State private var updating = false

    var body: some View {
        let latest = status?["latest"].string
        let workers = status?["workers"].array ?? []
        let behind = workers.filter { $0["version"].string != nil && latest != nil && $0["current"].bool != true }
        Section {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } })
            } else if status == nil {
                ProgressView()
            } else {
                HStack {
                    if let latest {
                        Text(latest).font(.callout.monospaced())
                        Spacer()
                        if workers.isEmpty { Text("No project is running.").font(.caption).foregroundStyle(.secondary) }
                        else if behind.isEmpty { StatePill(text: "All workers current", tone: .ok) }
                        else { StatePill(text: "\(behind.count) worker\(behind.count == 1 ? "" : "s") behind", tone: .warn) }
                    } else {
                        Text("No version known yet.").foregroundStyle(.secondary)
                    }
                }
                Button {
                    action.run {
                        guard let api = model.api else { return }
                        _ = try await api.mutate("admin.system.claudeCodeCheck")
                        await load()
                    }
                } label: { Label("Check now", systemImage: "arrow.clockwise") }
                Button {
                    done = nil
                    updating = true
                    action.run {
                        defer { updating = false }
                        guard let api = model.api else { return }
                        let r = try await api.mutate("admin.system.claudeCodeUpdate")
                        let results = r["results"].array
                        done = (results.filter { $0["ok"].bool == true }.count, results.count)
                        await load()
                    }
                } label: {
                    HStack { if updating { ProgressView() }; Label("Update workers", systemImage: "arrow.down.circle") }
                }.disabled(updating || workers.isEmpty)
                if let done {
                    Text("Updated \(done.ok) of \(done.total).").foregroundStyle(done.ok == done.total ? .green : .orange)
                }
                // The per-worker list only once there is something to disagree about.
                if !behind.isEmpty {
                    ForEach(workers, id: \.self) { w in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(w["name"].string ?? "")
                                Text(w["version"].string ?? "No answer").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if w["current"].bool == true { StatePill(text: "Current", tone: .ok) }
                        }
                    }
                }
            }
        } header: { Text("Claude Code") } footer: {
            Text("The CLI updates itself when it starts; updating here only removes the wait.")
        }
        .errorAlert(action)
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { status = try await api.query("admin.system.claudeCode"); error = nil }
        catch { self.error = error }
    }
}
