// tRPC: claudeAccount.list, claudeAccount.create, claudeAccount.rename, claudeAccount.delete, claudeAccount.checkValid, claudeAccount.setSdkToken, claudeAccount.resetCredentials, claudeAccount.getAccountDetails, project.list
import SwiftUI

/// Settings → Claude accounts: a row per account, its state in words, the
/// row opening the account. Adding one names it and offers the sign-in.
struct ClaudeAccountsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var accounts: JSON?
    @State private var projects: JSON = .array([])
    @State private var error: Error?
    @State private var adding = false
    @State private var newLabel = "Default"
    @State private var created: String?
    @State private var signingIn: SignInTarget?

    var body: some View {
        List {
            if let error { ErrorBanner(error: error, retry: { Task { await load() } }) }
            if let accounts {
                if accounts.array.isEmpty {
                    ContentUnavailableView {
                        Label("Link the Claude account DockAI will code with.", systemImage: "checkmark.shield")
                    } description: {
                        Text("Sign in once with your Pro or Max subscription and every project can run the Claude CLI.")
                    } actions: {
                        Button("Add account") { adding = true }.buttonStyle(.bordered)
                    }
                }
                Section {
                    ForEach(accounts.array, id: \.self) { a in
                        NavigationLink {
                            ClaudeAccountDetailView(accountId: a["id"].string ?? "")
                        } label: { row(a) }
                    }
                } footer: {
                    if !accounts.array.isEmpty { Text("Each account has its own credentials; a project picks one.") }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Claude accounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add account")
            }
        }
        .alert("Add a Claude account", isPresented: $adding) {
            TextField("Name", text: $newLabel)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create() }
        } message: {
            Text("A name for this account, such as Personal or Work. You sign in next.")
        }
        .confirmationDialog("Account created", isPresented: Binding(get: { created != nil }, set: { if !$0 { created = nil } }), titleVisibility: .visible) {
            Button("Sign in now") { if let id = created { signingIn = SignInTarget(id: id) }; created = nil }
            Button("Later", role: .cancel) { created = nil }
        } message: {
            Text("Sign in with the Claude subscription this account uses.")
        }
        .sheet(item: $signingIn) { target in
            ClaudeSignInSheet(accountId: target.id) { Task { await load() } }
        }
        .errorAlert(action)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ a: JSON) -> some View {
        let state = ClaudeAccountState(a)
        let linked = projects.array.filter { $0["claudeAccountId"].string == a["id"].string }.count
        let meta = [
            linked > 0 ? "\(linked) project\(linked == 1 ? "" : "s")" : nil,
            settingsDate(a["lastChecked"]).map { "Checked \($0)" },
        ].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: a["isValid"].bool == true ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(a["isValid"].bool == true ? .green : .orange)
                Text(a["label"].string ?? "Account").lineLimit(1)
                StatePill(text: state.label, tone: state.tone)
                if let tier = a["subscriptionTier"].string { StatePill(text: claudeTierLabel(tier), tone: .accent) }
            }
            if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func create() {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        action.run {
            guard let api = model.api else { return }
            let r = try await api.mutate("claudeAccount.create", .from(["label": label]))
            newLabel = "Default"
            await load()
            created = r["id"].string
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            accounts = try await api.query("claudeAccount.list")
            error = nil
        } catch { self.error = error }
        if let p = try? await api.query("project.list") { projects = p }
    }
}

struct SignInTarget: Identifiable { let id: String }

/// One account: its facts, how it authenticates (sign-in, re-check, reset, the
/// long-lived token), its conversations, and delete with what it costs.
struct ClaudeAccountDetailView: View {
    let accountId: String
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var action = Action()
    @State private var account: JSON?
    @State private var details: JSON = .null
    @State private var projects: JSON = .array([])
    @State private var error: Error?
    @State private var label = ""
    @State private var token = ""
    @State private var showToken = false
    @State private var tokenOpen = false
    @State private var checkNote: String?
    @State private var signingIn = false

