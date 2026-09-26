// tRPC: github.isConfigured, github.connection, github.disconnect, github.permissionStatus, users.getGitIdentity, users.updateGitIdentity, sshKey.list, sshKey.add, sshKey.remove, apiToken.list, apiToken.create, apiToken.revoke
import SwiftUI

/// Settings → GitHub. Connecting is an OAuth round trip that
/// `/api/github/authorize` starts from a signed-in browser session, so it
/// opens in Safari; disconnecting is a call.
struct GitHubSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @StateObject private var action = Action()
    @State private var configured: Bool?
    @State private var connection: JSON?
    @State private var permissions: JSON?
    @State private var error: Error?
    @State private var gitName = ""
    @State private var gitEmail = ""
    @State private var gitSaved: String?

    var body: some View {
        List {
            if let error { ErrorBanner(error: error, retry: { Task { await load() } }) }
            if configured == false {
                Section {
                    Text("No GitHub App is configured on this install. An administrator creates one and sets GITHUB_APP_ID, GITHUB_APP_CLIENT_ID, GITHUB_APP_CLIENT_SECRET and GITHUB_APP_PRIVATE_KEY_BASE64 on the server.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if let connection {
                if connection["connected"].bool == true {
                    Section {
                        HStack {
                            Text(connection["githubLogin"].string ?? "GitHub").font(.body.monospaced())
                            Spacer()
                            if connection["installationId"].isNull {
                                StatePill(text: "App not installed on repos", tone: .warn)
                            } else {
                                StatePill(text: "App installed", tone: .ok)
                            }
                        }
                        ConfirmButton(title: "Disconnect", confirmTitle: "Disconnect?") {
                            action.run {
                                _ = try await model.api?.mutate("github.disconnect")
                                await load()
                            }
                        }
                    } footer: {
                        Text("Disconnecting stops repo listing and cloning in every project.")
                    }
                    if permissions?["needsAcceptance"].bool == true, let u = permissions?["installationUrl"].string, let url = URL(string: u) {
                        Section {
                            Label("Additional permissions required", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text("Git push needs \"Contents: Read & write\" — accept the updated permissions in GitHub.").font(.callout)
                            Button { openURL(url) } label: { Label("Accept in GitHub", systemImage: "arrow.up.forward.app") }
                        }
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not connected")
                            Text("Browse and clone your repositories.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            if let url = webURL(model, "api/github/authorize") { openURL(url) }
                        } label: { Label("Connect GitHub in Safari", systemImage: "safari") }
                    } footer: {
                        Text("Safari needs to be signed in to DockAI. Come back here and pull to refresh once GitHub has sent you back.")
                    }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            // The identity every project commits as; each worker's ~/.gitconfig
            // is its own, so DockAI writes these two values into all of them.
            Section {
                TextField("Name", text: $gitName).textInputAutocapitalization(.words).autocorrectionDisabled()
                TextField("you@example.com", text: $gitEmail)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save") {
                    action.run {
                        let n = gitName.trimmingCharacters(in: .whitespaces), e = gitEmail.trimmingCharacters(in: .whitespaces)
                        let r = try await model.api?.mutate("users.updateGitIdentity", .from([
                            "name": n.isEmpty ? JSON.null : JSON.string(n),
                            "email": e.isEmpty ? JSON.null : JSON.string(e),
                        ])) ?? .null
                        let missed = r["notUpdated"].array.compactMap(\.string)
                        await MainActor.run {
                            gitSaved = missed.isEmpty ? "Saved in every running project."
                                : "Saved. Applies at the next start of: \(missed.joined(separator: ", "))."
                        }
                    }
                }
                if let gitSaved { Text(gitSaved).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Git identity")
            } footer: {
                Text("Every project commits as this; empty uses your GitHub login.")
            }
        }
        .navigationTitle("GitHub")
        .errorAlert(action)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let c = try await api.query("github.isConfigured")
            configured = c["configured"].bool == true
            if configured == true {
                connection = try await api.query("github.connection")
                if connection?["connected"].bool == true { permissions = try? await api.query("github.permissionStatus") }
            }
            let id = try await api.query("users.getGitIdentity")
            gitName = id["name"].string ?? ""
            gitEmail = id["email"].string ?? ""
            error = nil
        } catch { self.error = error }
    }
}

/// Settings → SSH keys: public keys for reaching a project's worker over
/// SSH. Adding or removing one reaches running workers at once.
struct SshKeysView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var publicKey = ""

    var body: some View {
        Loader(load: { try await model.api?.query("sshKey.list") ?? .array([]) }) { keys, reload in
            Form {
                Section {
                    if keys.array.isEmpty {
                        Text("No SSH keys yet. Add one below.").foregroundStyle(.secondary)
                    }
                    ForEach(keys.array, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: "key").foregroundStyle(.secondary)
                                Text(key["name"].string ?? "Key").lineLimit(1)
                                Spacer()
                                ConfirmButton(title: "Remove", confirmTitle: "Remove?") {
                                    action.run {
                                        _ = try await model.api?.mutate("sshKey.remove", .from(["id": key["id"].string ?? ""]))
                                        reload()
                                    }
                                }
                                .buttonStyle(.borderless).font(.callout)
                            }
                            Text(key["fingerprint"].string ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            if let added = settingsDate(key["createdAt"]) { Text("Added \(added)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } footer: {
                    Text("Public keys for reaching a project's worker over SSH.")
                }
                Section("Add an SSH key") {
                    TextField("Name, e.g. MacBook", text: $name)
                    TextField("ssh-ed25519 AAAA… or ssh-rsa AAAA…", text: $publicKey, axis: .vertical)
                        .font(.caption.monospaced())
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add key") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        let k = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        action.run {
                            _ = try await model.api?.mutate("sshKey.add", .from(["name": n, "publicKey": k]))
                            name = ""; publicKey = ""
                            reload()
                        }
                    }
                    .disabled(action.busy || name.trimmingCharacters(in: .whitespaces).isEmpty || publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle("SSH keys")
        .errorAlert(action)
    }
}

/// Settings → API tokens: personal tokens for the dockai CLI, carrying full
/// account access. Session-only on the server; a paired device counts as one.
struct ApiTokensView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var expiry = "never"
    @State private var created: JSON?

    var body: some View {
        Loader(load: { try await model.api?.query("apiToken.list") ?? .array([]) }) { tokens, reload in
            Form {
                if let created, let token = created["token"].string {
                    Section {
                        Label("Token created", systemImage: "checkmark.circle").foregroundStyle(.green)
                        Text("Copy this token now. You won't be able to see it again.").font(.callout)
                        CopyRow(text: token)
                        Button("Done") { self.created = nil }
                    }
                }
                Section {
                    if tokens.array.isEmpty { Text("No tokens yet.").foregroundStyle(.secondary) }
                    ForEach(tokens.array, id: \.self) { tok in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(tok["name"].string ?? "Token").lineLimit(1)
                                if let exp = tok["expiresAt"].date, exp < .now { StatePill(text: "Expired", tone: .danger) }
                                Spacer()
                                ConfirmButton(title: "Revoke", confirmTitle: "Revoke?") {
                                    action.run {
                                        _ = try await model.api?.mutate("apiToken.revoke", .from(["id": tok["id"].string ?? ""]))
                                        reload()
                                    }
                                }
                                .buttonStyle(.borderless).font(.callout)
                            }
                            Text("\(tok["prefix"].string ?? "")…").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text([
                                settingsDate(tok["lastUsedAt"]).map { "Last used \($0)" } ?? "Never used",
                                settingsDate(tok["expiresAt"]).map { "Expires \($0)" },
                            ].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Personal tokens for the dockai CLI; they carry your full account access.")
                }
                Section("New token") {
                    TextField("Name, e.g. MacBook CLI", text: $name)
                    Picker("Expires", selection: $expiry) {
                        Text("Never").tag("never")
                        Text("30 days").tag("30")
                        Text("90 days").tag("90")
                        Text("1 year").tag("365")
                    }
                    Button("Create token") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        var input: [String: Any?] = ["name": n]
                        if let days = Int(expiry) { input["expiresInDays"] = days }
                        action.run {
                            guard let api = model.api else { return }
                            created = try await api.mutate("apiToken.create", .from(input))
                            name = ""
                            reload()
                        }
                    }
                    .disabled(action.busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("API tokens")
        .errorAlert(action)
    }
}
