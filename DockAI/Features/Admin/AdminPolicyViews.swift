// tRPC: admin.system.getSettings, admin.system.updateSettings, admin.notifications.status, admin.notifications.telegram, admin.notifications.setTelegram, admin.pushConfig, admin.setPushConfig
import SwiftUI

/// The install's settings row, shared by Authentication and Experimental:
/// read once, each toggle written by itself and the row read back.
@MainActor
final class AdminSystemSettings: ObservableObject {
    @Published var value: JSON?
    @Published var error: Error?
    @Published var saving = false

    func load(_ api: TRPCClient?) async {
        guard let api else { return }
        do { value = try await api.query("admin.system.getSettings"); error = nil } catch { self.error = error }
    }

    func set(_ api: TRPCClient?, _ key: String, _ on: Bool) async {
        guard let api else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await api.mutate("admin.system.updateSettings", .from([key: on]))
            await load(api)
        } catch { self.error = error }
    }

    func binding(_ api: TRPCClient?, _ key: String, default def: Bool = false) -> Binding<Bool> {
        Binding(get: { self.value?[key].bool ?? def }, set: { v in Task { await self.set(api, key, v) } })
    }
}

// MARK: - Authentication

/// Admin → Authentication (pages/admin/SecuritySection.tsx).
struct AdminSecurityView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var settings = AdminSystemSettings()
    @State private var status: JSON?
    @State private var statusError: Error?

    var body: some View {
        let smtp = status?["smtp"].bool
        List {
            Section {
                if let statusError {
                    ErrorBanner(error: statusError, retry: { Task { await load() } })
                } else if let status {
                    LabeledContent("SMTP (Email)") {
                        StatePill(text: smtp == true ? "SMTP configured" : "SMTP not configured", tone: smtp == true ? .ok : .warn)
                    }
                    let missing = status["smtpMissingVars"].array.compactMap(\.string)
                    if smtp != true && !missing.isEmpty {
                        Text("Missing environment variables: \(missing.joined(separator: ", "))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            } footer: { Text("Set SMTP_HOST, SMTP_PORT, SMTP_USER and SMTP_PASS in the environment.") }

            Section {
                if let e = settings.error {
                    ErrorBanner(error: e, retry: { Task { await settings.load(model.api) } })
                }
                if settings.value != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Require email verification", isOn: settings.binding(model.api, "requireEmailVerification"))
                            .disabled(settings.saving || (smtp == false && settings.value?["requireEmailVerification"].bool != true))
                        Text(smtp == false ? "SMTP must be configured to enable email verification" : "A new user cannot sign in until they follow the link.")
                            .font(.caption).foregroundStyle(smtp == false ? .orange : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Disable public sign-up", isOn: settings.binding(model.api, "disableSignUp")).disabled(settings.saving)
                        Text("Only an admin can create a user.").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Passkey-only login", isOn: settings.binding(model.api, "passkeyOnlyMode")).disabled(settings.saving)
                        Text("Email and password sign-in is switched off.").font(.caption).foregroundStyle(.secondary)
                        Label("Make sure all users have registered a passkey before enabling this", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else if settings.error == nil {
                    ProgressView()
                }
            } footer: { Text("Who can sign in to this install, and how.") }
        }
        .navigationTitle("Authentication")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        await settings.load(model.api)
        guard let api = model.api else { return }
        do { status = try await api.query("admin.notifications.status"); statusError = nil } catch { statusError = error }
    }
}

// MARK: - Experimental

/// Admin → Experimental (pages/admin/ExperimentalSection.tsx).
struct AdminExperimentalView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var settings = AdminSystemSettings()

    var body: some View {
        List {
            Section {
                Label("These features use undocumented Anthropic APIs that may stop working without notice.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            Section {
                if let e = settings.error { ErrorBanner(error: e, retry: { Task { await settings.load(model.api) } }) }
                if let v = settings.value {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Advanced API features", isOn: settings.binding(model.api, "experimentalApiFeatures")).disabled(settings.saving)
                        Text("Subscription tier, rate limits and the live model list, from undocumented Anthropic APIs.").font(.caption).foregroundStyle(.secondary)
                    }
                    if v["experimentalApiFeatures"].bool == true {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Restrict to admins only", isOn: settings.binding(model.api, "experimentalAdminOnly", default: true)).disabled(settings.saving)
                            Text("Only admins see and switch the advanced API features on their Claude accounts.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if settings.error == nil {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Experimental")
        .task { await settings.load(model.api) }
        .refreshable { await settings.load(model.api) }
    }
}

// MARK: - Notification service

/// Admin → Notifications (pages/admin/NotificationsSection.tsx): the Telegram
/// bot and the APNs key for this app. Email lives under Authentication.
struct AdminNotificationsView: View {
    var body: some View {
        List {
            AdminTelegramSection()
            AdminPushSection()
            Section {
                Text("Email is configured in the environment and shown under Authentication.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notification service")
    }
}

private struct AdminTelegramSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var status: JSON?
    @State private var error: Error?
    @State private var token = ""
    @State private var saved = false
    @State private var confirmRemove = false

    var body: some View {
        Section {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } })
            } else if let s = status {
                LabeledContent("Bot token") {
                    if s["set"].bool == true {
                        if s["fromEnv"].bool == true { StatePill(text: "Configured from the environment", tone: .ok) }
                        else { StatePill(text: "Configured (token ending \(s["hint"].string ?? ""))", tone: .ok) }
                    } else {
                        StatePill(text: "Not configured")
                    }
                }
                // The environment wins where it is set, so there is nothing to edit here then.
                if s["fromEnv"].bool != true {
                    SecureField("New token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    HStack {
                        Button("Paste") { token = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? token }
                        Spacer()
                        Button(saved ? "Saved — webhook registered." : "Save") { save(token) }
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || action.busy)
                    }.buttonStyle(.borderless)
                    if s["set"].bool == true {
                        Button("Remove bot token", role: .destructive) { confirmRemove = true }
                    }
                }
            } else {
                ProgressView()
            }
        } header: { Text("Telegram") } footer: {
            Text("Paste a token from @BotFather; the webhook registers itself.")
        }
        .errorAlert(action)
        .confirmationDialog("Remove token?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove bot token", role: .destructive) { save("") }
        } message: {
            Text("Linked chats stop receiving notifications and shared groups stop answering until a token is added again.")
        }
        .task { await load() }
    }

    private func save(_ value: String) {
        action.run {
            guard let api = model.api else { return }
            _ = try await api.mutate("admin.notifications.setTelegram", .from(["botToken": value]))
            token = ""
            saved = !value.isEmpty
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { status = try await api.query("admin.notifications.telegram"); error = nil } catch { self.error = error }
    }
}

private struct AdminPushSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var cfg: JSON?
    @State private var error: Error?
    @State private var keyId = ""
    @State private var teamId = ""
    @State private var bundleId = ""
    @State private var key = ""
    @State private var saved = false
    /// Per device, what the last test push did — the only place a push failure shows.
    @State private var testResults: [JSON]?

    var body: some View {
        Section {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } })
            } else if let cfg {
                LabeledContent("State") {
                    if cfg["hasKey"].bool == true && !(cfg["keyId"].string ?? "").isEmpty {
                        Text("Configured (key \(cfg["keyId"].string ?? ""))").foregroundStyle(.green).font(.footnote.monospaced())
                    } else {
                        Text("Not configured").foregroundStyle(.secondary)
                    }
                }
                TextField("Key ID", text: $keyId).font(.body.monospaced()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Team ID", text: $teamId).font(.body.monospaced()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Bundle ID", text: $bundleId).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key (.p8)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $key).font(.caption2.monospaced()).frame(minHeight: 90)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(cfg["hasKey"].bool == true ? "A key is saved; leave empty to keep it." : "Paste the whole .p8 file.").font(.caption).foregroundStyle(.secondary)
                }
                Button(saved ? "Saved" : "Save") {
                    action.run {
                        guard let api = model.api else { return }
                        var input: [String: Any?] = ["keyId": keyId.trimmingCharacters(in: .whitespaces), "teamId": teamId.trimmingCharacters(in: .whitespaces), "bundleId": bundleId.trimmingCharacters(in: .whitespaces)]
                        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { input["key"] = key }
                        _ = try await api.mutate("admin.setPushConfig", .from(input))
                        key = ""
                        saved = true
                        await load()
                    }
                }.disabled(keyId.isEmpty || teamId.isEmpty || bundleId.isEmpty || action.busy)
                if cfg["hasKey"].bool == true {
                    Button("Send test push") {
                        action.run {
                            guard let api = model.api else { return }
                            testResults = try await api.mutate("admin.testPush")["results"].array
                        }
                    }.disabled(action.busy)
                }
                if let testResults {
                    if testResults.isEmpty {
                        Text("No paired device — pair this app under Settings → Your devices.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(testResults, id: \.self) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            let skipped = r["skipped"].bool == true
                            Label(r["device"].string ?? "", systemImage: r["ok"].bool == true ? "checkmark.circle.fill" : skipped ? "info.circle" : "xmark.circle.fill")
                                .foregroundStyle(r["ok"].bool == true ? .green : skipped ? .secondary : .red).font(.footnote.weight(.semibold))
                            Text(r["detail"].string ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        } header: { Text("Push (iOS app)") } footer: {
            Text("The APNs key from your Apple developer account, so the iOS app gets notifications.")
        }
        .errorAlert(action)
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let c = try await api.query("admin.pushConfig")
            if cfg == nil {
                keyId = c["keyId"].string ?? ""
                teamId = c["teamId"].string ?? ""
                bundleId = c["bundleId"].string ?? ""
            }
            cfg = c
            error = nil
        } catch { self.error = error }
    }
}
