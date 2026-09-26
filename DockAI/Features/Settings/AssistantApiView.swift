// tRPC: assistantApi.getConfig, assistantApi.setProtocol, assistantApi.setProject
import SwiftUI

/// Settings → Assistant API: the OpenAI- and Ollama-compatible surfaces
/// (server-wide, admin-only switches) and which of your projects they expose,
/// each with its system prompt, turn cap and allowed tools.
struct AssistantApiView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var config: JSON?
    @State private var error: Error?

    var body: some View {
        List {
            if let error { ErrorBanner(error: error, retry: { Task { await load() } }) }
            if let config {
                Section {
                    Label("Anyone holding one of your API tokens can then prompt that project remotely.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                protocols(config)
                projects(config)
                usage(config)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Assistant API")
        .disabled(action.busy)
        .errorAlert(action)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func protocols(_ config: JSON) -> some View {
        let canManage = config["canManageProtocols"].bool == true
        Section {
            ForEach(AssistantProtocol.all) { p in
                let proto = p.id
                let title = p.title
                let detail = p.detail
                let key = p.key
                let enabled = config[key].bool == true
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { enabled }, set: { on in
                        run("assistantApi.setProtocol", ["protocol": proto, "enabled": on])
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!canManage)
                    if enabled, let base = config["baseUrls"][proto].string {
                        CopyRow(text: base)
                    }
                }
            }
        } header: {
            Text("Protocols")
        } footer: {
            if !canManage { Text("Only an admin can turn protocols on or off — they open a network surface for the whole server.") }
        }
    }

    @ViewBuilder private func projects(_ config: JSON) -> some View {
        Section {
            if config["projects"].array.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No projects yet")
                    Text("Expose a project from its own settings, under Claude.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(config["projects"].array, id: \.self) { p in
                NavigationLink {
                    AssistantProjectView(project: p) { Task { await load() } }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p["name"].string ?? "")
                            Text(p["slug"].string ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p["hasAccount"].bool == false { StatePill(text: "No Claude account", tone: .danger) }
                        if p["assistantApiEnabled"].bool == true { StatePill(text: "Exposed", tone: .ok) }
                    }
                }
            }
        } header: {
            Text("Exposed projects")
        } footer: {
            Text("An exposed project appears to clients as a model named by its slug.")
        }
    }

    @ViewBuilder private func usage(_ config: JSON) -> some View {
        let anyOn = config["openaiEnabled"].bool == true || config["ollamaEnabled"].bool == true
        if anyOn, let first = config["projects"].array.first(where: { $0["assistantApiEnabled"].bool == true }),
           let slug = first["slug"].string, let base = config["baseUrls"]["openai"].string {
            Section {
                Text("""
                curl \(base)/chat/completions \\
                  -H "Authorization: Bearer dka_your_token" \\
                  -H "Content-Type: application/json" \\
                  -d '{"model":"\(slug)","messages":[{"role":"user","content":"Hello"}]}'
                """)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
            } header: {
                Text("Try it")
            } footer: {
                Text("Create an API token under API tokens, then run this.")
            }
        }
    }

    private func run(_ path: String, _ input: [String: Any?]) {
        action.run {
            guard let api = model.api else { return }
            _ = try await api.mutate(path, .from(input))
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { config = try await api.query("assistantApi.getConfig"); error = nil } catch { self.error = error }
    }
}

/// The two wire formats, as the web describes them.
struct AssistantProtocol: Identifiable {
    let id: String
    let title: String
    let detail: String
    let key: String
    static let all = [
        AssistantProtocol(id: "openai", title: "OpenAI-compatible", detail: "For LiteLLM, scripts and curl; Home Assistant's own OpenAI integration cannot be pointed here.", key: "openaiEnabled"),
        AssistantProtocol(id: "ollama", title: "Ollama-compatible", detail: "For Home Assistant's built-in Ollama integration, which asks for a server URL.", key: "ollamaEnabled"),
    ]
}

/// One project's assistant settings. Each field saves when you leave it, as on the web.
struct AssistantProjectView: View {
    let project: JSON
    let onChange: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var enabled = false
    @State private var systemPrompt = ""
    @State private var maxTurns = 8
    @State private var allowedTools = ""
    @State private var loaded = false
    @FocusState private var focus: Field?
    private enum Field { case prompt, tools }

    private var id: String { project["id"].string ?? "" }

    var body: some View {
        Form {
            Section {
                Toggle("Expose \(project["name"].string ?? "")", isOn: Binding(get: { enabled }, set: { on in
                    enabled = on
                    save(["enabled": on])
                }))
                if project["hasAccount"].bool == false {
                    Text("No Claude account linked — requests to this project will fail.").font(.caption).foregroundStyle(.red)
                }
            }
            Section("System prompt") {
                TextField("You are a home assistant. Answer briefly and plainly.", text: $systemPrompt, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focus, equals: .prompt)
            }
            Section {
                Stepper("Max turns: \(maxTurns)", value: Binding(get: { maxTurns }, set: { v in
                    maxTurns = v
                    save(["maxTurns": v])
                }), in: 1...50)
            }
            Section {
                TextField("Read, Bash, WebFetch", text: $allowedTools)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .tools)
            } header: {
                Text("Allowed tools")
            } footer: {
                Text("Comma-separated, blank for the default. Runs with this project's permission mode (\(project["claudePermissionMode"].string ?? "default")), set under its Claude settings.")
            }
        }
        .navigationTitle(project["name"].string ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert(action)
        .onAppear {
            guard !loaded else { return }
            enabled = project["assistantApiEnabled"].bool == true
            systemPrompt = project["assistantApiSystemPrompt"].string ?? ""
            maxTurns = project["assistantApiMaxTurns"].int ?? 8
            allowedTools = project["assistantApiAllowedTools"].string ?? ""
            loaded = true
        }
        .onChange(of: focus) { old, _ in
            if old == .prompt, systemPrompt != (project["assistantApiSystemPrompt"].string ?? "") { save(["systemPrompt": systemPrompt]) }
            if old == .tools, allowedTools != (project["assistantApiAllowedTools"].string ?? "") { save(["allowedTools": allowedTools]) }
        }
        .onDisappear {
            var pending: [String: Any?] = [:]
            if systemPrompt != (project["assistantApiSystemPrompt"].string ?? "") { pending["systemPrompt"] = systemPrompt }
            if allowedTools != (project["assistantApiAllowedTools"].string ?? "") { pending["allowedTools"] = allowedTools }
            if !pending.isEmpty { save(pending) }
        }
    }

    private func save(_ fields: [String: Any?]) {
        var input = fields
        input["projectId"] = id
        action.run {
            guard let api = model.api else { return }
            _ = try await api.mutate("assistantApi.setProject", .from(input))
            onChange()
        }
    }
}
