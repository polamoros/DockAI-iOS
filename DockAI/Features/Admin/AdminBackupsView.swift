// tRPC: backups.destinations, backups.createDestination, backups.deleteDestination, backups.testDestination, backups.revealPassword, backups.runNow, backups.snapshots, backups.restore, backups.settings, backups.setSettings, backups.runs
import SwiftUI

/// Admin → Backups (pages/admin/BackupsSection.tsx): destinations (test,
/// back up now, check, snapshots and restore, the repository password,
/// remove), when it runs and what it keeps, and the recent runs.
struct AdminBackupsView: View {
    @State private var snapshotsFor: String?
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var destinations: [JSON]?
    @State private var error: Error?
    @State private var runs: [JSON] = []
    @State private var settings: JSON?
    @State private var adding = false
    @State private var tested: [String: JSON] = [:]
    @State private var password: (name: String, value: String)?
    @State private var confirmRemove: JSON?

    var body: some View {
        List {
            Section {
                if let error {
                    ErrorBanner(error: error, retry: { Task { await load() } })
                } else if let destinations {
                    if destinations.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No backups yet")
                            Text("Add a destination such as Google Drive and backups run every night.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(destinations, id: \.self) { d in destinationRow(d) }
                } else {
                    ProgressView()
                }
                Button { adding = true } label: { Label("Add destination", systemImage: "plus") }
            } header: { Text("Destinations") } footer: {
                Text("Encrypted copies of every project, conversation and setting, kept off this host.")
            }

            if let settings { AdminBackupSchedule(initial: settings) }

            if !runs.isEmpty {
                Section("Recent runs") {
                    ForEach(runs, id: \.self) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(runKind(r["kind"].string) + (r["target"].string.map { " · \($0)" } ?? ""))
                                Spacer()
                                runStatus(r["status"].string)
                            }
                            HStack(spacing: 4) {
                                Text(r["destination"]["name"].string ?? "")
                                Text("· \(AdminFormat.dateTime(r["startedAt"].date))")
                            }.font(.caption).foregroundStyle(.secondary)
                            if let e = r["error"].string, !e.isEmpty { Text(e).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Backups")
        .errorAlert(action)
        .sheet(isPresented: $adding) {
            AdminAddDestinationSheet { created in
                password = created
                Task { await load() }
            }
        }
        .alert(password.map { "Keep the password for “\($0.name)”" } ?? "", isPresented: Binding(get: { password != nil }, set: { if !$0 { password = nil } })) {
            Button("Copy") { UIPasteboard.general.string = password?.value }
            Button("Done", role: .cancel) {}
        } message: {
            Text("\(password?.value ?? "")\n\nYou need it to restore if this install is lost; keep it in your password manager.")
        }
        .confirmationDialog("Remove \(confirmRemove?["name"].string ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let d = confirmRemove else { return }
                action.run {
                    _ = try await api().mutate("backups.deleteDestination", .from(["id": d["id"].string]))
                    await load()
                }
            }
        } message: { Text("Its snapshots stay at the destination.") }
        .task {
            // Poll the runs: every 5s while one is running, else every minute.
            while !Task.isCancelled {
                await load()
                let busy = runs.contains { $0["status"].string == "running" }
                try? await Task.sleep(nanoseconds: (busy ? 5 : 60) * 1_000_000_000)
            }
        }
        .navigationDestination(item: $snapshotsFor) { AdminSnapshotsView(destinationId: $0) }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func destinationRow(_ d: JSON) -> some View {
        let id = d["id"].string ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Text(d["name"].string ?? "")
            Text("\(adminBackupKindName(d["kind"].string)) · \(d["path"].string ?? "")").font(.caption).foregroundStyle(.secondary)
            if let t = tested[id] {
                Text(t["detail"].string ?? "").font(.caption).foregroundStyle(t["ok"].bool == true ? .green : .red)
            }
            HStack(spacing: 16) {
                Button {
                    action.run { tested[id] = try await api().mutate("backups.testDestination", .from(["id": id])) }
                } label: { Label("Test", systemImage: "checkmark.circle") }
                // A button, not a NavigationLink: a link inside a list row
                // stretches the row and hides its own label (the simulator
                // walk showed a tall empty card, 2026-09-26).
                Button { snapshotsFor = id } label: { Label("Snapshots", systemImage: "clock.arrow.circlepath") }
                    .fixedSize()
                Menu {
                    Button { runNow(id, "backup") } label: { Label("Back up now", systemImage: "play") }
                    Button { runNow(id, "check") } label: { Label("Check repository", systemImage: "checkmark.shield") }
                    Button {
                        action.run {
                            let r = try await api().mutate("backups.revealPassword", .from(["id": id]))
                            password = (d["name"].string ?? "", r["resticPassword"].string ?? "")
                        }
                    } label: { Label("Show password", systemImage: "key") }
                    Button(role: .destructive) { confirmRemove = d } label: { Label("Remove", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }.buttonStyle(.borderless).font(.callout)
        }
    }

    private func runNow(_ id: String, _ kind: String) {
        action.run {
            _ = try await api().mutate("backups.runNow", .from(["id": id, "kind": kind]))
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { destinations = try await api.query("backups.destinations").array; error = nil }
        catch { self.error = error }
        if let r = try? await api.query("backups.runs") { runs = r.array }
        if settings == nil, let s = try? await api.query("backups.settings") { settings = s }
    }

    private func api() throws -> TRPCClient {
        guard let api = model.api else { throw TRPCError(code: "UNAUTHORIZED", message: "Not signed in.") }
        return api
    }

    private func runKind(_ k: String?) -> String {
        switch k { case "backup": "Backup"; case "check": "Check"; case "restore": "Restore"; default: k ?? "" }
    }

    @ViewBuilder
    private func runStatus(_ s: String?) -> some View {
        switch s {
        case "running": StatePill(text: "Running", tone: .accent)
        case "succeeded": StatePill(text: "Done", tone: .ok)
        case "failed": StatePill(text: "Failed", tone: .danger)
        default: StatePill(text: s ?? "—")
        }
    }
}

func adminBackupKindName(_ k: String?) -> String {
    switch k { case "drive": "Google Drive"; case "webdav": "Nextcloud"; case "s3": "S3"; case "sftp": "SFTP"; default: k ?? "" }
}

// MARK: - Add a destination

private struct AdminBackupField {
    let key: String
    let label: String
    var secret = false
    var multiline = false
    var optional = false
}

private let adminBackupFields: [String: [AdminBackupField]] = [
    "drive": [AdminBackupField(key: "token", label: "Token", secret: true, multiline: true)],
    "webdav": [AdminBackupField(key: "url", label: "WebDAV URL"), AdminBackupField(key: "user", label: "User"), AdminBackupField(key: "pass", label: "Password", secret: true)],
    "s3": [AdminBackupField(key: "endpoint", label: "Endpoint", optional: true), AdminBackupField(key: "region", label: "Region", optional: true),
           AdminBackupField(key: "accessKeyId", label: "Access key"), AdminBackupField(key: "secretAccessKey", label: "Secret key", secret: true)],
    "sftp": [AdminBackupField(key: "host", label: "Host"), AdminBackupField(key: "port", label: "Port", optional: true),
             AdminBackupField(key: "user", label: "User"), AdminBackupField(key: "pass", label: "Password", secret: true, optional: true)],
]

private struct AdminAddDestinationSheet: View {
    let onCreated: ((name: String, value: String)) -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var kind = "drive"
    @State private var path = "dockai-backups"
    @State private var config: [String: String] = [:]

    private var fields: [AdminBackupField] { adminBackupFields[kind] ?? [] }
    private var complete: Bool {
        !name.isEmpty && fields.allSatisfy { $0.optional || !(config[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Service", selection: $kind) {
                    ForEach(["drive", "webdav", "s3", "sftp"], id: \.self) { Text(adminBackupKindName($0)).tag($0) }
                }.pickerStyle(.segmented)
                Section {
                    ForEach(fields, id: \.key) { f in
                        let binding = Binding(get: { config[f.key] ?? "" }, set: { config[f.key] = $0 })
                        if f.multiline {
                            VStack(alignment: .leading) {
                                Text(f.label).font(.caption).foregroundStyle(.secondary)
                                TextEditor(text: binding).font(.caption.monospaced()).frame(minHeight: 90)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        } else if f.secret {
                            SecureField(f.label + (f.optional ? " (optional)" : ""), text: binding)
                        } else {
                            TextField(f.label + (f.optional ? " (optional)" : ""), text: binding)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                } footer: {
                    if kind == "drive" { Text("On a computer with a browser, run `rclone authorize \"drive\"`") }
                }
                Section {
                    TextField("Folder", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text("Where encrypted backups are stored.") }
            }
            .navigationTitle("Add destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let keys = Set(fields.map(\.key))
                        let cfg = config.filter { keys.contains($0.key) && !$0.value.isEmpty }
                        action.run {
                            guard let api = model.api else { return }
                            let r = try await api.mutate("backups.createDestination", .from(["name": name, "kind": kind, "path": path, "config": cfg as [String: Any?]]))
                            onCreated((r["name"].string ?? name, r["resticPassword"].string ?? ""))
                            dismiss()
                        }
                    }.disabled(!complete || action.busy)
                }
            }
            .errorAlert(action)
        }
    }
}

// MARK: - Schedule

private struct AdminBackupSchedule: View {
    let initial: JSON
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var hour = 4
    @State private var daily = 7
    @State private var weekly = 4
    @State private var monthly = 6
    @State private var saved = false
    @State private var loaded = false

    var body: some View {
        Section {
            Picker("Time", selection: $hour) {
                ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
            }
            Stepper("Keep \(daily) daily", value: $daily, in: 1...365)
            Stepper("Keep \(weekly) weekly", value: $weekly, in: 0...104)
            Stepper("Keep \(monthly) monthly", value: $monthly, in: 0...120)
            Button(saved ? "Saved" : "Save") {
                action.run {
                    guard let api = model.api else { return }
                    _ = try await api.mutate("backups.setSettings", .from(["hour": hour, "retention": ["daily": daily, "weekly": weekly, "monthly": monthly] as [String: Any?]]))
                    saved = true
                }
            }.disabled(action.busy)
        } header: { Text("When it runs") } footer: {
            Text("Every night at this hour, \(initial["timezone"].string ?? "UTC") time. Older snapshots are removed after each backup.")
        }
        .errorAlert(action)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            hour = initial["hour"].int ?? 4
            daily = initial["retention"]["daily"].int ?? daily
            weekly = initial["retention"]["weekly"].int ?? weekly
            monthly = initial["retention"]["monthly"].int ?? monthly
        }
        .onChange(of: [hour, daily, weekly, monthly]) { _, _ in saved = false }
    }
}

// MARK: - Snapshots and restore

private struct AdminSnapshotsView: View {
    let destinationId: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var restored = false

    var body: some View {
        Loader(load: {
            guard let api = model.api else { return .array([]) }
            return try await api.query("backups.snapshots", .from(["id": destinationId]))
        }) { value, _ in
            List {
                if restored {
                    Label("Restore started; the project's previous files are kept aside in its volumes.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                if value.array.isEmpty { Text("No snapshots yet").foregroundStyle(.secondary) }
                ForEach(value.array, id: \.self) { s in
                    let tags = s["tags"].array.compactMap(\.string)
                    let slug = tags.first { $0.hasPrefix("project:") }.map { String($0.dropFirst(8)) }
                    let title = tags.first { $0.range(of: "^(project|user|account|db):", options: .regularExpression) != nil } ?? s["id"].string ?? ""
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.body.monospaced())
                        HStack(spacing: 6) {
                            Text(s["id"].string ?? "").font(.caption.monospaced())
                            Text(AdminFormat.dateTime(s["time"].date)).font(.caption)
                        }.foregroundStyle(.secondary)
                        if let slug {
                            ConfirmButton(title: "Restore", confirmTitle: "Restore \(slug) to this snapshot?") {
                                action.run {
                                    guard let api = model.api else { return }
                                    _ = try await api.mutate("backups.restore", .from(["id": destinationId, "slug": slug, "snapshot": s["id"].string ?? "latest"]))
                                    restored = true
                                }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Snapshots")
        .errorAlert(action)
    }
}
