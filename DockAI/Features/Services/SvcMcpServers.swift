// tRPC: mcp.presets, mcp.list, mcp.add, mcp.update, mcp.remove
import SwiftUI

/// MCP servers (McpServers.tsx): the project's own connectors — presets, a
/// custom command, or a remote endpoint with a token. Header values are never
/// read back: a row shows which header keys are set, and an update that omits
/// `headers` keeps the stored ones.
struct SvcMcpServers: View {
    let projectId: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var servers: [JSON]?
    @State private var listError: Error?
    @State private var presets: [JSON] = []
    @State private var presetsError: Error?
    @State private var pushFailed = false
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case custom, remote(name: String, label: String, url: String), edit(JSON)
        var id: String {
            switch self {
            case .custom: "custom"
            case .remote(let n, _, _): "remote-\(n)"
            case .edit(let s): "edit-\(s["id"].string ?? "")"
            }
        }
    }

    private var configured: Set<String> { Set((servers ?? []).compactMap { $0["name"].string }) }

    var body: some View {
        Section {
            if pushFailed {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Saved, but this worker did not get it — restart the project to apply it.").font(.callout)
                    Spacer()
                    Button("Close") { pushFailed = false }.buttonStyle(.borderless).font(.callout)
                }
            }
            if let presetsError {
                VStack(alignment: .leading) {
                    Text("Could not load the presets").font(.callout.weight(.medium))
                    ErrorBanner(error: presetsError) { Task { await loadPresets() } }
                }
            }
            if let listError { ErrorBanner(error: listError) { Task { await load() } } }
            else if let servers {
                if servers.isEmpty {
                    VStack(alignment: .leading) {
                        Text("No MCP servers")
                        Text("Add a preset or a custom one.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(servers, id: \.self) { s in row(s) }
            } else { ProgressView() }

            Menu {
                Section("Presets") {
                    ForEach(presets, id: \.self) { p in
                        let name = p["name"].string ?? ""
                        Button {
                            addPreset(p)
                        } label: {
                            if configured.contains(name) {
                                Text("\(p["label"].string ?? name) — Already added")
                            } else {
                                Text(p["label"].string ?? name)
                            }
                        }
                        .disabled(configured.contains(name))
                    }
                }
                Button { sheet = .custom } label: { Label("Custom server…", systemImage: "plus") }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(action.busy)
        } header: {
            Text("MCP servers")
        } footer: {
            Text("Connectors a conversation in this project can use — a command in the worker, or a remote endpoint.")
        }
        .errorAlert(action)
        .task { await load(); await loadPresets() }
        .sheet(item: $sheet) { s in
            SvcMcpForm(sheet: s, projectId: projectId) { result in
                sheet = nil
                if let result { pushFailed = !result["pushFailed"].isNull }
                Task { await load() }
            }
        }
    }

    private func describe(_ s: JSON) -> String {
        let transport = s["transport"].string ?? "stdio"
        if transport == "stdio" {
            return ([s["command"].string ?? ""] + s["args"].array.compactMap(\.string)).joined(separator: " ")
        }
        let keys = s["headerKeys"].array.compactMap(\.string)
        return "\(transport) · \(s["url"].string ?? "")" + (keys.isEmpty ? "" : " · authenticated (\(keys.joined(separator: ", ")))")
    }

    private func row(_ s: JSON) -> some View {
        let enabled = s["enabled"].bool ?? true
        let id = s["id"].string ?? ""
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(s["name"].string ?? "").lineLimit(1)
                    if !enabled { StatePill(text: "Disabled") }
                }
                Text(describe(s)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button {
                action.run {
                    let r = try await model.api?.mutate("mcp.update", .from(["id": id, "enabled": !enabled])) ?? .null
                    pushFailed = !r["pushFailed"].isNull
                    await load()
                }
            } label: {
                Image(systemName: enabled ? "power.circle.fill" : "power.circle").foregroundStyle(enabled ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(enabled ? "Disable server" : "Enable server")
            .disabled(action.busy)
        }
        .contentShape(Rectangle())
        .onTapGesture { sheet = .edit(s) }
        .swipeActions {
            Button("Remove", role: .destructive) {
                action.run {
                    let r = try await model.api?.mutate("mcp.remove", .from(["id": id])) ?? .null
                    pushFailed = !r["pushFailed"].isNull
                    await load()
                }
            }
        }
    }

    private func addPreset(_ p: JSON) {
        let t = p["transport"].string ?? "stdio"
        if t == "sse" || t == "http" {
            sheet = .remote(name: p["name"].string ?? "", label: p["label"].string ?? "", url: p["urlPlaceholder"].string ?? "")
            return
        }
        action.run {
            let r = try await model.api?.mutate("mcp.add", .object([
                "projectId": .string(projectId), "name": p["name"], "transport": .string("stdio"),
                "command": p["command"], "args": .array(p["args"].array), "envVars": .object(p["envVars"].object),
                "headers": .object([:]), "enabled": .bool(true),
            ])) ?? .null
            pushFailed = !r["pushFailed"].isNull
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { servers = try await api.query("mcp.list", .from(["projectId": projectId])).array; listError = nil } catch { listError = error }
    }

    private func loadPresets() async {
        guard let api = model.api else { return }
        do { presets = try await api.query("mcp.presets").array; presetsError = nil } catch { presetsError = error }
    }
}

/// Add (custom command or remote endpoint) or edit one server. The token field
/// is plain text on purpose: on iOS a secure field routes through the password
/// manager and pasting a long token becomes fiddly. It is never shown again.
private struct SvcMcpForm: View {
    let sheet: SvcMcpServers.Sheet
    let projectId: String
    let done: (JSON?) -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var transport = "stdio"
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    @State private var url = ""
    @State private var token = ""
    @State private var keptKeys: [String] = []
    @State private var keptEnvKeys: [String] = []
    @State private var filled = false

    private var editing: JSON? { if case .edit(let s) = sheet { return s }; return nil }
    private var title: String {
        switch sheet {
        case .custom: "Custom server"
        case .remote(_, let label, _): label
        case .edit(let s): s["name"].string ?? "Server"
        }
    }
    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return transport == "stdio" ? !command.trimmingCharacters(in: .whitespaces).isEmpty : URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(isRemotePreset)
                    if !isRemotePreset {
                        Picker("Transport", selection: $transport) {
                            Text("Command").tag("stdio")
                            Text("SSE").tag("sse")
                            Text("HTTP").tag("http")
                        }
                    }
                }
                if transport == "stdio" {
                    Section {
                        TextField("Command (e.g. npx)", text: $command).font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Arguments (space-separated)", text: $args).font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section {
                        TextEditor(text: $env).font(.system(.footnote, design: .monospaced)).frame(minHeight: 60)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Variables") } footer: {
                        Text(keptEnvKeys.isEmpty ? "One per line, as NAME=value."
                             : "One per line, as NAME=value. Set: \(keptEnvKeys.joined(separator: ", ")); leave empty to keep them.")
                    }
                } else {
                    Section {
                        TextField("https://home-assistant.example.com/mcp_server/sse", text: $url)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField(keptKeys.isEmpty ? "Long-lived access token" : "Leave empty to keep the stored token", text: $token)
                            .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if !keptKeys.isEmpty { Text("Set: \(keptKeys.joined(separator: ", ")); leave empty to keep them.") }
                            Text("Sent as Authorization: Bearer <token>. Home Assistant → your profile → Security → Long-lived access tokens.")
                        }
                    }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { submit() }.disabled(!valid || action.busy)
                }
            }
            .errorAlert(action)
            .onAppear { if !filled { fill(); filled = true } }
        }
    }

    private var isRemotePreset: Bool { if case .remote = sheet { return true }; return false }

    private func fill() {
        switch sheet {
        case .custom: break
        case .remote(let n, _, let u): name = n; transport = "sse"; url = u
        case .edit(let s):
            name = s["name"].string ?? ""
            transport = s["transport"].string ?? "stdio"
            command = s["command"].string ?? ""
            args = s["args"].array.compactMap(\.string).joined(separator: " ")
            // Values are never sent back (redaction.ts); only which keys are set.
            keptEnvKeys = s["envVarKeys"].array.compactMap(\.string)
            url = s["url"].string ?? ""
            keptKeys = s["headerKeys"].array.compactMap(\.string)
        }
    }

    private var envVars: [String: JSON] {
        var out: [String: JSON] = [:]
        for line in env.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = .string(String(line[line.index(after: eq)...])) }
        }
        return out
    }

    private func submit() {
        let t = token.trimmingCharacters(in: .whitespaces)
        let stdio = transport == "stdio"
        var input: [String: JSON] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "transport": .string(transport),
            "command": .string(stdio ? command.trimmingCharacters(in: .whitespaces) : ""),
            "args": .array(stdio ? PSPatch.lines(args).map(JSON.string) : []),
        ]
        // On an edit, empty keeps the stored variables; on an add it is simply none.
        if editing == nil || !envVars.isEmpty || !stdio { input["envVars"] = .object(stdio ? envVars : [:]) }
        if !stdio { input["url"] = .string(url.trimmingCharacters(in: .whitespaces)) }
        let procedure: String
        if let id = editing?["id"].string {
            procedure = "mcp.update"
            input["id"] = .string(id)
            // Omitting headers keeps the stored ones; only a new token replaces them.
            if !stdio && !t.isEmpty { input["headers"] = .object(["Authorization": .string("Bearer \(t)")]) }
        } else {
            procedure = "mcp.add"
            input["projectId"] = .string(projectId)
            input["enabled"] = .bool(true)
            input["headers"] = .object(!stdio && !t.isEmpty ? ["Authorization": .string("Bearer \(t)")] : [:])
        }
        let payload = JSON.object(input)
        action.run {
            let r = try await model.api?.mutate(procedure, payload) ?? .null
            done(r)
        }
    }
}
