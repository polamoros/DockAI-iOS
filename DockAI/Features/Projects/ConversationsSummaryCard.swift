// tRPC: project.conversationsState (through ConversationsStore)
import SwiftUI

/// The Overview's conversations card: a summary, not the list. The Remote
/// Control line, how many are live, the live ones first (five at most, each
/// with its one action and its menu), and a way to the full list.
struct ConversationsSummaryCard: View {
    let slug: String
    let project: JSON
    @EnvironmentObject var model: AppModel
    @StateObject private var store: ConversationsStore
    @State private var share: ConversationShareTarget?

    init(slug: String, project: JSON) {
        self.slug = slug
        self.project = project
        _store = StateObject(wrappedValue: ConversationsStore(slug: slug))
    }

    private static let rows = 5

    var body: some View {
        let all = store.conversations
        let shown = all.sorted { a, b in
            let la = a["remoteState"].isNull ? 1 : 0, lb = b["remoteState"].isNull ? 1 : 0
            if la != lb { return la < lb }
            return (a["updatedAt"].double ?? 0) > (b["updatedAt"].double ?? 0)
        }.prefix(Self.rows)
        let live = all.filter { !$0["remoteState"].isNull }.count

        ProjCard("Conversations", systemImage: "bubble.left.and.bubble.right") {
            NavigationLink("See all") { ConversationsView(slug: slug, project: project) }.font(.footnote)
        } content: {
            HStack {
                ConversationsRCLine(rc: store.rc, failed: store.loadError != nil && store.state == nil)
                Spacer()
                if !all.isEmpty { Text("\(live) live").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if store.state == nil && store.loadError == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = store.loadError, store.state == nil {
                ErrorBanner(error: error) { Task { await store.load(model.api) } }
            } else if shown.isEmpty {
                VStack(spacing: 8) {
                    Text("No conversations yet").font(.subheadline).foregroundStyle(.secondary)
                    NavigationLink { ConversationsView(slug: slug, project: project) } label: {
                        Label("New conversation", systemImage: "plus")
                    }.buttonStyle(.bordered).controlSize(.small)
                }.frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown), id: \.self) { s in
                        ConversationRowView(conversation: s, store: store, isOwner: Proj.isOwner(project), onShare: Proj.isOwner(project) ? { id, title in
                            share = ConversationShareTarget(id: id, title: title)
                        } : nil)
                        Divider()
                    }
                }
                if all.count > shown.count {
                    NavigationLink("\(all.count - shown.count) more") { ConversationsView(slug: slug, project: project) }
                        .font(.footnote)
                }
            }
            if let result = store.handoffResult {
                ConversationHandoffResult(slug: slug, result: result) { store.handoffResult = nil }
            }
        }
        .task { await store.poll(model) }
        .errorAlert(for: store)
        .sheet(item: $share) { target in
            NavigationStack {
                ConversationShareView(project: project, slug: slug, preset: target, conversations: store.conversations)
            }
        }
    }
}

/// A conversation to share, carried into the share sheet.
struct ConversationShareTarget: Identifiable, Hashable {
    let id: String
    let title: String
}

extension View {
    /// A row action's failure, as an alert with the server's own message.
    func errorAlert(for store: ConversationsStore) -> some View {
        alert("Something went wrong", isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.actionError?.localizedDescription ?? "") }
    }
}
