// tRPC: agentRun.createSchedule, agentRun.updateSchedule, project.claudeSessions
import SwiftUI

/// One of an automation's own buttons under its Telegram result.
struct AgentAutomationButton: Identifiable, Hashable {
    let id = UUID()
    var label = ""
    var action = "command" // "command" | "agent"
    var command = ""
    var prompt = ""

    var isComplete: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && !(action == "command" ? command : prompt).trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Create or edit an automation — the web's page-form, with the same groups in
/// the same order: Name; When it runs; What it does; Notifications.
struct AgentAutomationForm: View {
    let projectId: String
    let slug: String
    let target: AgentAutomationTarget
    let onDone: () -> Void

    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()

    @State private var name = ""
    @State private var kind = "recurring" // once | recurring | event
    @State private var runAt = Date().addingTimeInterval(3600)
    @State private var cron = "0 3 * * *"
    @State private var trigger = ""
    @State private var timezone = TimeZone.current.identifier
    @State private var doesAction = "agent" // agent | command
    @State private var prompt = ""
    @State private var sessionId = ""
    @State private var command = ""
    @State private var notify = "never" // never | always | failure
    @State private var buttons: [AgentAutomationButton] = []

    @State private var conversations: [JSON] = []
    @State private var conversationsError: Error?
    @State private var conversationsLoading = false
    @State private var populated = false

    /// How often an on-event automation runs its check.
    private struct CronPreset: Hashable { let label: String; let cron: String }
    private static let checkPresets: [CronPreset] = [
        CronPreset(label: "Every 5 minutes", cron: "*/5 * * * *"),
        CronPreset(label: "Every 10 minutes", cron: "*/10 * * * *"),
        CronPreset(label: "Every hour", cron: "0 * * * *"),
    ]
    private static let presets: [CronPreset] = [
        CronPreset(label: "Every hour", cron: "0 * * * *"),
        CronPreset(label: "Every day at 03:00", cron: "0 3 * * *"),
        CronPreset(label: "Weekdays at 09:00", cron: "0 9 * * 1-5"),
        CronPreset(label: "Every Monday at 08:00", cron: "0 8 * * 1"),
    ]
    private static let zones: [String] = ["UTC"] + TimeZone.knownTimeZoneIdentifiers.filter { $0 != "UTC" }

    private var editingId: String? {
        if case .edit(let row) = target { return row["id"].string }
        return nil
    }

    private var title: String {
        if case .edit(let row) = target { return row["name"].string ?? "Edit automation" }
        return "New automation"
    }

