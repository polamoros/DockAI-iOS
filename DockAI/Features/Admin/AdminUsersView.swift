// tRPC: admin.users.list, admin.users.create, admin.users.update, admin.users.setRole, admin.users.setPassword, admin.users.ban, admin.users.unban, admin.users.delete, admin.loginLinks.create
import SwiftUI

/// Admin → Users (pages/admin/UsersSection.tsx + UserModals.tsx): search,
/// create, and per user edit, set password, one-time login link, role, ban
/// and delete. The web uses `admin.users.*` (which carries `banned`), not the
/// older top-level `users.list/delete`, so this does too.
struct AdminUsersView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var users: [JSON]?
    @State private var error: Error?
    @State private var creating = false

    var body: some View {
        List {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } })
            } else if let users {
                if users.isEmpty {
                    Text(search.isEmpty ? "No users found." : "No users match your search.").foregroundStyle(.secondary)
                }
                ForEach(users, id: \.self) { u in
                    NavigationLink {
                        AdminUserDetailView(user: u, isSelf: u["id"].string == model.me["id"].string, onChange: { Task { await load() } })
                    } label: { AdminUserRow(user: u) }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Users")
        .searchable(text: $search, prompt: "Search by name or email…")
        .task(id: search) {
            // Typed search: wait a moment so every keystroke is not a request.
            if !search.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
            await load()
        }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Label("Create user", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $creating) {
            AdminCreateUserSheet(onDone: { Task { await load() } })
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let input: JSON = search.isEmpty ? .null : .from(["search": search])
            users = try await api.query("admin.users.list", input).array
            error = nil
        } catch { self.error = error }
    }
}

