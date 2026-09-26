// tRPC: project.update, project.delete, project.getBySlug, member.list, member.add, member.setRole, member.remove
import SwiftUI

/// Settings → General (GeneralSettings.tsx): the name, the repository and its
/// per-project GitHub token, the operator grants shown (never set) here, who
/// else can reach the project, and deleting it.
struct PSGeneralSettings: View {
    let slug: String
    let onChange: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var box: PSProjectBox
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var repoUrl = ""
    @State private var branch = ""
    @State private var extraRepos = ""
    @State private var githubAccess = "repo"
    @State private var pat = ""
    @State private var clearPat = false
    @State private var saved = false
    @State private var loaded = false

    init(slug: String, project: JSON, onChange: @escaping () -> Void) {
        self.slug = slug
        self.onChange = onChange
        _box = StateObject(wrappedValue: PSProjectBox(project))
    }

    private var p: JSON { box.project }

    private var values: [String: JSON] {
        let url = repoUrl.trimmingCharacters(in: .whitespaces)
        return [
            "name": .string(name),
            "githubRepoUrl": url.isEmpty ? .null : .string(url),
            "githubBranch": .string(branch),
            "githubAccess": .string(githubAccess),
            "githubExtraRepos": .array(extraRepos
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map { .string(String($0)) }),
        ]
    }

    private var patch: [String: JSON] {
        var c = PSPatch.changed(values, project: p, defaults: ["githubBranch": .string("main"), "githubAccess": .string("repo"), "githubExtraRepos": .array([])])
        // Write-only: an empty field leaves the stored token alone; the switch removes it.
        if clearPat { c["githubPat"] = .string("") }
        else if !pat.trimmingCharacters(in: .whitespaces).isEmpty { c["githubPat"] = .string(pat.trimmingCharacters(in: .whitespaces)) }
        return c
    }

