// tRPC: library.skills.list, library.skills.create, library.skills.update, library.skills.delete, library.mcp.list, library.mcp.create, library.mcp.update, library.mcp.delete
import SwiftUI

/// Settings → Skills & MCP: the user's library. Each item is kept once and is
/// on for all of this person's projects or not; a project can say otherwise
/// in its own Claude settings. Creating and editing are pages of their own.
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var skills: JSON?
    @State private var mcp: JSON?
    @State private var error: Error?
    @State private var notUpdated: [String] = []

    var body: some View {
        List {
            if let error { ErrorBanner(error: error, retry: { Task { await load() } }) }
            if !notUpdated.isEmpty { NotUpdatedNote(slugs: notUpdated) }
            Section {
                if let skills {
                    if skills.array.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No skills yet")
                            Text("Paste a SKILL.md to keep it here for your projects.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(skills.array, id: \.self) { s in
                        itemRow(kind: "skills", item: s, meta: s["description"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "No description") {
                            SkillEditorView(existing: s) { r in done(r) }
                        }
                    }
                } else if error == nil { ProgressView() }
                NavigationLink { SkillEditorView(existing: nil) { r in done(r) } } label: { Label("New skill", systemImage: "plus") }
            } header: { Text("Skills") }

            Section {
                if let mcp {
                    if mcp.array.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No MCP servers yet")
                            Text("Add a server once and switch it on wherever you need it.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(mcp.array, id: \.self) { m in
                        let meta = m["transport"].string == "stdio" || m["transport"].isNull
                            ? ([m["command"].string ?? ""] + m["args"].array.compactMap(\.string)).joined(separator: " ")
                            : (m["url"].string ?? "")
                        itemRow(kind: "mcp", item: m, meta: meta) {
                            McpEditorView(existing: m) { r in done(r) }
                        }
                    }
                } else if error == nil { ProgressView() }
                NavigationLink { McpEditorView(existing: nil) { r in done(r) } } label: { Label("New MCP server", systemImage: "plus") }
            } header: { Text("MCP servers") }
        }
        .navigationTitle("Skills & MCP")
        .errorAlert(action)
        .task { await load() }
        .refreshable { await load() }
    }

    /// A row: the name, a line of detail, the all-projects switch, edit by
    /// tapping, delete by swiping.
    private func itemRow<Dest: View>(kind: String, item: JSON, meta: String, @ViewBuilder editor: @escaping () -> Dest) -> some View {
        let id = item["id"].string ?? ""
        let name = item["name"].string ?? ""
        return HStack {
            NavigationLink {
                editor()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.monospaced())
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Toggle("\(name) in all my projects", isOn: Binding(
                get: { item["defaultOn"].bool == true },
                set: { on in mutate("library.\(kind).update", ["id": id, "defaultOn": on]) }
            ))
            .labelsHidden()
            .fixedSize()
        }
        .swipeActions {
            Button("Delete", role: .destructive) { mutate("library.\(kind).delete", ["id": id]) }
        }
    }

    private func done(_ result: JSON?) {
        if let result { notUpdated = result["notUpdated"].array.compactMap(\.string) }
        Task { await load() }
    }

    private func mutate(_ path: String, _ input: [String: Any?]) {
        action.run {
            guard let api = model.api else { return }
            let r = try await api.mutate(path, .from(input))
            notUpdated = r["notUpdated"].array.compactMap(\.string)
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            async let s = api.query("library.skills.list")
            async let m = api.query("library.mcp.list")
            skills = try await s
            mcp = try await m
            error = nil
        } catch { self.error = error }
    }
}

/// A skill, new or edited. Pasting a whole SKILL.md into the body fills the
/// name and description from its frontmatter, as the web does.
struct SkillEditorView: View {
    let existing: JSON?
    let onDone: (JSON?) -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var description = ""
    @State private var content = ""
    @State private var defaultOn = false
    @State private var loaded = false

    /// `SKILL_NAME` in packages/shared: the name is also a directory, so a bad
    /// one is refused, never rewritten.
    private var nameOk: Bool { name.isEmpty || name.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil }

    var body: some View {
        Form {
            Section {
                TextEditor(text: Binding(get: { content }, set: { onContent($0) }))
                    .font(.caption.monospaced())
                    .frame(minHeight: 200)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("SKILL.md") } footer: {
                Text("Paste the whole file; its name and description fill the fields below.")
            }
            Section {
                TextField("release-notes", text: $name)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Name") } footer: {
                Text(nameOk ? "Lowercase letters, digits and hyphens." : "Use lowercase letters, digits and hyphens only, starting with a letter or digit.")
                    .foregroundStyle(nameOk ? Color.secondary : Color.red)
            }
            Section {
                TextField("Description", text: $description, axis: .vertical)
            } header: { Text("Description") } footer: {
                Text("What Claude reads to decide when to use it.")
            }
            Section {
                Toggle("All my projects", isOn: $defaultOn)
            } footer: {
                Text("On in every project you own, unless a project says otherwise.")
            }
        }
        .navigationTitle(existing?["name"].string ?? "New skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(action.busy || name.isEmpty || !nameOk || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .errorAlert(action)
        .onAppear {
            guard !loaded, let e = existing else { loaded = true; return }
            name = e["name"].string ?? ""
            description = e["description"].string ?? ""
            content = e["content"].string ?? ""
            defaultOn = e["defaultOn"].bool == true
            loaded = true
        }
    }

    private func onContent(_ text: String) {
        let parsed = SkillMarkdown.parse(text)
        if parsed.name != nil || parsed.description != nil {
            if let n = parsed.name { name = n }
            if let d = parsed.description { description = d }
            content = parsed.body
        } else {
            content = text
        }
    }

    private func save() {
        var input: [String: Any?] = ["name": name, "description": description, "content": content, "defaultOn": defaultOn]
        let path: String
        if let id = existing?["id"].string { input["id"] = id; path = "library.skills.update" } else { path = "library.skills.create" }
        action.run {
            guard let api = model.api else { return }
            let r = try await api.mutate(path, .from(input))
            onDone(r)
            dismiss()
        }
    }
}

/// `parseSkillMarkdown` from packages/shared, in Swift: frontmatter `name`
/// and `description` when present, the rest as the body.
enum SkillMarkdown {
    static func parse(_ text: String) -> (name: String?, description: String?, body: String) {
        let pattern = "^\u{FEFF}?---\\r?\\n([\\s\\S]*?)\\r?\\n---[ \\t]*(?:\\r?\\n|$)"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(m.range, in: text), let fm = Range(m.range(at: 1), in: text) else {
            return (nil, nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let front = String(text[fm])
        func field(_ key: String) -> String? {
            for line in front.components(separatedBy: .newlines) {
                guard line.hasPrefix("\(key):") else { continue }
                var v = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()) }
                v = v.trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            return nil
        }
        let body = String(text[whole.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (field("name"), field("description"), body)
    }
}

/// An MCP server, new or edited: a command, or an HTTP/SSE URL with headers.
/// Stored headers and variables are never shown back; leaving them empty on
/// an edit keeps them.
struct McpEditorView: View {
    let existing: JSON?
    let onDone: (JSON?) -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var action = Action()
    @State private var name = ""
    @State private var transport = "stdio"
    @State private var command = ""
    @State private var args = ""
    @State private var url = ""
    @State private var headers = ""
    @State private var envVars = ""
    @State private var defaultOn = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("github", text: $name).font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Picker("Transport", selection: $transport) {
                    Text("Command").tag("stdio")
                    Text("HTTP").tag("http")
                    Text("SSE").tag("sse")
                }
                .pickerStyle(.segmented)
            }
            if transport == "stdio" {
                Section("Command") {
                    TextField("npx", text: $command).font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextEditor(text: $args).font(.caption.monospaced()).frame(minHeight: 70)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Arguments") } footer: { Text("One per line.") }
            } else {
                Section("URL") {
                    TextField("https://example.com/mcp", text: $url).font(.body.monospaced())
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextEditor(text: $headers).font(.caption.monospaced()).frame(minHeight: 50)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Headers") } footer: { Text(kept("headerKeys") ?? "One per line, as Name: value.") }
            }
            Section {
                TextEditor(text: $envVars).font(.caption.monospaced()).frame(minHeight: 50)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Variables") } footer: { Text(kept("envVarKeys") ?? "One per line, as NAME=value.") }
            Section {
                Toggle("All my projects", isOn: $defaultOn)
            } footer: {
                Text("On in every project you own, unless a project says otherwise.")
            }
        }
        .navigationTitle(existing?["name"].string ?? "New MCP server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(action.busy || name.isEmpty || (transport == "stdio" ? command.isEmpty : url.isEmpty))
            }
        }
        .errorAlert(action)
        .onAppear {
            guard !loaded, let e = existing else { loaded = true; return }
            name = e["name"].string ?? ""
            let t = e["transport"].string ?? "stdio"
            transport = (t == "http" || t == "sse") ? t : "stdio"
            command = e["command"].string ?? ""
            args = e["args"].array.compactMap(\.string).joined(separator: "\n")
            url = e["url"].string ?? ""
            defaultOn = e["defaultOn"].bool == true
            loaded = true
        }
    }

    private func kept(_ key: String) -> String? {
        let keys = existing?[key].array.compactMap(\.string) ?? []
        return keys.isEmpty ? nil : "Set: \(keys.joined(separator: ", ")); leave empty to keep them."
    }

    /// `KEY=value` / `Name: value` lines, the shape a person pastes.
    private func lines(_ text: String, sep: Character) -> [String: Any?] {
        var out: [String: Any?] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let i = line.firstIndex(of: sep), i != line.startIndex else { continue }
            out[line[..<i].trimmingCharacters(in: .whitespaces)] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private func save() {
        let stdio = transport == "stdio"
        var input: [String: Any?] = [
            "name": name, "transport": transport, "defaultOn": defaultOn,
            "command": stdio ? command : "",
            "args": stdio ? args.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : [String](),
            "url": stdio ? nil : url,
        ]
        if !headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { input["headers"] = lines(headers, sep: ":") }
        if !envVars.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { input["envVars"] = lines(envVars, sep: "=") }
        let path: String
        if let id = existing?["id"].string { input["id"] = id; path = "library.mcp.update" } else { path = "library.mcp.create" }
        action.run {
            guard let api = model.api else { return }
            let r = try await api.mutate(path, .from(input))
            onDone(r)
            dismiss()
        }
    }
}
