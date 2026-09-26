// tRPC: project.create, github.isConfigured, github.connection, github.listRepos, github.listBranches, claudeAccount.list
import SwiftUI

/// New project: name and address, a repository (picked from GitHub or typed),
/// the Claude account, and what the worker may reach on the local network.
struct NewProjectView: View {
    let onCreated: (String) -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var slug = ""
    @State private var slugManual = false
    @State private var repoMode = "github"
    @State private var repoUrl = ""
    @State private var branch = "main"
    @State private var githubAccess = "repo"
    @State private var selectedRepo = ""
    @State private var accountId = ""
    @State private var networkMode = "internet"
    @State private var allowedHosts = ""

    @State private var githubConfigured: Bool?
    @State private var githubConnectionId: String?
    @State private var githubLoadError: Error?
    @State private var accounts: [JSON]?
    @State private var accountsError: Error?
    @State private var creating = false
    @State private var createError: Error?

    var body: some View {
        Form {
            Section {
                TextField("Project name", text: $name)
                    .onChange(of: name) { _, v in if !slugManual { slug = Self.toSlug(v) } }
                TextField("my-awesome-project", text: Binding(get: { slug }, set: { slug = $0; slugManual = true }))
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Identity") } footer: {
                Text(slugValid || slug.isEmpty ? "The address the project lives at: lowercase letters, digits and hyphens." : "Use lowercase letters, digits and hyphens, not starting or ending with a hyphen.")
                    .foregroundStyle(slugValid || slug.isEmpty ? Color.secondary : Color.red)
            }

            RepoSection(mode: $repoMode, repoUrl: $repoUrl, branch: $branch, selectedRepo: $selectedRepo,
                        githubAvailable: githubConfigured == true && githubConnectionId != nil,
                        githubConfigured: githubConfigured, githubLoadError: githubLoadError,
                        retry: { Task { await loadGitHub() } })

            if !repoUrl.isEmpty {
                Section {
                    Picker("GitHub access", selection: $githubAccess) {
                        Text("All repositories").tag("all")
                        Text("This repository").tag("repo")
                    }
                } footer: {
                    Text(githubAccess == "all"
                         ? "Can push to every repository your GitHub App reaches, as on your own computer."
                         : "Can push only to this repository; add others later in Settings → General.")
                }
            }

            Section {
                if let accounts {
                    if accounts.isEmpty {
                        Text("No Claude accounts linked yet. Add one in Settings → Claude accounts.").foregroundStyle(.secondary)
                    } else {
                        Picker("Claude account", selection: $accountId) {
                            Text("None").tag("")
                            ForEach(accounts, id: \.self) { a in
                                Text(accountLabel(a)).tag(a["id"].string ?? "")
                            }
                        }
                    }
                } else if let accountsError {
                    ErrorBanner(error: accountsError) { Task { await loadAccounts() } }
                } else {
                    ProgressView()
                }
            } footer: {
                if accounts != nil && accountId.isEmpty {
                    Text("Without an account, Claude cannot start in this project.").foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Local network", selection: $networkMode) {
                    Text("Internet only (no LAN)").tag("internet")
                    Text("Internet + specific hosts").tag("custom")
                    Text("Full local network").tag("full")
                }
                if networkMode == "custom" {
                    TextField("192.168.1.10:8123", text: $allowedHosts, axis: .vertical)
                        .font(.body.monospaced()).lineLimit(3...6)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: {
                Text(networkMode == "custom"
                     ? "One IP, IP:port or CIDR per line — names are not resolved."
                     : "What this project can reach on your local network; the internet and package registries always work.")
            }

            if let createError {
                Section { Text(createError.localizedDescription).foregroundStyle(.red) }
            }
        }
        .navigationTitle("New project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if creating { ProgressView() } else {
                    Button("Create") { Task { await create() } }.disabled(name.isEmpty || !slugValid)
                }
            }
        }
        .task { await loadGitHub() }
        .task { await loadAccounts() }
    }

    private var slugValid: Bool {
        slug.range(of: "^[a-z0-9][a-z0-9-]*[a-z0-9]$", options: .regularExpression) != nil && slug.count <= 48
    }

