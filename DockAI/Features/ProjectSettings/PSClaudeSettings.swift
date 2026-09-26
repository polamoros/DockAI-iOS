// tRPC: project.update, project.getBySlug, project.switchAccount, claudeAccount.list, project.conversationsState, project.rcStart, project.rcStop, library.forProject, library.setOverride
import SwiftUI

/// Settings → Claude (ClaudeCliSettings.tsx), in the order people reach for
/// it: model and permission mode; Remote Control with its state and Restart
/// server; Guardrails; Advanced; the account with failover last; then the
/// library's skills, which apply at once and so sit outside the save.
struct PSClaudeSettings: View {
    let slug: String
    let onChange: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var box: PSProjectBox
    @StateObject private var action = Action()
    @StateObject private var switcher = Action()

    @State private var accounts: [JSON] = []
    @State private var accountsState: AccountsState = .loading
    enum AccountsState { case loading, loaded, failed }

    @State private var permissionMode = "default"
    @State private var modelId = ""
    @State private var accountId = ""
    @State private var fallbackIds: [String] = []
    @State private var failoverThreshold = "98"
    @State private var autoFailover = false
    @State private var autoRemote = true
    @State private var rcInteractive = true
    @State private var rcSpawn = "same-dir"
    @State private var capacity = 10
    @State private var remoteName = ""
    @State private var statusLine = ""
    @State private var keepAlive = false
    @State private var customFlags = ""
    @State private var toolsText = ""
    @State private var systemPrompt = ""
    @State private var maxTurns = ""
    @State private var maxBudget = ""
    @State private var saved = false
    @State private var loaded = false
    @State private var switchNote: String?

    init(slug: String, project: JSON, onChange: @escaping () -> Void) {
        self.slug = slug
        self.onChange = onChange
        _box = StateObject(wrappedValue: PSProjectBox(project))
    }

    private var p: JSON { box.project }

    static let permissionModes: [(String, String, String)] = [
        ("default", "Default", "prompt for each tool use"),
        ("acceptEdits", "Accept edits", "auto-approve file changes, ask for commands"),
        ("plan", "Plan", "require plan approval before execution"),
        ("auto", "Auto", "Claude decides when to ask (Team/Enterprise)"),
        ("dontAsk", "Don't ask", "approve all tools without prompting"),
        ("bypassPermissions", "Bypass", "skip all permission checks entirely"),
    ]
    static let models: [(String, String)] = [
        ("", "Account default"), ("fable", "Fable — newest and most capable"), ("opus", "Opus — deep reasoning"),
        ("sonnet", "Sonnet — fast and intelligent"), ("haiku", "Haiku — fastest, lightweight tasks"),
    ]

    // MARK: derived

    private var selectedAccount: JSON? { accounts.first { $0["id"].string == accountId } }
    private var accountCanRc: Bool { selectedAccount?["isValid"].bool == true }
    private var accountUsable: Bool { accountCanRc || selectedAccount?["hasSdkToken"].bool == true }
    private var rcConfigurable: Bool { autoRemote && accountCanRc }
    private var accountsUnavailable: Bool { accountsState != .loaded }

    private var tools: [String] { PSTools.lines(toolsText) }
    private var toolErrors: [String] { tools.compactMap(PSTools.validate) }

    private var storedTools: String { p["claudeTools"].string ?? "" }

    private var values: [String: JSON] {
        var v: [String: JSON] = [
            "claudePermissionMode": .string(permissionMode),
            "claudeModel": .string(modelId),
            "fallbackAccountIds": .array(fallbackIds.map(JSON.string)),
            "autoFailover": .bool(autoFailover),
            "failoverThreshold": .number(Double(Int(failoverThreshold) ?? 98)),
            "claudeAutoRemote": .bool(autoRemote),
            "claudeRcInteractive": .bool(rcInteractive),
            "claudeRcSpawn": .string(rcSpawn),
            "capacity": .number(Double(capacity)),
            "remoteName": remoteName.trimmingCharacters(in: .whitespaces).isEmpty ? .null : .string(remoteName.trimmingCharacters(in: .whitespaces)),
            "claudeStatusLine": statusLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .null : .string(statusLine),
            "claudeKeepAlive": .bool(keepAlive),
            "claudeCustomFlags": .string(customFlags),
            // Unchanged rules keep their stored spelling, so an untouched list is not a change.
            "claudeTools": .string(PSTools.split(storedTools) == tools ? storedTools : tools.joined(separator: ",")),
            "claudeSystemPrompt": .string(systemPrompt),
            "claudeMaxTurns": Int(maxTurns).map { JSON.number(Double($0)) } ?? .null,
            "claudeMaxBudget": Double(maxBudget).map { JSON.number($0) } ?? .null,
        ]
        // Never offered while the list is unknown: saving then would unlink the account.
        if !accountsUnavailable { v["claudeAccountId"] = accountId.isEmpty ? .null : .string(accountId) }
        return v
    }