private struct AdminUserRow: View {
    let user: JSON
    var body: some View {
        HStack(spacing: 10) {
            Text(String((user["name"].string ?? "?").trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.caption.monospaced().weight(.medium))
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user["name"].string ?? "").lineLimit(1)
                    StatePill(text: user["role"].string == "ADMIN" ? "Admin" : "Member", tone: user["role"].string == "ADMIN" ? .accent : .neutral)
                    if user["banned"].bool == true { StatePill(text: "Banned", tone: .danger) }
                }
                HStack(spacing: 4) {
                    Text(user["email"].string ?? "").lineLimit(1)
                    Text("· \(user["_count"]["projects"].int ?? 0) projects")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One user's actions, each where the web's kebab put it.
struct AdminUserDetailView: View {
    let user: JSON
    let isSelf: Bool
    let onChange: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var passwordDone = false
    @State private var banReason = ""
    @State private var role = "MEMBER"
    @State private var banned = false
    @State private var linkMinutes = 15
    @State private var link: String?
    @State private var saved = false

    private var id: String { user["id"].string ?? "" }

    var body: some View {
        Form {
            Section {
                LabeledContent("Joined", value: AdminFormat.dateTime(user["createdAt"].date))
                LabeledContent("Projects", value: "\(user["_count"]["projects"].int ?? 0)")
            }

            Section("Edit user") {
                TextField("Name", text: $name)
                TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(saved ? "Saved" : "Save") {
                    action.run {
                        _ = try await api().mutate("admin.users.update", .from(["userId": id, "name": name, "email": email]))
                        saved = true
                        onChange()
                    }
                }.disabled(name.isEmpty || email.isEmpty || action.busy)
            }

            Section {
                SecureField("New password", text: $password)
                Button(passwordDone ? "Password updated." : "Update password") {
                    action.run {
                        _ = try await api().mutate("admin.users.setPassword", .from(["userId": id, "newPassword": password]))
                        password = ""
                        passwordDone = true
                    }
                }.disabled(password.count < 8 || action.busy)
            } header: { Text("Set password") } footer: { Text("Minimum 8 characters") }

            Section {
                Picker("Valid for", selection: $linkMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                if let link {
                    Text(link).font(.caption.monospaced()).textSelection(.enabled)
                    AdminCopyButton(text: link)
                    ShareLink(item: link)
                } else {
                    Button("Create link") {
                        action.run {
                            let r = try await api().mutate("admin.loginLinks.create", .from(["userId": id, "minutes": linkMinutes]))
                            if let path = r["path"].string, let c = model.credentials {
                                // The path, joined to the origin this app talks to — the server does not guess its own.
                                link = c.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
                            }
                        }
                    }
                }
            } header: { Text("One-time login link") } footer: {
                Text(link == nil ? "A single-use way in for \(user["name"].string ?? "this user"), from a device their passkey is not on." : "Copy it now — it is shown once and cannot be read back.")
            }

            Section("Role") {
                if isSelf {
                    Text("Cannot change your own role").foregroundStyle(.secondary)
                } else {
                    Button(role == "ADMIN" ? "Demote to member" : "Promote to admin") {
                        let next = role == "ADMIN" ? "MEMBER" : "ADMIN"
                        action.run {
                            _ = try await api().mutate("admin.users.setRole", .from(["userId": id, "role": next]))
                            role = next
                            onChange()
                        }
                    }
                }
            }

            Section {
                if isSelf {
                    Text("Cannot ban yourself").foregroundStyle(.secondary)
                } else if banned {
                    if let r = user["banReason"].string, !r.isEmpty { LabeledContent("Reason", value: r) }
                    Button("Unban") {
                        action.run {
                            _ = try await api().mutate("admin.users.unban", .from(["userId": id]))
                            banned = false
                            onChange()
                        }
                    }
                } else {
                    TextField("Reason (optional)", text: $banReason)
                    ConfirmButton(title: "Ban", confirmTitle: "Ban \(user["name"].string ?? "")?") {
                        action.run {
                            var input: [String: Any?] = ["userId": id]
                            if !banReason.isEmpty { input["reason"] = banReason }
                            _ = try await api().mutate("admin.users.ban", .from(input))
                            banned = true
                            onChange()
                        }
                    }
                }
            } header: { Text("Ban user") } footer: {
                if !isSelf && !banned { Text("They will not be able to sign in; their sessions end and API tokens are revoked.") }
            }

            Section {
                if isSelf {
                    Text("Cannot delete yourself").foregroundStyle(.secondary)
                } else {
                    ConfirmButton(title: "Delete user", confirmTitle: "Delete permanently") {
                        action.run {
                            _ = try await api().mutate("admin.users.delete", .from(["userId": id]))
                            onChange()
                            dismiss()
                        }
                    }
                }
            } footer: {
                if !isSelf {
                    let n = user["_count"]["projects"].int ?? 0
                    Text("Permanently delete \(user["name"].string ?? "this user"), their projects and their workers. This cannot be undone." + (n > 0 ? " \(n) project\(n == 1 ? "" : "s") will be permanently deleted." : ""))
                }
            }
        }
        .navigationTitle(user["name"].string ?? "User")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert(action)
        .onAppear {
            name = user["name"].string ?? ""
            email = user["email"].string ?? ""
            role = user["role"].string ?? "MEMBER"
            banned = user["banned"].bool ?? false
        }
    }

    private func api() throws -> TRPCClient {
        guard let api = model.api else { throw TRPCError(code: "UNAUTHORIZED", message: "Not signed in.") }
        return api
    }
}

private struct AdminCreateUserSheet: View {
    let onDone: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var role = "MEMBER"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Section {
                    SecureField("Password", text: $password)
                } footer: { Text("Minimum 8 characters") }
                Picker("Role", selection: $role) {
                    Text("Member").tag("MEMBER")
                    Text("Admin").tag("ADMIN")
                }
            }
            .navigationTitle("Create user")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action.busy ? "Creating…" : "Create") {
                        action.run {
                            guard let api = model.api else { return }
                            _ = try await api.mutate("admin.users.create", .from(["name": name, "email": email, "password": password, "role": role]))
                            onDone()
                            dismiss()
                        }
                    }.disabled(name.isEmpty || !email.contains("@") || password.count < 8 || action.busy)
                }
            }
            .errorAlert(action)
        }
    }
}
