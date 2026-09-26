// tRPC: project.readEnv, project.writeEnv
import SwiftUI

/// Settings → .env (EnvSettings.tsx): the repo's `.env`, keys pre-filled from
/// `.env.example` with their hints; secret-looking values hidden until shown.
struct PSEnvSettings: View {
    let slug: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var entries: [Entry] = []
    @State private var original: [Entry] = []
    @State private var hasExample = false
    @State private var loaded = false
    @State private var loadError: Error?
    @State private var revealed: Set<UUID> = []
    @State private var saved = false

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
        var hint: String
        var fromExample: Bool
        var required: Bool
        static func == (a: Entry, b: Entry) -> Bool { a.key == b.key && a.value == b.value }
    }

    private static let secretPattern = #"(?i)password|secret|key|token|api_key|apikey|auth|credential"#
    private func isSecret(_ key: String) -> Bool { key.range(of: Self.secretPattern, options: .regularExpression) != nil }

    private var hasChanges: Bool { entries.map { [$0.key, $0.value] } != original.map { [$0.key, $0.value] } }
    private var hasEmptyRequired: Bool { entries.contains { $0.required && $0.value.isEmpty } }

    var body: some View {
        Group {
            if let loadError {
                ErrorBanner(error: loadError) { Task { await load() } }.padding()
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .errorAlert(action)
        .task { await load() }
    }

    private var form: some View {
        Form {
            Section {
                if !hasExample && entries.isEmpty {
                    Text("No .env.example found. You can add variables manually.").foregroundStyle(.secondary)
                }
                if hasEmptyRequired {
                    Label("Some required variables are empty", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                ForEach($entries) { $entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if entry.fromExample {
                                Text(entry.key).font(.system(.subheadline, design: .monospaced).weight(.medium))
                            } else {
                                TextField("VARIABLE_NAME", text: $entry.key)
                                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                    .onChange(of: entry.key) { _, v in
                                        let clean = String(v.filter { ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" })
                                        if clean != v { entry.key = clean }
                                    }
                            }
                            if entry.required && entry.value.isEmpty { StatePill(text: "required", tone: .warn) }
                            Spacer()
                            if isSecret(entry.key) {
                                Button {
                                    if revealed.contains(entry.id) { revealed.remove(entry.id) } else { revealed.insert(entry.id) }
                                } label: { Image(systemName: revealed.contains(entry.id) ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(revealed.contains(entry.id) ? "Hide value" : "Show value")
                            }
                            if !entry.fromExample {
                                Button(role: .destructive) {
                                    let id = entry.id
                                    entries.removeAll { $0.id == id }
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove \(entry.key.isEmpty ? "variable" : entry.key)")
                            }
                        }
                        if !entry.hint.isEmpty { Text(entry.hint).font(.caption).foregroundStyle(.secondary) }
                        Group {
                            if isSecret(entry.key) && !revealed.contains(entry.id) {
                                SecureField("Enter value…", text: $entry.value)
                            } else {
                                TextField("Enter value…", text: $entry.value)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Button {
                    entries.append(Entry(key: "", value: "", hint: "", fromExample: false, required: false))
                } label: { Label("Add variable", systemImage: "plus") }
            } header: {
                Text("Environment variables")
            } footer: {
                Text("Keys are pre-filled from .env.example.")
            }

            PSSaveSection(
                consequence: ["Written to the project’s .env inside the worker. A process already running keeps the old values until it restarts."],
                busy: action.busy, saved: saved, disabled: !hasChanges, save: save)
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let data = try await api.query("project.readEnv", .from(["slug": slug]))
            hasExample = data["hasExample"].bool == true
            entries = data["entries"].array.map {
                Entry(key: $0["key"].string ?? "", value: $0["value"].string ?? "", hint: $0["hint"].string ?? "",
                      fromExample: $0["fromExample"].bool == true, required: $0["required"].bool == true)
            }
            original = entries
            loaded = true
            loadError = nil
        } catch { loadError = error }
    }

    private func save() {
        let payload: [JSON] = entries
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { .object(["key": .string($0.key), "value": .string($0.value)]) }
        action.run {
            _ = try await model.api?.mutate("project.writeEnv", .object(["slug": .string(slug), "entries": .array(payload)]))
            await load()
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
        }
    }
}
