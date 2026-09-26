// tRPC: claudeAccount.conversations, claudeAccount.archiveConversation, claudeAccount.deleteConversation, claudeAccount.archiveConversations, claudeAccount.deleteConversations
import SwiftUI

/// An account's conversations as Anthropic lists them (every project's, not
/// one's), read through a running project on the account. Archive is the
/// reversible one; deleting an archived conversation is for good. Select to
/// act on several.
struct AccountConversationsView: View {
    let accountId: String
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var data: JSON?
    @State private var error: Error?
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive

    private var sorted: [JSON] {
        (data?["sessions"].array ?? []).sorted { ($0["lastActiveAt"].double ?? 0) > ($1["lastActiveAt"].double ?? 0) }
    }
    private var active: [JSON] { sorted.filter { $0["archived"].bool != true } }
    private var archived: [JSON] { sorted.filter { $0["archived"].bool == true } }

    var body: some View {
        List(selection: $selection) {
            if let error { ErrorBanner(error: error, retry: { Task { await load() } }) }
            if let data {
                if data["source"].string == "needs-running-project" {
                    ContentUnavailableView("No running project on this account", systemImage: "text.bubble",
                                           description: Text("Start a project that uses this account to list its conversations."))
                } else if sorted.isEmpty {
                    ContentUnavailableView("No conversations yet", systemImage: "text.bubble")
                } else {
                    if !active.isEmpty {
                        Section("Active (\(active.count))") {
                            ForEach(active, id: \.self) { s in
                                row(s).tag(s["apiId"].string ?? "")
                                    .swipeActions {
                                        if let apiId = s["apiId"].string {
                                            Button("Archive") { run("claudeAccount.archiveConversation", ["accountId": accountId, "apiId": apiId]) }.tint(.orange)
                                        }
                                    }
                            }
                        }
                    }
                    if !archived.isEmpty {
                        Section("Archived (\(archived.count))") {
                            ForEach(archived, id: \.self) { s in
                                row(s).tag(s["apiId"].string ?? "")
                                    .swipeActions {
                                        if let apiId = s["apiId"].string {
                                            Button("Delete", role: .destructive) { run("claudeAccount.deleteConversation", ["accountId": accountId, "apiId": apiId]) }
                                        }
                                    }
                            }
                        }
                    }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !sorted.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Select") {
                        editMode = editMode.isEditing ? .inactive : .active
                        selection.removeAll()
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editMode.isEditing {
                    let ids = selection.filter { !$0.isEmpty }
                    let toArchive = active.compactMap { $0["apiId"].string }.filter { ids.contains($0) }
                    let toDelete = archived.compactMap { $0["apiId"].string }.filter { ids.contains($0) }
                    ConfirmButton(title: "Archive \(toArchive.count)", confirmTitle: "Archive \(toArchive.count)?", role: nil) {
                        run("claudeAccount.archiveConversations", ["accountId": accountId, "apiIds": toArchive])
                    }.disabled(toArchive.isEmpty)
                    Spacer()
                    ConfirmButton(title: "Delete \(toDelete.count)", confirmTitle: "Delete \(toDelete.count) for good?") {
                        run("claudeAccount.deleteConversations", ["accountId": accountId, "apiIds": toDelete])
                    }.disabled(toDelete.isEmpty)
                }
            }
        }
        .disabled(action.busy)
        .errorAlert(action)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ s: JSON) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // An empty title is not a title: "" fell through as one and drew a blank row.
            Text([s["title"].string, s["firstMessage"].string, s["id"].string].compactMap { $0 }.first { !$0.isEmpty } ?? "Conversation").lineLimit(2)
            HStack(spacing: 6) {
                // The server says *what* is needed (a sentence), not a flag.
                if let need = s["needsAction"].string, !need.isEmpty { StatePill(text: "Needs you", tone: .warn) }
                else if s["remoteConnected"].bool == true { StatePill(text: "Connected", tone: .ok) }
                if let model = s["model"].string { Text(model) }
                if let ms = s["lastActiveAt"].double { Text(Date(timeIntervalSince1970: ms / 1000).relative) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func run(_ path: String, _ input: [String: Any?]) {
        action.run {
            guard let api = model.api else { return }
            _ = try await api.mutate(path, .from(input))
            selection.removeAll()
            editMode = .inactive
            await load()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            data = try await api.query("claudeAccount.conversations", .from(["accountId": accountId]))
            error = nil
        } catch { self.error = error }
    }
}
