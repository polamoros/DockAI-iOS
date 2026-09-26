// tRPC: claudeAccount.conversations, claudeAccount.archiveConversation, claudeAccount.deleteConversation, claudeAccount.archiveConversations, claudeAccount.deleteConversations
import SwiftUI

/// The account's conversations as Anthropic lists them — every project on
/// the account, not only this one. Active ones can be archived (reversible),
/// archived ones deleted (permanent); both one at a time or selected in bulk.
struct CloudConversationsList: View {
    let accountId: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var data: JSON?
    @State private var error: Error?
    @State private var selected: Set<String> = []
    @State private var confirm: String?
    @Environment(\.openURL) private var openURL

    private var sessions: [JSON] {
        (data?["sessions"].array ?? []).sorted { ($0["lastActiveAt"].double ?? 0) > ($1["lastActiveAt"].double ?? 0) }
    }
    private var active: [JSON] { sessions.filter { $0["archived"].bool != true } }
    private var archived: [JSON] { sessions.filter { $0["archived"].bool == true } }
    private func ids(_ rows: [JSON]) -> [String] { rows.compactMap { $0["apiId"].string } }

    var body: some View {
        Group {
            if let error, data == nil {
                ErrorBanner(error: error) { Task { await load() } }
            } else if let data {
                if data["source"].string == "needs-running-project" {
                    Text("Start a project on this account to list its conversations.").font(.footnote).foregroundStyle(.secondary)
                } else if sessions.isEmpty {
                    Text("No conversations on this account.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    group("Active", rows: active, bulk: "archive")
                    group("Archived", rows: archived, bulk: "delete")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
        .errorAlert(action)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let c = confirm {
                Button(c == "archive" ? "Archive" : "Delete for ever", role: .destructive) { runBulk(c) }
            }
        }
    }

    @ViewBuilder private func group(_ title: String, rows: [JSON], bulk: String) -> some View {
        if !rows.isEmpty {
            let chosen = Set(ids(rows)).intersection(selected)
            HStack {
                Text("\(title) (\(rows.count))").font(.footnote.weight(.semibold))
                Spacer()
                Button(chosen.count == ids(rows).count ? "Deselect" : "Select all") {
                    if chosen.count == ids(rows).count { selected.subtract(ids(rows)) } else { selected.formUnion(ids(rows)) }
                }.font(.caption).buttonStyle(.borderless)
                if !chosen.isEmpty {
                    Button(bulk == "archive" ? "Archive \(chosen.count)" : "Delete \(chosen.count)", role: bulk == "delete" ? .destructive : nil) {
                        confirm = bulk
                    }.font(.caption).buttonStyle(.borderless).disabled(action.busy)
                }
            }
            ForEach(rows, id: \.self) { s in row(s, archived: bulk == "delete") }
        }
    }

    private func row(_ s: JSON, archived: Bool) -> some View {
        let apiId = s["apiId"].string
        let isSelected = apiId.map { selected.contains($0) } ?? false
        return HStack(spacing: 8) {
            Button {
                guard let apiId else { return }
                if isSelected { selected.remove(apiId) } else { selected.insert(apiId) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }.buttonStyle(.borderless).disabled(apiId == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(s["title"].string.flatMap { $0.isEmpty ? nil : $0 } ?? String((s["id"].string ?? "").prefix(8)))
                    .font(.subheadline).lineLimit(1)
                Text(meta(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                if let apiId, let url = URL(string: "https://claude.ai/code/session_\(apiId.hasPrefix("cse_") ? String(apiId.dropFirst(4)) : apiId)") {
                    Button { openURL(url) } label: { Label("Open in the Claude app", systemImage: "arrow.up.right.square") }
                }
                if let apiId {
                    if archived {
                        Button(role: .destructive) { single("claudeAccount.deleteConversation", apiId) } label: { Label("Delete for ever", systemImage: "trash") }
                    } else {
                        Button { single("claudeAccount.archiveConversation", apiId) } label: { Label("Archive", systemImage: "archivebox") }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.borderless)
        }
    }

    private func meta(_ s: JSON) -> String {
        var parts: [String] = []
        if s["active"].bool == true && s["remoteConnected"].bool == true { parts.append("connected") }
        if let ms = s["lastActiveAt"].double { parts.append(Proj.relative(ms: ms)) }
        if let used = s["contextUsed"].double, let max = s["contextMax"].double, max > 0 {
            parts.append("\(Int((used / max * 100).rounded()))% context")
        }
        if let model = s["model"].string, !model.isEmpty { parts.append(model.replacingOccurrences(of: "claude-", with: "")) }
        return parts.joined(separator: " · ")
    }

    private var confirmTitle: String {
        guard let c = confirm else { return "" }
        let n = Set(ids(c == "archive" ? active : archived)).intersection(selected).count
        return c == "archive"
            ? "Archive \(n) conversation\(n == 1 ? "" : "s")? They can be brought back from the Claude app."
            : "Delete \(n) archived conversation\(n == 1 ? "" : "s") for ever? This cannot be undone."
    }

    private func single(_ path: String, _ apiId: String) {
        guard let api = model.api else { return }
        action.run {
            _ = try await api.mutate(path, .from(["accountId": accountId, "apiId": apiId]))
            await load()
        }
    }

    /// Two bulk procedures, because the two buttons do different things: one
    /// is reversible and one is not.
    private func runBulk(_ kind: String) {
        guard let api = model.api else { return }
        let chosen = Array(Set(ids(kind == "archive" ? active : archived)).intersection(selected))
        action.run {
            _ = try await api.mutate(kind == "archive" ? "claudeAccount.archiveConversations" : "claudeAccount.deleteConversations",
                                     .from(["accountId": accountId, "apiIds": JSON.array(chosen.map { JSON.string($0) })]))
            selected.subtract(chosen)
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do { data = try await api.query("claudeAccount.conversations", .from(["accountId": accountId])); error = nil }
        catch { self.error = error }
    }
}
