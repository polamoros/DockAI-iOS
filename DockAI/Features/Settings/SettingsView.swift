// tRPC: users.me (via model.refreshMe), device.revoke (via model.signOut)
import SwiftUI
import LocalAuthentication

/// Settings: every user section the web has, in the web's three groups, plus
/// what only the app has — the Face ID lock and signing this phone out.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    // Same key as AppModel's; read here so the switch redraws when it changes.
    @AppStorage("faceIDLock") private var faceIDLock = false
    @State private var confirmSignOut = false
    @State private var lockError: String?

    var body: some View {
        List {
            Section("You") {
                NavigationLink { ProfileSettingsView() } label: { Label("Profile", systemImage: "person") }
                NavigationLink { SecuritySettingsView() } label: { Label("Security", systemImage: "lock") }
                NavigationLink { NotificationsSettingsView() } label: { Label("Notifications", systemImage: "bell") }
                NavigationLink { DevicesSettingsView() } label: { Label("Your devices", systemImage: "iphone") }
            }
            Section("Claude") {
                NavigationLink { ClaudeAccountsView() } label: { Label("Claude accounts", systemImage: "checkmark.shield") }
                NavigationLink { ClaudeDefaultsView() } label: { Label("Claude defaults", systemImage: "terminal") }
                NavigationLink { LibraryView() } label: { Label("Skills & MCP", systemImage: "books.vertical") }
            }
            Section("Connections") {
                NavigationLink { GitHubSettingsView() } label: { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                NavigationLink { SshKeysView() } label: { Label("SSH keys", systemImage: "key") }
                NavigationLink { ApiTokensView() } label: { Label("API tokens", systemImage: "key.horizontal") }
                NavigationLink { AssistantApiView() } label: { Label("Assistant API", systemImage: "cpu") }
            }
            Section {
                NavigationLink { AboutView() } label: { Label("About", systemImage: "info.circle") }
            }
            Section {
                Toggle(isOn: Binding(get: { faceIDLock }, set: { setLock($0) })) {
                    Label("Face ID lock", systemImage: "faceid")
                }
                Button(role: .destructive) { confirmSignOut = true } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } header: {
                Text("This iPhone")
            } footer: {
                // Appearance and language on the web are a theme and a locale
                // switch; the app follows the system for both, so there is
                // nothing to set here.
                Text("The app follows the system's appearance and language. Signing out revokes this iPhone's token; pair again from the web to come back.")
            }
            if let lockError {
                Text(lockError).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of DockAI on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await model.signOut() } }
        }
    }

    /// Turning the lock on proves Face ID (or the passcode) works first, so it
    /// cannot lock the app behind something the phone cannot answer.
    private func setLock(_ on: Bool) {
        lockError = nil
        guard on else { faceIDLock = false; return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            lockError = err?.localizedDescription ?? "This iPhone has no Face ID or passcode set up."
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Lock DockAI with Face ID") { ok, error in
            Task { @MainActor in
                if ok { faceIDLock = true } else { lockError = error?.localizedDescription }
            }
        }
    }
}

/// Profile: three read-only facts, as on the web.
struct ProfileSettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            LabeledContent("Name", value: model.me["name"].string ?? "—")
            LabeledContent("Email") { Text(model.me["email"].string ?? "—").textSelection(.enabled) }
            // Only when the server says: `users.me` may not carry the role, and
            // "Member" printed for an admin would be a wrong fact.
            if let role = model.me["role"].string {
                LabeledContent("Role", value: role == "ADMIN" ? "Admin" : "Member")
            }
        }
        .navigationTitle("Profile")
        .task { await model.refreshMe() }
        .refreshable { await model.refreshMe() }
    }
}

/// Security: passkeys, two-factor and the password are better-auth's, and its
/// endpoints take a browser session — not a device token — so they are
/// managed on the web.
struct SecuritySettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    var body: some View {
        List {
            Section {
                Label("Passkeys", systemImage: "person.badge.key")
                Label("Two-factor authentication", systemImage: "lock.shield")
                Label("Password", systemImage: "ellipsis.rectangle")
            } footer: {
                Text("Registering and removing passkeys, two-factor and the password need a signed-in browser, so they are managed on the web. This iPhone signs in with its own device token, which you can revoke in Your devices.")
            }
            Section {
                Button {
                    if let url = webURL(model, "settings/security") { openURL(url) }
                } label: { Label("Open Security on the web", systemImage: "safari") }
            }
        }
        .navigationTitle("Security")
    }
}
