// tRPC: users.getDockaiTools, users.updateDockaiTools, users.getClaudeStatusLine, users.updateClaudeStatusLine
import SwiftUI

/// Settings → Claude defaults: DockAI's own tools in every conversation, and
/// the default status line. Both are pushed to running projects on save; a
/// project can override the status line in its own Claude settings.
struct ClaudeDefaultsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var tools: JSON?
    @State private var toolsError: Error?
    @State private var statusLoaded = false
    @State private var statusError: Error?
    @State private var script = ""
    @State private var dockaiInfo = true
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                if let toolsError {
                    ErrorBanner(error: toolsError, retry: { Task { await load() } })
                } else if let tools {
                    Toggle(isOn: Binding(get: { tools["notify"].bool ?? true }, set: { setTools(notify: $0, client: tools["client"].bool ?? true) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Telegram tools")
                            Text("Sends you results and images, and asks questions with tappable answers."
                                 + (tools["telegramLinked"].bool == false ? " Link a chat in Settings → Notifications first." : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(get: { tools["client"].bool ?? true }, set: { setTools(notify: tools["notify"].bool ?? true, client: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Computer tools")
                            Text("Only while your computer is attached; commands need --allow-run.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("DockAI tools")
            } footer: {
                Text("An MCP server DockAI adds to every conversation in your projects.")
            }

            Section {
                if let statusError {
                    ErrorBanner(error: statusError, retry: { Task { await load() } })
                } else if statusLoaded {
                    TextEditor(text: $script)
                        .font(.caption.monospaced())
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle(isOn: $dockaiInfo) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DockAI status line")
                            Text("Adds a line with memory, weekly usage, pending restarts and Remote Control.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { save() } label: {
                        HStack { Text("Save"); if action.busy { ProgressView() } }
                    }
                    if saved { Text("Saved — pushed to your running projects.").font(.caption).foregroundStyle(.green) }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Status line")
            } footer: {
                Text("A shell script that prints one line. It gets the session as JSON on stdin; jq, git, awk and curl are in the worker. Empty uses Claude's default.")
            }
        }
        .navigationTitle("Claude defaults")
        .errorAlert(action)
        .task { await load() }
    }

    /// The switch moves at once; the refetch puts the truth back either way.
    private func setTools(notify: Bool, client: Bool) {
        tools = .from(["notify": notify, "client": client, "telegramLinked": tools?["telegramLinked"] ?? .null] as [String: Any?])
        action.run {
            guard let api = model.api else { return }
            defer { Task { await loadTools() } }
            _ = try await api.mutate("users.updateDockaiTools", .from(["notify": notify, "client": client]))
        }
    }

    private func save() {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : script
        action.run {
            guard let api = model.api else { return }
            _ = try await api.mutate("users.updateClaudeStatusLine", .from(["script": value, "dockaiInfo": dockaiInfo] as [String: Any?]))
            saved = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saved = false
        }
    }

    private func loadTools() async {
        guard let api = model.api else { return }
        do { tools = try await api.query("users.getDockaiTools"); toolsError = nil } catch { toolsError = error }
    }

    private func load() async {
        await loadTools()
        guard let api = model.api else { return }
        do {
            let r = try await api.query("users.getClaudeStatusLine")
            script = r["script"].string ?? ""
            dockaiInfo = r["dockaiInfo"].bool ?? true
            statusLoaded = true
            statusError = nil
        } catch { statusError = error }
    }
}