    private var patch: [String: JSON] {
        PSPatch.changed(values, project: p, defaults: [
            "claudePermissionMode": .string("default"), "claudeModel": .string(""), "fallbackAccountIds": .array([]),
            "autoFailover": .bool(false), "failoverThreshold": .number(98), "claudeAutoRemote": .bool(true),
            "claudeRcInteractive": .bool(true), "claudeRcSpawn": .string("same-dir"), "capacity": .number(10),
            "claudeKeepAlive": .bool(false), "claudeCustomFlags": .string(""), "claudeTools": .string(""),
            "claudeSystemPrompt": .string(""),
        ])
    }

    // MARK: body

    var body: some View {
        Form {
            PSRestartOwedSection(project: p) { Task { await box.reload(model.api, slug: slug); onChange() } }

            Section("Conversation defaults") {
                Picker("Model", selection: $modelId) {
                    ForEach(modelOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker(selection: $permissionMode) {
                    ForEach(Self.permissionModes, id: \.0) { m in
                        Text("\(m.1) — \(m.2)").tag(m.0)
                    }
                } label: {
                    PSLabel(title: "Permission mode", detail: "How Claude requests permission for tools like file edits and commands.")
                }
                .pickerStyle(.navigationLink)
            }

            Section {
                Toggle(isOn: $autoRemote) {
                    PSLabel(title: "Remote Control", detail: "Makes this project reachable from the Claude app, and brings its conversations back after a restart.")
                }
                if autoRemote && !accountId.isEmpty && !accountCanRc && !accountsUnavailable {
                    Text("This account has only a long-lived token, which Anthropic limits to inference, so Remote Control will not start.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if rcConfigurable && p.psRunning { PSRemoteControlFacts(slug: slug) }
            }

            guardrails
            advanced
            accountSection
            failover

            PSSaveSection(
                consequence: PSRestart.consequence(changed: Set(patch.keys), running: p.psRunning, accountCanRc: accountCanRc, autoRemoteAfter: autoRemote),
                busy: action.busy, saved: saved,
                disabled: patch.isEmpty || accountsUnavailable || !toolErrors.isEmpty || !p.psCan("configure"),
                blockedReason: accountsUnavailable && accountsState == .failed
                    ? "Saving is off until the Claude account list loads — saving now would unlink the project’s account." : nil,
                save: save)

            if let id = p["id"].string {
                SvcLibraryOverrides(projectId: id, kind: "skill")
            }
        }
        .errorAlert(action)
        .errorAlert(switcher)
        .onAppear { if !loaded { fill(); loaded = true } }
        .task { await loadAccounts() }
    }

    private var modelOptions: [(String, String)] {
        var o = Self.models
        if !modelId.isEmpty && !o.contains(where: { $0.0 == modelId }) { o.append((modelId, "\(modelId) (currently set)")) }
        return o
    }

    // MARK: groups

    private var guardrails: some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allowed tools").font(.subheadline.weight(.medium))
                    TextEditor(text: $toolsText)
                        .font(.system(.footnote, design: .monospaced)).frame(minHeight: 70)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("One rule per line, such as Bash(git *) or mcp__server__*. Empty allows everything. Applies to every conversation, after a worker restart.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(toolErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    if !toolSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(toolSuggestions, id: \.self) { s in
                                    Button(s) { toolsText = (tools + [s]).joined(separator: "\n") }
                                        .font(.caption).buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                LabeledContent {
                    TextField("No limit", text: $maxTurns).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                } label: { PSLabel(title: "Max turns", detail: "Agentic turns per conversation.") }
                LabeledContent {
                    TextField("No limit", text: $maxBudget).keyboardType(.decimalPad).multilineTextAlignment(.trailing).ownerOnly(p)
                } label: { PSLabel(title: "Max budget ($)", detail: "API cost limit (USD)") }
                VStack(alignment: .leading, spacing: 4) {
                    Text("System prompt").font(.subheadline.weight(.medium))
                    TextEditor(text: $systemPrompt).frame(minHeight: 90)
                    Text("Appended to Claude's own system prompt.").font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                groupLabel("Guardrails", overridden: !tools.isEmpty || !maxTurns.isEmpty || !maxBudget.isEmpty || !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } footer: {
            Text("These apply to agent runs and the assistant API, not to the Claude app — except allowed tools.")
        }
    }

    private var toolSuggestions: [String] {
        let builtIn = ["Bash", "Edit", "Read", "Write", "Glob", "Grep", "WebFetch", "WebSearch", "Task", "TodoWrite", "NotebookEdit"]
        let mcp = p["mcpServers"].array.compactMap { $0["name"].string }.map { "mcp__\($0)__*" }
        return (builtIn + mcp).filter { !tools.contains($0) }
    }

    private var advanced: some View {
        let overridden = !customFlags.trimmingCharacters(in: .whitespaces).isEmpty || !statusLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keepAlive
            || (rcConfigurable && (!remoteName.isEmpty || capacity != 10 || rcSpawn != "same-dir" || !rcInteractive))
        return Section {
            DisclosureGroup {
                if rcConfigurable {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name in the Claude app").font(.subheadline.weight(.medium))
                        TextField("DockAI-\(p["slug"].string ?? slug)", text: $remoteName)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: remoteName) { _, v in
                                let clean = String(String(v.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" ? $0 : "-" }).prefix(63))
                                if clean != v { remoteName = clean }
                            }
                        Text("A DNS label; empty uses the default shown, and it applies on the next restart.").font(.caption).foregroundStyle(.secondary)
                    }
                    Stepper(value: $capacity, in: 1...32) {
                        PSLabel(title: "Concurrent conversations: \(capacity)", detail: "The Claude app cannot start a new one while they are all in use.")
                    }
                    Picker(selection: $rcSpawn) {
                        Text("Shared workspace").tag("same-dir")
                        Text("One worktree each").tag("worktree")
                    } label: {
                        PSLabel(title: "Workspace isolation", detail: "How two conversations share the files; worktrees need a git repository.")
                    }
                    Toggle(isOn: $rcInteractive) {
                        PSLabel(title: "Convert app conversations", detail: "A conversation started in the Claude app moves itself to the terminal on its first turn.")
                    }
                }
                Toggle(isOn: $keepAlive) {
                    PSLabel(title: "Keep session alive", detail: "Sends a tiny message so the five-hour usage window does not lapse; it spends usage.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status line (override)").font(.subheadline.weight(.medium))
                    TextEditor(text: $statusLine).font(.system(.footnote, design: .monospaced)).frame(minHeight: 100)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("A shell script that prints one line; empty inherits from Claude defaults. It gets the conversation as JSON on stdin.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom flags").font(.subheadline.weight(.medium))
                    TextField("e.g. --verbose --worktree", text: $customFlags).font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Raw flags passed to the claude command; a bad flag stops the Remote Control server from starting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: { groupLabel("Advanced", overridden: overridden) }
        }
    }

    private var accountSection: some View {
        Section {
            switch accountsState {
            case .loading:
                LabeledContent("Claude account") { ProgressView() }
            case .failed:
                LabeledContent("Claude account") { Text(p["claudeAccount"]["label"].string ?? "Unknown").foregroundStyle(.secondary) }
                Text("The account list could not be loaded, so this cannot be changed right now.").font(.caption).foregroundStyle(.orange)
                Button("Retry") { Task { await loadAccounts() } }
            case .loaded:
                Picker("Claude account", selection: $accountId) {
                    Text("No account").tag("")
                    ForEach(accounts, id: \.self) { a in
                        Text(accountLabel(a)).tag(a["id"].string ?? "")
                    }
                }
                .onChange(of: accountId) { _, v in switchIfRunning(v) }
                .ownerOnly(p)
                PSOwnerOnlyNote(project: p)
                if switcher.busy { Text("Switching account…").font(.caption) }
                else if let switchNote { Text(switchNote).font(.caption) }
                else if p.psRunning { Text("Switching while running takes a moment; the worker stays up.").font(.caption).foregroundStyle(.secondary) }
                if accountId.isEmpty && !p.psRunning {
                    Text("No account selected. Claude won't be available in this project.").font(.caption).foregroundStyle(.orange)
                }
                if !accountId.isEmpty && !accountUsable {
                    Text("This account needs to be logged in before Claude can be used.").font(.caption).foregroundStyle(.orange)
                }
                if !accountId.isEmpty && accountUsable && !accountCanRc {
                    Text("A long-lived token runs Claude and agents, but not Remote Control.").font(.caption).foregroundStyle(.secondary)
                }
                if !accountId.isEmpty, let cur = p["claudeAccountId"].string, cur != accountId, !p.psRunning {
                    Text("Switching accounts changes which conversations are visible; the old ones come back if you switch back.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func accountLabel(_ a: JSON) -> String {
        let label = a["label"].string ?? "Account"
        if a["isValid"].bool == true { return label }
        return a["hasSdkToken"].bool == true ? "\(label) (token auth)" : "\(label) (not signed in)"
    }

    private var failover: some View {
        Section {
            DisclosureGroup {
                let others = accounts.filter { $0["id"].string != accountId }
                if accounts.count < 2 {
                    Text("Failover needs a second Claude account. Add one under Settings → Claude accounts.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(others, id: \.self) { a in
                        let id = a["id"].string ?? ""
                        let order = fallbackIds.firstIndex(of: id)
                        Toggle(isOn: Binding(
                            get: { order != nil },
                            set: { on in if on { fallbackIds.append(id) } else { fallbackIds.removeAll { $0 == id } } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(a["label"].string ?? "Account")
                                    if let order { StatePill(text: "Tried \(order + 1) of \(fallbackIds.count)") }
                                }
                                if a["isValid"].bool != true { Text("Needs sign-in").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
                if !fallbackIds.isEmpty {
                    Toggle(isOn: $autoFailover) {
                        PSLabel(title: "Switch automatically", detail: "Off by default: the list is used only when you switch by hand.")
                    }
                    if autoFailover {
                        LabeledContent {
                            HStack {
                                TextField("98", text: $failoverThreshold).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 60)
                                Text("%")
                            }
                        } label: {
                            PSLabel(title: "Switch at", detail: "Percent of the weekly window (50–100). Skipped while the agent is working, and at most once every 30 minutes.")
                        }
                    }
                    Text("Conversations are kept; an empty list turns failover off.").font(.caption).foregroundStyle(.secondary)
                }
            } label: { groupLabel("Usage failover", overridden: !fallbackIds.isEmpty) }
        } footer: {
            Text("Moves the project to the next account with headroom when this one runs out.")
        }
        .ownerOnly(p)
    }

    private func groupLabel(_ title: String, overridden: Bool) -> some View {
        HStack {
            Text(title)
            if overridden { StatePill(text: "Set here", tone: .accent) }
        }
    }

    // MARK: actions

    /// While running, a new account applies at once: every configured account
    /// is already mounted, so this repoints a symlink rather than rebuilding.
    private func switchIfRunning(_ v: String) {
        guard loaded, p.psRunning, !v.isEmpty, v != p["claudeAccountId"].string else { return }
        switchNote = nil
        let canRc = accounts.first { $0["id"].string == v }?["isValid"].bool == true
        switcher.run {
            _ = try await model.api?.mutate("project.switchAccount", .from(["slug": slug, "accountId": v]))
            await box.reload(model.api, slug: slug)
            switchNote = canRc ? "Switched. Remote Control restarted on the new account."
                : "Switched. Remote Control stays off — this account has no interactive login."
            onChange()
        }
    }

    private func loadAccounts() async {
        guard let api = model.api else { return }
        do {
            accounts = try await api.query("claudeAccount.list").array
            accountsState = .loaded
        } catch { accountsState = .failed }
    }

    private func fill() {
        permissionMode = p["claudePermissionMode"].string ?? "default"
        modelId = p["claudeModel"].string ?? ""
        accountId = p["claudeAccountId"].string ?? ""
        fallbackIds = p["fallbackAccountIds"].array.compactMap(\.string)
        failoverThreshold = String(p["failoverThreshold"].int ?? 98)
        autoFailover = p["autoFailover"].bool ?? false
        autoRemote = p["claudeAutoRemote"].bool ?? true
        rcInteractive = p["claudeRcInteractive"].bool ?? true
        rcSpawn = p["claudeRcSpawn"].string ?? "same-dir"
        capacity = p["capacity"].int ?? 10
        remoteName = p["remoteName"].string ?? ""
        statusLine = p["claudeStatusLine"].string ?? ""
        keepAlive = p["claudeKeepAlive"].bool ?? false
        customFlags = p["claudeCustomFlags"].string ?? ""
        toolsText = PSTools.split(p["claudeTools"].string ?? "").joined(separator: "\n")
        systemPrompt = p["claudeSystemPrompt"].string ?? ""
        maxTurns = p["claudeMaxTurns"].int.map(String.init) ?? ""
        maxBudget = p["claudeMaxBudget"].double.map { String($0) } ?? ""
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

/// Allowed-tools rules: the server stores them comma-joined, and a comma inside
/// a scope (`Bash(git a,b)`) is not a separator — the web's `splitTools`.
enum PSTools {
    static func split(_ raw: String) -> [String] {
        var out: [String] = []
        var buf = ""
        var depth = 0
        for ch in raw {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if ch == "," && depth == 0 {
                let t = buf.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                buf = ""
            } else { buf.append(ch) }
        }
        let t = buf.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }

    /// One per line in the editor (a pasted comma list still splits).
    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").flatMap { split(String($0)) }
    }

    /// The CLI rejects a bare "*"; globs are legal only inside a scope or after mcp__<server>__.
    static func validate(_ entry: String) -> String? {
        if entry == "*" { return "A bare \"*\" is not accepted — name the tool, e.g. Bash(*) or mcp__server__*" }
        if entry.contains("*"),
           entry.range(of: #"^mcp__[^_]+__"#, options: .regularExpression) == nil,
           entry.range(of: #"\(.*\)"#, options: .regularExpression) == nil {
            return "\(entry): globs are only allowed inside a scope, e.g. Bash(git *), or after mcp__server__"
        }
        return nil
    }
}

/// The Remote Control server as it is now — state, isolation, what its last
/// start brought back, why it is down — with Restart server (stop, then start,
/// which also re-runs the reconnect pass).
struct PSRemoteControlFacts: View {
    let slug: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var rc: JSON = .null
    @State private var error: Error?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Server").font(.subheadline.weight(.medium))
                if loading { ProgressView() } else { statePill }
                Spacer()
                Button {
                    action.run {
                        _ = try await model.api?.mutate("project.rcStop", .from(["slug": slug]))
                        _ = try await model.api?.mutate("project.rcStart", .from(["slug": slug]))
                        await load()
                    }
                } label: {
                    if action.busy { ProgressView() } else { Label("Restart server", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(action.busy || rc["blockedReason"].string != nil)
            }
            if let reason = rc["blockedReason"].string {
                Text(reason == "tokenOnly"
                     ? "This account has only a long-lived token, which Anthropic limits to inference, so Remote Control will not start."
                     : "Link a Claude account under General, and Remote Control can start.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if rc["running"].bool == true {
                if let spawn = rc["spawn"].string {
                    LabeledContent("Isolation", value: spawn == "worktree" ? "One worktree each" : "Shared workspace").font(.caption)
                }
                if let n = rc["reconnected"].int, n > 0 {
                    LabeledContent("Last start", value: "\(n) conversation\(n == 1 ? "" : "s") reconnected").font(.caption)
                }
            }
            if let error {
                ErrorBanner(error: error) { Task { await load() } }
            } else if rc["running"].bool != true, let last = rc["lastError"].string {
                Text(last).font(.system(.caption2, design: .monospaced)).foregroundStyle(.orange)
            }
        }
        .errorAlert(action)
        .task { await load() }
    }

    @ViewBuilder private var statePill: some View {
        if error != nil { StatePill(text: "Unknown", tone: .danger) }
        else if rc["running"].bool == true { StatePill(text: "Running", tone: .ok) }
        else if rc["blockedReason"].string == nil && rc["supervised"].bool == true { StatePill(text: "Retrying", tone: .warn) }
        else if rc["blockedReason"].string != nil { StatePill(text: "Unavailable") }
        else { StatePill(text: "Stopped") }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            rc = try await api.query("project.conversationsState", .from(["slug": slug, "sessions": false]))["rc"]
            error = nil
        } catch { self.error = error }
        loading = false
    }
}