    static func toSlug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var dash = false
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); dash = false }
            else if !dash && !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private func accountLabel(_ a: JSON) -> String {
        let label = a["label"].string ?? "Account"
        if a["isValid"].bool == true { return label }
        return label + (a["hasSdkToken"].bool == true ? " (Token only)" : " (Not signed in)")
    }

    private func loadGitHub() async {
        guard let api = model.api else { return }
        do {
            githubConfigured = try await api.query("github.isConfigured")["configured"].bool ?? false
            let conn = try await api.query("github.connection")
            githubConnectionId = conn["connected"].bool == true ? conn["id"].string : nil
            githubLoadError = nil
            if githubConnectionId == nil && githubConfigured == false { repoMode = "manual" }
        } catch { githubLoadError = error }
    }

    private func loadAccounts() async {
        guard let api = model.api else { return }
        do {
            let list = try await api.query("claudeAccount.list").array
            accounts = list
            accountsError = nil
            if accountId.isEmpty, let preferred = list.first(where: { $0["isValid"].bool == true }) ?? list.first {
                accountId = preferred["id"].string ?? ""
            }
        } catch { accountsError = error }
    }

    private func create() async {
        guard let api = model.api else { return }
        creating = true
        defer { creating = false }
        var input: [String: Any?] = [
            "name": name, "slug": slug, "githubBranch": branch.isEmpty ? "main" : branch,
            "networkMode": networkMode,
        ]
        if !repoUrl.trimmingCharacters(in: .whitespaces).isEmpty { input["githubRepoUrl"] = repoUrl.trimmingCharacters(in: .whitespaces) }
        if input["githubRepoUrl"] != nil { input["githubAccess"] = githubAccess }
        if repoMode == "github", let id = githubConnectionId { input["githubConnectionId"] = id }
        if !accountId.isEmpty { input["claudeAccountId"] = accountId }
        if networkMode == "custom" {
            input["networkAllowedHosts"] = JSON.array(allowedHosts.split(whereSeparator: { $0.isWhitespace }).map { JSON.string(String($0)) })
        }
        do {
            let project = try await api.mutate("project.create", .from(input))
            createError = nil
            onCreated(project["slug"].string ?? slug)
        } catch { createError = error }
    }
}

/// The repository: a GitHub repo searched through the App's installation, or
/// any URL typed by hand (GitLab, Gitea, self-hosted).
private struct RepoSection: View {
    @Binding var mode: String
    @Binding var repoUrl: String
    @Binding var branch: String
    @Binding var selectedRepo: String
    let githubAvailable: Bool
    let githubConfigured: Bool?
    let githubLoadError: Error?
    let retry: () -> Void

    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var repos: [JSON] = []
    @State private var reposError: Error?
    @State private var loadingRepos = false
    @State private var branches: [JSON] = []
    @State private var branchesError: Error?

    var body: some View {
        Section {
            if let githubLoadError {
                ErrorBanner(error: githubLoadError, retry: retry)
            }
            Picker("Source", selection: $mode) {
                Text("GitHub").tag("github")
                Text("Manual").tag("manual")
            }.pickerStyle(.segmented)

            if mode == "github" {
                if githubAvailable { githubPicker } else {
                    Text(githubConfigured == true
                         ? "Connect your GitHub account in Settings → GitHub to pick a repository."
                         : "GitHub is not set up on this install. Use Manual to type a repository URL.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                TextField("https://github.com/user/repo", text: $repoUrl)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                if !repoUrl.isEmpty {
                    TextField("Branch", text: $branch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                }
            }
        } header: { Text("Repository") } footer: { Text("Optional. Cloned into the workspace on first start.") }
    }

    @ViewBuilder private var githubPicker: some View {
        if selectedRepo.isEmpty {
            TextField("Search repositories", text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .task(id: search) {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await loadRepos()
                }
            if loadingRepos && repos.isEmpty { ProgressView() }
            if let reposError { ErrorBanner(error: reposError) { Task { await loadRepos() } } }
            ForEach(repos.prefix(25), id: \.self) { r in
                Button { pick(r) } label: {
                    HStack {
                        Text(r["fullName"].string ?? "").foregroundStyle(.primary)
                        Spacer()
                        if r["private"].bool == true { Image(systemName: "lock").foregroundStyle(.secondary) }
                    }
                }
            }
            if !loadingRepos && reposError == nil && repos.isEmpty {
                Link("No repositories found — check where the GitHub App is installed", destination: URL(string: "https://github.com/settings/installations")!)
                    .font(.footnote)
            }
        } else {
            HStack {
                Label(selectedRepo, systemImage: "chevron.left.forwardslash.chevron.right")
                Spacer()
                Button("Change") { selectedRepo = ""; repoUrl = ""; branches = [] }.font(.footnote)
            }
            if let branchesError {
                ErrorBanner(error: branchesError) { Task { await loadBranches() } }
            } else if branches.isEmpty {
                HStack { Text("Branch"); Spacer(); ProgressView() }
            } else {
                Picker("Branch", selection: $branch) {
                    ForEach(branchNames, id: \.self) { b in Text(b).tag(b) }
                }
            }
        }
    }

    private var branchNames: [String] {
        let names = branches.compactMap { $0["name"].string }
        return names.contains(branch) ? names : [branch] + names
    }

    private func pick(_ r: JSON) {
        selectedRepo = r["fullName"].string ?? ""
        repoUrl = r["cloneUrl"].string ?? ""
        branch = r["defaultBranch"].string ?? "main"
        search = ""
        Task { await loadBranches() }
    }

    private func loadRepos() async {
        guard let api = model.api else { return }
        loadingRepos = true
        defer { loadingRepos = false }
        do {
            let input: JSON = search.isEmpty ? .object([:]) : .from(["search": search])
            repos = try await api.query("github.listRepos", input).array
            reposError = nil
        } catch { reposError = error }
    }

    private func loadBranches() async {
        guard let api = model.api else { return }
        let parts = selectedRepo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        do {
            branches = try await api.query("github.listBranches", .from(["owner": parts[0], "repo": parts[1]])).array
            branchesError = nil
        } catch { branchesError = error }
    }
}
