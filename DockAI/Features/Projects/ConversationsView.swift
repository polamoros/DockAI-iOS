// tRPC: project.conversationsState, project.remoteSessionNew, telegram.shares (and row actions through ConversationsStore)
import SwiftUI

/// The Conversations tab: the full list with state pills and each row's
/// menu, New conversation, sharing to Telegram, and — under a disclosure —
/// the account's cloud-side list with archive, delete and bulk selection.
struct ConversationsView: View {
    let slug: String
    let project: JSON
    @EnvironmentObject var model: AppModel
    @StateObject private var store: ConversationsStore
    @State private var share: ConversationShareTarget?
    @State private var showKinds = false
    @State private var showCloud = false
    @State private var sharesForProject = 0
    /// Yours, what DockAI ran on its own, or both — as on the web.
    @State private var filter = "yours"

    init(slug: String, project: JSON) {
        self.slug = slug
        self.project = project
        _store = StateObject(wrappedValue: ConversationsStore(slug: slug))
    }

    private var isOwner: Bool { Proj.isOwner(project) }

    var body: some View {
        List {
            Section {
                HStack {
                    ConversationsRCLine(rc: store.rc, failed: store.loadError != nil && store.state == nil)
                    Spacer()
                    if isOwner { newButton }
                }
                if let created = store.created {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conversation started").font(.subheadline.weight(.semibold))
                        Text("It is in the Claude app within seconds; join it from a terminal with dockai claude \(slug).")
                            .font(.footnote)
                        Button("Close") { store.created = nil }.font(.footnote)
                    }
                    .id(created)
                }
                if let result = store.handoffResult {
                    ConversationHandoffResult(slug: slug, result: result) { store.handoffResult = nil }
                }
            }

            if !store.automated.isEmpty {
                Section {
                    Picker("Show", selection: $filter) {
                        Text("Yours \(store.conversations.count)").tag("yours")
                        Text("Automated \(store.automated.count)").tag("automated")
                        Text("All").tag("all")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                list
            } header: {
                if !store.conversations.isEmpty && filter != "automated" { countHeader }
            } footer: {
                if showKinds { kindsLegend }
            }

            if isOwner {
                Section {
                    Button { share = ConversationShareTarget(id: "", title: "") } label: {
                        Label(sharesForProject > 0 ? "Telegram groups (\(sharesForProject))" : "Share to Telegram", systemImage: "paperplane")
                    }
                } footer: {
                    Text("Open one conversation to a group chat for people without a DockAI account.")
                }
            }

            if let accountId = project["claudeAccountId"].string, isOwner {
                Section {
                    DisclosureGroup("In the Claude app", isExpanded: $showCloud) {
                        if showCloud { CloudConversationsList(accountId: accountId) }
                    }
                } footer: {
                    Text("Every conversation on this Claude account, as Anthropic lists them — not only this project's.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Conversations")
        .refreshable { await store.load(model.api) }
        .task { await store.poll(model) }
        .task { await loadShares() }
        .errorAlert(for: store)
        .sheet(item: $share, onDismiss: { Task { await loadShares() } }) { target in
            NavigationStack {
                ConversationShareView(project: project, slug: slug, preset: target.id.isEmpty ? nil : target, conversations: store.conversations)
            }
        }
    }

    private var newButton: some View {
        Button { store.create(title: nil, api: model.api) } label: {
            if store.creating { ProgressView() } else { Label("New conversation", systemImage: "plus") }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(store.busy || store.creating)
    }

    @ViewBuilder private var list: some View {
        if store.state == nil && store.loadError == nil {
            ProgressView().frame(maxWidth: .infinity)
        } else if let error = store.loadError, store.state == nil {
            ErrorBanner(error: error) { Task { await store.load(model.api) } }
        } else if shown.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.secondary)
                Text("No conversations yet").foregroundStyle(.secondary)
                if isOwner {
                    Button { store.create(title: nil, api: model.api) } label: { Label("New conversation", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).disabled(store.creating)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical)
        } else {
            ForEach(shown, id: \.self) { s in
                ConversationRowView(conversation: s, store: store, isOwner: isOwner, onShare: isOwner ? { id, title in
                    share = ConversationShareTarget(id: id, title: title)
                } : nil)
            }
        }
    }

    private var shown: [JSON] {
        switch filter {
        case "automated": return store.automated
        case "all": return (store.conversations + store.automated).sorted { ($0["updatedAt"].double ?? 0) > ($1["updatedAt"].double ?? 0) }
        default: return store.conversations
        }
    }

    private var countHeader: some View {
        let all = store.conversations.map(ConversationFacts.init)
        let app = all.filter(\.environment).count
        let terminal = all.filter(\.terminal).count
        let local = all.count - app - terminal
        return HStack {
            Text("\(app) app · \(terminal) terminal · \(local) worker only")
            Button { showKinds.toggle() } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("What the kinds mean")
        }.textCase(nil)
    }

    private var kindsLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("**app** — Runs on this project's Remote Control server; only the Claude app joins it.")
            Text("**terminal** — One process the Claude app and dockai claude both join.")
            Text("**worker only** — A transcript in this worker, in no app.")
            Text("**Busy** is answering, **Idle** is waiting for a message, **Needs you** is parked on a permission prompt.")
        }.font(.caption)
    }

    private func loadShares() async {
        guard let api = model.api, isOwner else { return }
        if let shares = try? await api.query("telegram.shares") {
            sharesForProject = shares.array.filter { $0["pinnedProjectId"].string == project["id"].string }.count
        }
    }
}