    var body: some View {
        Form {
            PSRestartOwedSection(project: p) { Task { await box.reload(model.api, slug: slug); onChange() } }

            Section("Identity") {
                TextField("Project name", text: $name)
                LabeledContent("Slug") { Text(p["slug"].string ?? slug).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                Text("Cannot be changed after creation. The avatar is changed from the web dashboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("https://github.com/user/repo", text: $repoUrl)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .ownerOnly(p)
                LabeledContent("Branch") {
                    TextField("main", text: $branch).multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if !repoUrl.trimmingCharacters(in: .whitespaces).isEmpty {
                Picker("GitHub access", selection: $githubAccess) {
                    Text("All repositories").tag("all")
                    Text("This repository").tag("repo")
                }.ownerOnly(p)
                }
                if githubAccess == "repo" && !repoUrl.trimmingCharacters(in: .whitespaces).isEmpty {
                    LabeledContent("Other repositories") {
                        TextField("owner/other-repo", text: $extraRepos).multilineTextAlignment(.trailing).ownerOnly(p)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                SecureField(p["hasGithubPat"].bool == true ? "A token is set — type to replace it" : "github_pat_…", text: $pat)
                    .disabled(clearPat || !p.psOwner)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if p["hasGithubPat"].bool == true {
                    Toggle("Remove the token", isOn: $clearPat).ownerOnly(p)
                }
                PSOwnerOnlyNote(project: p)
            } header: {
                Text("Repository")
            } footer: {
                Text(githubAccess == "all"
                     ? "GitHub access: can push to every repository your GitHub App reaches, as on your own computer. GitHub token: for a repository the App is not installed on."
                     : "GitHub access: only this repository and the others listed (same owner, owner/name). GitHub token: for a repository the App is not installed on.")
            }

            grants

            PSSaveSection(
                consequence: PSRestart.consequence(changed: Set(patch.keys), running: p.psRunning),
                busy: action.busy, saved: saved, disabled: patch.isEmpty || !p.psCan("configure"), save: save)

            PSSharingSection(slug: slug)

            if p.psCan("configure") { deleteSection }
        }
        .errorAlert(action)
        .onAppear { if !loaded { fill(); loaded = true } }
    }

    /// Operator grants, shown and not set: an admin sees the state and where to
    /// change it; an owner sees a row only when the grant is on.
    @ViewBuilder private var grants: some View {
        let deploy = p["deployTarget"]["name"].string
        let host = p["hostAccess"].bool == true
        if model.isAdmin || host || deploy != nil {
            Section {
                if deploy != nil || model.isAdmin {
                    LabeledContent {
                        Text(deploy ?? "None").font(.system(.footnote, design: .monospaced))
                    } label: {
                        PSLabel(title: "Deploy", detail: deploy != nil
                                ? "The stack this project redeploys with dockai-deploy."
                                : "An admin chooses which project may redeploy a Compose stack on this host.")
                    }
                }
                if model.isAdmin || host {
                    LabeledContent {
                        Text(host ? "On" : "Off").foregroundStyle(host ? .green : .secondary)
                    } label: {
                        PSLabel(title: "Own Docker daemon", detail: model.isAdmin
                                ? "A privileged worker; an admin grants it under Admin → Access and it applies on restart."
                                : "An admin granted this project a privileged worker with its own Docker daemon.")
                    }
                }
            } header: {
                if model.isAdmin { Text("Set by an admin") }
            } footer: {
                if model.isAdmin { Text("Set in Admin → Access.") }
            }
        }
    }

    private var deleteSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Delete project").font(.headline)
                Text("Removes the project from DockAI and deletes its worker.").font(.callout)
                Text("Permanently destroys \(p["name"].string ?? slug)’s workspace and anything uncommitted in it, its shell history and hand-installed tools, and its conversations.")
                    .font(.callout).foregroundStyle(.red)
                Text("The Claude account and its credentials are shared with your other projects and are not touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ConfirmButton(title: "Delete", confirmTitle: "Delete for good?") {
                guard let id = p["id"].string else { return }
                action.run {
                    _ = try await model.api?.mutate("project.delete", .from(["id": id]))
                    await MainActor.run { dismiss() }
                    onChange()
                }
            }
        } header: {
            Text("Danger zone").foregroundStyle(.red)
        }
    }

    private func fill() {
        name = p["name"].string ?? ""
        repoUrl = p["githubRepoUrl"].string ?? ""
        branch = p["githubBranch"].string ?? "main"
        githubAccess = p["githubAccess"].string == "all" ? "all" : "repo"
        extraRepos = p["githubExtraRepos"].array.compactMap(\.string).joined(separator: ", ")
        pat = ""
        clearPat = false
    }

    private func save() {
        guard let id = p["id"].string else { return }
        var input = patch
        guard !input.isEmpty else { return }
        input["id"] = .string(id)
        action.run {
            _ = try await model.api?.mutate("project.update", .object(input))
            await box.reload(model.api, slug: slug)
            fill()
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
            onChange()
        }
    }
}

/// Who else on this install can reach the project. Only the owner sees it,
/// because only the owner may change it.
struct PSSharingSection: View {
    let slug: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var data: JSON = .null
    @State private var loadError: Error?
    @State private var email = ""
    @State private var role = "VIEWER"

    var body: some View {
        Group {
            if let loadError {
                Section("People") { ErrorBanner(error: loadError) { Task { await load() } } }
            } else if data.isNull {
                Section("People") { ProgressView() }
            } else if data["canManage"].bool == true {
                Section {
                    TextField("someone@example.com", text: $email)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Role", selection: $role) {
                        Text("Viewer").tag("VIEWER")
                        Text("Collaborator").tag("COLLABORATOR")
                    }
                    Text(role == "VIEWER"
                         ? "Can watch conversations, agent runs and logs, but cannot start, change or open a terminal."
                         : "Drives Claude with the project's permissions, so share only with someone you'd trust with its files and secrets.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        let e = email.trimmingCharacters(in: .whitespaces)
                        guard !e.isEmpty else { return }
                        action.run {
                            _ = try await model.api?.mutate("member.add", .from(["slug": slug, "email": e, "role": role]))
                            email = ""
                            await load()
                        }
                    } label: { Label("Share", systemImage: "person.badge.plus") }
                        .disabled(action.busy || email.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("People")
                } footer: {
                    Text("Who else on this install can reach this project.")
                }

                Section {
                    let members = data["members"].array
                    if members.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Not shared with anyone")
                            Text("They need an account here before you can add them.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(members, id: \.self) { m in memberRow(m) }
                }
            }
        }
        .errorAlert(action)
        .task { await load() }
    }

    private func memberRow(_ m: JSON) -> some View {
        let id = m["id"].string ?? ""
        let r = m["role"].string ?? "VIEWER"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(m["user"]["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? m["user"]["email"].string ?? "—")
                HStack(spacing: 6) {
                    StatePill(text: r == "COLLABORATOR" ? "Collaborator" : "Viewer", tone: r == "COLLABORATOR" ? .accent : .neutral)
                    Text(m["user"]["email"].string ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Button("Make viewer") { setRole(id, "VIEWER") }.disabled(r == "VIEWER")
                Button("Make collaborator") { setRole(id, "COLLABORATOR") }.disabled(r == "COLLABORATOR")
            } label: { Image(systemName: "ellipsis.circle") }
                .disabled(action.busy)
        }
        .swipeActions {
            Button("Remove", role: .destructive) {
                action.run {
                    _ = try await model.api?.mutate("member.remove", .from(["slug": slug, "memberId": id]))
                    await load()
                }
            }
        }
    }

    private func setRole(_ id: String, _ role: String) {
        action.run {
            _ = try await model.api?.mutate("member.setRole", .from(["slug": slug, "memberId": id, "role": role]))
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { data = try await api.query("member.list", .from(["slug": slug])); loadError = nil } catch { loadError = error }
    }
}
