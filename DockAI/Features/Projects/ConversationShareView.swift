// tRPC: telegram.status, telegram.shares, telegram.createShareCode, telegram.setShareSession, telegram.unshare, project.update
import SwiftUI

/// Share a conversation to a Telegram group, for people with no DockAI
/// account: what groups may use here, the groups already connected (with the
/// conversation each joins), and a new invite.
struct ConversationShareView: View {
    let project: JSON
    let slug: String
    let preset: ConversationShareTarget?
    let conversations: [JSON]
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var status: JSON?
    @State private var statusError: Error?
    @State private var shares: [JSON] = []
    @State private var sessionId = ""
    @State private var mode = "parallel"
    @State private var language = "en"
    @State private var prompt = ""
    @State private var code: String?
    @StateObject private var action = Action()

    private static let languages = [ShareOption(id: "en", label: "English"), ShareOption(id: "es", label: "Español"), ShareOption(id: "ca", label: "Català")]
    private var projectId: String { project["id"].string ?? "" }
    private var mine: [JSON] { shares.filter { $0["pinnedProjectId"].string == projectId } }
    private var options: [ShareOption] {
        conversations.map { s in ShareOption(id: s["id"].string ?? "", label: ConversationFacts(s: s).title) }
    }

    var body: some View {
        Form {
            if let statusError {
                Section { ErrorBanner(error: statusError) { Task { await load() } } }
            } else if let status, status["configured"].bool != true {
                Section { Text(model.isAdmin ? "This install has no Telegram bot yet. Set one up in Admin → Notifications." : "This install has no Telegram bot yet.") }
            } else if status == nil {
                Section { ProgressView() }
            } else {
                TelegramAccessSection(project: project)
                if !mine.isEmpty { connectedSection }
                if let code { inviteSection(code) } else { formSection }
            }
        }
        .navigationTitle("Share to Telegram")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            if let preset { sessionId = preset.id }
            await load()
        }
        .errorAlert(action)
    }

    private var connectedSection: some View {
        Section("Connected groups") {
            ForEach(mine, id: \.self) { s in
                VStack(alignment: .leading, spacing: 6) {
                    Text(s["title"].string ?? s["username"].string.map { "Linked by @\($0)" } ?? "A group").font(.subheadline.weight(.medium))
                    Text(describe(s)).font(.caption).foregroundStyle(.secondary)
                    Picker("Conversation", selection: Binding(
                        get: { s["pinnedSessionId"].string ?? "" },
                        set: { v in repoint(s, to: v) })) {
                        if s["mode"].string != "parallel" { Text("A new conversation").tag("") }
                        if let pinned = s["pinnedSessionId"].string, !options.contains(where: { $0.id == pinned }) {
                            Text(String(pinned.prefix(8))).tag(pinned)
                        }
                        ForEach(options) { o in Text(o.label).tag(o.id) }
                    }
                    ConfirmButton(title: "Revoke", confirmTitle: "Revoke access") {
                        guard let id = s["id"].string, let api = model.api else { return }
                        action.run {
                            _ = try await api.mutate("telegram.unshare", .from(["id": id]))
                            await load()
                        }
                    }.font(.footnote).buttonStyle(.borderless)
                }
            }
        }
    }

    private var formSection: some View {
        Section {
            Picker("Conversation", selection: $sessionId) {
                Text("A new conversation").tag("")
                ForEach(options) { o in Text(o.label).tag(o.id) }
            }
            Picker("Mode", selection: $mode) {
                Text("Shared").tag("parallel")
                Text("Its own").tag("isolated")
            }.pickerStyle(.segmented)
            Picker("Language", selection: $language) {
                ForEach(Self.languages) { l in Text(l.label).tag(l.id) }
            }
            if mode == "isolated" {
                TextField("Instructions for the group's conversation (optional)", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
            }
            Button {
                create()
            } label: {
                if action.busy { ProgressView() } else { Label("Create invite", systemImage: "paperplane") }
            }
            .disabled(action.busy || project["claudeAccountId"].isNull || (mode == "parallel" && sessionId.isEmpty))
        } header: {
            Text(mine.isEmpty ? "New invite" : "Another group")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == "parallel" ? "The group and you share this conversation, live." : "A separate conversation, limited by Group permissions.")
                if mode == "parallel" && sessionId.isEmpty { Text("A shared group joins a running conversation, so pick one.") }
                if project["claudeAccountId"].isNull { Text("Link a Claude account to this project first.").foregroundStyle(.orange) }
                Text("What the bot says there, and answers in, follows the language.")
            }
        }
    }

    private func inviteSection(_ code: String) -> some View {
        Section {
            Text("Telegram asks which group to add the bot to; create the group first.").font(.footnote)
            if let bot = status?["username"].string, let url = URL(string: "https://t.me/\(bot)?startgroup=\(code)") {
                Button { openURL(url) } label: { Label("Open Telegram", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Or by hand: add \(status?["username"].string.map { "@\($0)" } ?? "the bot") to the group, then send:").font(.caption).foregroundStyle(.secondary)
                ProjCommandLine(command: "/start \(code)")
            }
            Button("Done with this invite") { self.code = nil; Task { await load() } }
        } header: { Text("Invite ready") }
    }

    private func describe(_ s: JSON) -> String {
        let pinned = s["pinnedSessionId"].string
        let title = options.first(where: { $0.id == pinned })?.label ?? pinned.map { String($0.prefix(8)) }
        let lang = Self.languages.first(where: { $0.id == s["language"].string })?.label ?? (s["language"].string ?? "")
        return s["mode"].string == "parallel"
            ? "Joins “\(title ?? "—")” — the same conversation as yours · \(lang)"
            : "Its own conversation, from “\(title ?? "a new conversation")” · \(lang)"
    }

    private func repoint(_ share: JSON, to v: String) {
        guard let id = share["id"].string, let api = model.api else { return }
        action.run {
            _ = try await api.mutate("telegram.setShareSession", .from(["id": id, "sessionId": v.isEmpty ? nil : v]))
            await load()
        }
    }

    private func create() {
        guard let api = model.api else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let input: [String: Any?] = [
            "projectId": projectId,
            "sessionId": sessionId.isEmpty ? nil : sessionId,
            "mode": mode,
            "systemPrompt": mode == "isolated" && !trimmed.isEmpty ? trimmed : nil,
            "language": language,
        ]
        action.run {
            let r = try await api.mutate("telegram.createShareCode", .from(input))
            code = r["code"].string
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            status = try await api.query("telegram.status")
            statusError = nil
            shares = (try? await api.query("telegram.shares"))?.array ?? shares
        } catch { statusError = error }
    }
}

/// What groups may use in this project — one switch for "same as yours",
/// and the grants one by one under it. Per project: a policy over what
/// leaves this workspace.
private struct TelegramAccessSection: View {
    let project: JSON
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var full: Bool?
    @State private var grants: Set<String>?

    private static let all: [ShareOption] = [
        ShareOption(id: "edit", label: "Change files", detail: "Write and edit files in the workspace."),
        ShareOption(id: "shell", label: "Run commands", detail: "A shell: git, installs, deploys — the same reach your conversations have."),
        ShareOption(id: "web", label: "Web", detail: "Fetch pages and search the web."),
        ShareOption(id: "skills", label: "Skills and subagents", detail: "Run this project's skills and delegate to subagents."),
        ShareOption(id: "artifacts", label: "Artifacts", detail: "Publish pages under your account, and list and read every artifact you own."),
        ShareOption(id: "connectors", label: "Connectors", detail: "This project's MCP servers, and DockAI's own notify and ask tools."),
    ]

    private var isFull: Bool { full ?? (project["telegramAccess"].string == "full") }
    private var current: Set<String> { grants ?? Set(project["telegramGrants"].array.compactMap(\.string)) }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { isFull }, set: { v in save(["telegramAccess": v ? "full" : "custom"]) { full = v } })) {
                VStack(alignment: .leading) {
                    Text("Same as yours")
                    Text("Everything your own conversations can do here: shell, web, connectors, artifacts.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !isFull {
                ForEach(Self.all) { g in
                    Toggle(isOn: Binding(get: { current.contains(g.id) }, set: { on in toggle(g.id, on) })) {
                        VStack(alignment: .leading) {
                            Text(g.label)
                            Text(g.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            HStack { Text("Group permissions"); if action.busy { ProgressView().controlSize(.mini) } }
        } footer: {
            Text("For groups with a conversation of their own; a group joining yours has its tools.")
        }
        .disabled(action.busy)
        .errorAlert(action)
    }

    private func toggle(_ grant: String, _ on: Bool) {
        var next = current
        if on { next.insert(grant) } else { next.remove(grant) }
        let ordered = Self.all.map(\.id).filter { next.contains($0) }
        save(["telegramGrants": JSON.array(ordered.map { JSON.string($0) })]) { grants = next }
    }

    private func save(_ fields: [String: Any?], then apply: @escaping () -> Void) {
        guard let id = project["id"].string, let api = model.api else { return }
        var input = fields
        input["id"] = id
        action.run {
            _ = try await api.mutate("project.update", .from(input))
            apply()
        }
    }
}

/// A choice in a picker: its value, its label, and an optional line under it.
private struct ShareOption: Identifiable, Hashable {
    let id: String
    let label: String
    var detail = ""
}