    var body: some View {
        Form {
            Section {
                TextField("e.g. Nightly dependency check", text: $name)
            } header: { Text("Name") }

            Section {
                Picker("When it runs", selection: $kind) {
                    Text("One time").tag("once")
                    Text("Recurring").tag("recurring")
                    Text("On event").tag("event")
                }
                .pickerStyle(.segmented)

                if kind == "once" {
                    // Shown as wall-clock time in the chosen zone; sent as an
                    // absolute instant, which the server accepts as ISO.
                    DatePicker("Date and time", selection: $runAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, TimeZone(identifier: timezone) ?? .current)
                    hint("Runs once at this time, then turns itself off.")
                }
                if kind == "event" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check command").font(.subheadline)
                        TextField("e.g. npm view @anthropic-ai/claude-code version", text: $trigger, axis: .vertical)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        hint("Runs before any AI; the agent runs only when its output changes.")
                    }
                }
                if kind != "once" {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind == "event" ? "Check every" : "Cron").font(.subheadline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(kind == "event" ? Self.checkPresets : Self.presets, id: \.self) { preset in
                                    presetButton(preset.label, preset.cron)
                                }
                            }
                        }
                        TextField("0 3 * * *", text: $cron)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        hint(kind == "event" ? "How often the check command runs, as a cron." : "Five fields: minute, hour, day of month, month, day of week.")
                    }
                }
                Picker("Time zone", selection: $timezone) {
                    ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.navigationLink)
            } header: { Text("When it runs") }

            Section {
                Picker("What it does", selection: $doesAction) {
                    Text("Run the agent").tag("agent")
                    Text("Run a command").tag("command")
                }
                .pickerStyle(.segmented)

                if doesAction == "agent" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prompt").font(.subheadline)
                        TextField("What should the agent do?", text: $prompt, axis: .vertical)
                            .lineLimit(4...12)
                    }
                    Picker("Where it runs", selection: $sessionId) {
                        Text("A fresh conversation each run").tag("")
                        ForEach(conversations, id: \.self) { s in
                            Text(conversationLabel(s)).tag(s["id"].string ?? "")
                        }
                        // An automation pinned to a conversation that is no
                        // longer listed still shows what it is pinned to.
                        if !sessionId.isEmpty, !conversations.contains(where: { $0["id"].string == sessionId }) {
                            Text(String(sessionId.prefix(8))).tag(sessionId)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    hint("A fresh conversation, or an existing one.")
                    // A list that failed to load leaves a picker with one
                    // option, which reads as "no conversations" rather than
                    // "we could not ask".
                    if let conversationsError {
                        ErrorBanner(error: conversationsError, retry: { Task { await loadConversations() } })
                    } else if conversationsLoading {
                        ProgressView()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command").font(.subheadline)
                        TextField("e.g. ./scripts/backup.sh", text: $command, axis: .vertical)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        hint("Runs in the worker with no model; its output and exit code are kept.")
                    }
                }
            } header: { Text("What it does") }

            Section {
                Picker("Notifications", selection: $notify) {
                    Text("Never").tag("never")
                    Text("Always").tag("always")
                    Text("On failure").tag("failure")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Notifications")
            } footer: {
                Text("The result, sent to your Telegram.")
            }

            if notify != "never" {
                Section {
                    ForEach($buttons) { $b in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Button label", text: Binding(get: { $b.wrappedValue.label }, set: { $b.wrappedValue.label = String($0.prefix(30)) }))
                                Button(role: .destructive) {
                                    buttons.removeAll { $0.id == b.id }
                                } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove button")
                            }
                            Picker("What it does", selection: $b.action) {
                                Text("Run a command").tag("command")
                                Text("Run the agent").tag("agent")
                            }
                            .pickerStyle(.segmented)
                            if b.action == "command" {
                                TextField("e.g. ./scripts/backup.sh", text: $b.command)
                                    .font(.callout.monospaced())
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            } else {
                                TextField("What the agent should do", text: $b.prompt, axis: .vertical)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if buttons.count < 3 {
                        Button { buttons.append(AgentAutomationButton()) } label: { Label("Add button", systemImage: "plus") }
                    }
                } header: {
                    Text("Buttons")
                } footer: {
                    Text("Run again and Pause are always offered; add up to three of your own.")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if action.busy {
                    ProgressView()
                } else {
                    Button(editingId == nil ? "Create" : "Save") { submit() }.disabled(!valid)
                }
            }
        }
        .errorAlert(action)
        .onAppear { populate() }
        .task { await loadConversations() }
    }

    // MARK: - Pieces

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func presetButton(_ label: String, _ value: String) -> some View {
        Button(label) { cron = value }
            .font(.caption)
            .buttonStyle(.bordered)
            .tint(cron == value ? Color.accentColor : Color.secondary)
    }

    private func conversationLabel(_ s: JSON) -> String {
        let id = s["id"].string ?? ""
        let base = [s["title"].string, s["firstPrompt"].string].compactMap { $0 }.first { !$0.isEmpty } ?? String(id.prefix(8))
        return s["active"].bool == true ? "\(base) · live" : base
    }

    // MARK: - State

    private var valid: Bool {
        let t = { (s: String) in !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard t(name) else { return false }
        if kind != "once", !t(cron) { return false }
        if kind == "event", !t(trigger) { return false }
        if doesAction == "agent", !t(prompt) { return false }
        if doesAction == "command", !t(command) { return false }
        if notify != "never", buttons.contains(where: { !$0.isComplete }) { return false }
        return true
    }

    /// Editing fills the same form the create page uses.
    private func populate() {
        guard !populated else { return }
        populated = true
        guard case .edit(let row) = target else { return }
        name = row["name"].string ?? ""
        prompt = row["prompt"].string ?? ""
        cron = (row["cron"].string ?? "").isEmpty ? "0 3 * * *" : row["cron"].string!
        trigger = row["trigger"].string ?? ""
        sessionId = row["sessionId"].string ?? ""
        let tz = (row["timezone"].string ?? "").isEmpty ? "UTC" : row["timezone"].string!
        timezone = tz
        kind = row["kind"].string ?? (trigger.isEmpty ? "recurring" : "event")
        if let d = row["runAt"].date { runAt = d }
        doesAction = row["action"].string == "command" ? "command" : "agent"
        command = row["command"].string ?? ""
        let n = row["notify"].string
        notify = n == "always" || n == "failure" ? n! : "never"
        buttons = row["buttons"].array.map { b in
            AgentAutomationButton(
                label: b["label"].string ?? "",
                action: b["action"].string == "agent" ? "agent" : "command",
                command: b["command"].string ?? "",
                prompt: b["prompt"].string ?? ""
            )
        }
    }

    private func loadConversations() async {
        guard let api = model.api else { return }
        conversationsLoading = true
        defer { conversationsLoading = false }
        do {
            conversations = try await api.query("project.claudeSessions", .from(["slug": slug]))["sessions"].array
            conversationsError = nil
        } catch {
            conversationsError = error
        }
    }

    private func submit() {
        guard let api = model.api else { return }
        // Only the chosen kind's fields go: a trigger left in the box from an
        // earlier choice would otherwise turn a recurring automation into an
        // on-event one.
        var input: [String: Any?] = [
            "name": name,
            "sessionId": sessionId.isEmpty ? nil : sessionId,
            "action": doesAction,
            "prompt": prompt,
            "command": command,
            "notify": notify,
            // Buttons only mean something when a result is sent.
            "buttons": notify == "never" ? [Any?]() : buttons.map { b -> Any? in
                ["label": b.label, "action": b.action, "command": b.command, "prompt": b.prompt] as [String: Any?]
            },
            "kind": kind,
            "timezone": timezone,
        ]
        if kind == "once" {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            input["runAt"] = f.string(from: runAt)
            input["cron"] = ""
            input["trigger"] = ""
        } else {
            input["cron"] = cron
            input["trigger"] = kind == "event" ? trigger : ""
        }
        let id = editingId
        if let id { input["id"] = id } else { input["projectId"] = projectId }
        action.run {
            _ = try await api.mutate(id == nil ? "agentRun.createSchedule" : "agentRun.updateSchedule", .from(input))
            onDone()
        }
    }
}