    var body: some View {
        List {
            if let error { ErrorBanner(error: error, retry: { Task { await load() } }) }
            if let account {
                content(account)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(account?["label"].string ?? "Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(action.busy)
        .errorAlert(action)
        .sheet(isPresented: $signingIn) {
            ClaudeSignInSheet(accountId: accountId) { Task { await load() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func content(_ account: JSON) -> some View {
        let state = ClaudeAccountState(account)
        let isValid = account["isValid"].bool == true
        let hasToken = account["hasSdkToken"].bool == true

        Section("Account") {
            TextField("Name", text: $label)
                .onSubmit { rename() }
                .submitLabel(.done)
            if let tier = details["subscriptionTier"].string ?? account["subscriptionTier"].string {
                LabeledContent("Plan", value: claudeTierLabel(tier))
            }
            if let email = details["email"].string {
                LabeledContent("Email") { Text(email).textSelection(.enabled) }
            }
            if let org = details["orgUuid"].string {
                LabeledContent("Organization") { Text(org).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if let rate = details["rateLimitTier"].string {
                LabeledContent("Rate limit", value: claudeTierLabel(rate))
            }
            if let created = settingsDate(account["createdAt"]) { LabeledContent("Created", value: created) }
            if let checked = settingsDate(account["lastChecked"]) { LabeledContent("Last checked", value: checked) }
        }

        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Status")
                    Text(state.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatePill(text: state.label, tone: state.tone)
            }
            Button { recheck() } label: { Label("Check again", systemImage: "arrow.clockwise") }
            if let checkNote { Text(checkNote).font(.caption).foregroundStyle(.secondary) }
            Button { signingIn = true } label: {
                Label(isValid ? "Sign in again" : "Sign in", systemImage: "person.badge.key")
            }
            if isValid {
                ConfirmButton(title: "Reset credentials", confirmTitle: "Sign out? Tap again") {
                    mutate("claudeAccount.resetCredentials", ["id": accountId])
                }
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text(isValid
                 ? "Reset: every project on this account loses Claude until you sign in again."
                 : "Signing in is the only way to get Remote Control; it works before any project exists.")
        }

        Section {
            DisclosureGroup(isExpanded: $tokenOpen) {
                Text("A claude setup-token credential runs agent runs, automations and the assistant API without an interactive login. Anthropic scopes these to inference, so use one alongside a sign-in, not instead of one.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Group {
                        if showToken { TextField("sk-ant-oat01-…", text: $token) }
                        else { SecureField("sk-ant-oat01-…", text: $token) }
                    }
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(showToken ? "Hide" : "Show") { showToken.toggle() }.buttonStyle(.borderless)
                }
                Button("Save token") {
                    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    token = ""
                    mutate("claudeAccount.setSdkToken", ["id": accountId, "token": value])
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasToken {
                    ConfirmButton(title: "Remove token", confirmTitle: "Remove?") {
                        mutate("claudeAccount.setSdkToken", ["id": accountId, "token": nil])
                    }
                }
            } label: {
                HStack {
                    Text("Long-lived token")
                    StatePill(text: "No Remote Control")
                    if hasToken { StatePill(text: "Set", tone: .accent) }
                }
            }
        }

        Section {
            NavigationLink {
                AccountConversationsView(accountId: accountId)
            } label: { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
        }

        Section {
            ConfirmButton(title: "Delete account", confirmTitle: "Delete for good?") { delete() }
        } header: {
            Text("Danger zone")
        } footer: {
            let affected = projects.array.filter { $0["claudeAccountId"].string == accountId }.compactMap { $0["name"].string }
            VStack(alignment: .leading, spacing: 4) {
                Text("Removes its credentials and every conversation stored with them.")
                if !affected.isEmpty {
                    Text("\(affected.count) project\(affected.count == 1 ? " loses" : "s lose") Claude: \(affected.joined(separator: ", "))")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Actions

    private func rename() {
        let v = label.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != account?["label"].string else { return }
        mutate("claudeAccount.rename", ["id": accountId, "label": v])
    }

    /// "Could not check" is not "not signed in": the reason travels and is said.
    private func recheck() {
        checkNote = nil
        action.run {
            guard let api = model.api else { return }
            let r = try await api.mutate("claudeAccount.checkValid", .from(["id": accountId]))
            switch r["reason"].string {
            case "check-failed": checkNote = "Could not check right now\(r["detail"].string.map { ": \($0)" } ?? ""). This is not the same as signed out."
            case "unconfirmed": checkNote = "The access token has expired unused, so there is nothing to confirm yet."
            case "no-credentials": checkNote = "No credentials on this account yet."
            case "login-refused": checkNote = "Anthropic refused this login; sign in again."
            default: checkNote = r["valid"].bool == true ? "Signed in." : nil
            }
            await load()
        }
    }

    private func delete() {
        action.run {
            guard let api = model.api else { return }
            _ = try await api.mutate("claudeAccount.delete", .from(["id": accountId]))
            dismiss()
        }
    }

    private func mutate(_ path: String, _ input: [String: Any?]) {
        action.run {
            guard let api = model.api else { return }
            _ = try await api.mutate(path, .from(input))
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list = try await api.query("claudeAccount.list")
            guard let found = list.array.first(where: { $0["id"].string == accountId }) else {
                throw TRPCError(code: "NOT_FOUND", message: "This account no longer exists.")
            }
            if account?["label"] != found["label"] { label = found["label"].string ?? "" }
            account = found
            error = nil
        } catch { self.error = error }
        if let p = try? await api.query("project.list") { projects = p }
        // Plan, email and organization come from a second, optional call
        // (experimental account details); without it they are simply absent.
        if let d = try? await api.query("claudeAccount.getAccountDetails", .from(["id": accountId])) {
            details = d["details"]
        }
    }
}
