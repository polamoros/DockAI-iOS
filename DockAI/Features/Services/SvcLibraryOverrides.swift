// tRPC: library.forProject, library.setOverride
import SwiftUI

/// One project's say over its owner's library (LibraryOverrides.tsx): each item
/// Default · On · Off, with what the default is written beside it. Renders
/// nothing when the library has no item of this kind. Used for MCP servers on
/// the Services tab and for skills in Settings → Claude; each choice applies at once.
struct SvcLibraryOverrides: View {
    let projectId: String
    /// "skill" or "mcp"
    let kind: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var items: [JSON] = []
    @State private var missed: [String] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                Section {
                    if !missed.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Saved, not yet live everywhere").font(.callout.weight(.medium))
                            Text("These projects get it at their next start: \(missed.joined(separator: ", ")).").font(.caption)
                        }
                        .foregroundStyle(.orange)
                    }
                    ForEach(items, id: \.self) { item in row(item) }
                } header: {
                    Text(kind == "skill" ? "Skills" : "From your library")
                } footer: {
                    Text(kind == "skill"
                         ? "From your library; conversations and terminals get them, automations and Telegram runs do not. Manage the library in Settings → Skills & MCP."
                         : "MCP servers from Settings → Skills & MCP; this project's own of the same name wins.")
                }
            }
        }
        .errorAlert(action)
        .task { await load() }
    }

    private func row(_ item: JSON) -> some View {
        let id = item["id"].string ?? ""
        var detail: [String] = []
        if let d = item["description"].string, !d.isEmpty { detail.append(d) }
        detail.append("Default: \(item["defaultOn"].bool == true ? "on" : "off")")
        if item["shadowed"].bool == true { detail.append("This project's own MCP server of that name is used instead.") }
        return VStack(alignment: .leading, spacing: 6) {
            PSLabel(title: item["name"].string ?? "", detail: detail.joined(separator: " · "))
            Picker(item["name"].string ?? "", selection: Binding(
                get: { item["override"].string ?? "default" },
                set: { value in set(id, value) }
            )) {
                Text("Default").tag("default")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(action.busy)
        }
        .padding(.vertical, 2)
    }

    private func set(_ itemId: String, _ value: String) {
        action.run {
            let r = try await model.api?.mutate("library.setOverride", .from([
                "projectId": projectId, "kind": kind, "itemId": itemId, "value": value,
            ])) ?? .null
            missed = r["notUpdated"].array.compactMap(\.string)
            await load()
        }
    }

    private func load() async {
        guard let api = model.api, let v = try? await api.query("library.forProject", .from(["projectId": projectId])) else { return }
        items = (kind == "skill" ? v["skills"] : v["mcpServers"]).array
    }
}
