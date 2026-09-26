// tRPC: project.conversationsState, project.remoteSessionStart, project.remoteSessionStop, project.remoteSessionNew, project.deleteConversation, project.archiveConversation, project.sessionHandoff
import SwiftUI

/// The project's conversations, the Remote Control server and the CLI's
/// process roster — one query, `project.conversationsState`, as on the web —
/// and every row action, in one place so the Overview's summary and the
/// Conversations tab cannot grow different menus for the same row.
@MainActor
final class ConversationsStore: ObservableObject {
    let slug: String
    @Published private(set) var state: JSON?
    @Published var loadError: Error?
    @Published var actionError: Error?
    @Published private(set) var busy = false
    @Published private(set) var deletingId: String?
    @Published var handoffResult: JSON?
    @Published var created: String?
    @Published private(set) var creating = false
    /// Deleted rows go the moment the server says so, not on the next poll.
    @Published private var gone: Set<String> = []

    /// Seeded from the last answer (ScreenCache), so the list is on screen at
    /// once and the load below only refreshes it.
    init(slug: String) {
        self.slug = slug
        self.state = ScreenCache.get(cacheKey)
    }

    private var cacheKey: String { "conversations.\(slug)" }

    /// A transcript with no user message and nothing live is a throwaway —
    /// the server's pre-created conversation, or one opened and abandoned.
    private var listed: [JSON] {
        (state?["sessions"].array ?? []).filter { s in
            let id = s["id"].string ?? ""
            return ((s["messageCount"].int ?? 0) > 0 || !s["remoteState"].isNull) && !gone.contains(id)
        }
    }

    /// The person's own conversations — what every picker and count uses.
    var conversations: [JSON] { listed.filter { ($0["automated"].string ?? "").isEmpty } }

    /// What DockAI ran on its own, named by its automation rather than its
    /// first message ("Run" when the run had no name) — the tab's Automated.
    var automated: [JSON] {
        listed.filter { !($0["automated"].string ?? "").isEmpty }.map { s in
            guard let label = s["automated"].string, label != "Run" else { return s }
            var o = s.object
            o["title"] = .string(label)
            return .object(o)
        }
    }

    /// Process state by local conversation id: working, idle or blocked.
    var roster: [String: String] {
        var out: [String: String] = [:]
        for a in state?["roster"]["agents"].array ?? [] {
            guard let id = a["sessionId"].string else { continue }
            out[id] = a["blocked"].bool == true ? "blocked" : a["state"].string == "working" ? "working" : "idle"
        }
        return out
    }

    /// Whether the CLI answered the roster at all — an older worker image does not.
    var rosterKnown: Bool { state?["roster"]["supported"].bool ?? false }
    var rc: JSON { state?["rc"] ?? .null }

    func load(_ api: TRPCClient?) async {
        guard let api else { return }
        do {
            let fresh = try await api.query("project.conversationsState", .from(["slug": slug, "sessions": true, "includeAutomated": true]))
            state = fresh
            ScreenCache.set(cacheKey, fresh)
            loadError = nil
        } catch { loadError = error }
    }

    /// Poll every 15 seconds while the caller's task lives.
    func poll(_ model: AppModel) async {
        while !Task.isCancelled {
            await load(model.api)
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    private func perform(_ api: TRPCClient?, _ work: @escaping (TRPCClient) async throws -> Void) {
        guard let api else { return }
        busy = true
        Task {
            do { try await work(api) } catch { actionError = error }
            busy = false
            await load(api)
        }
    }

    func resume(_ id: String, api: TRPCClient?) {
        perform(api) { api in _ = try await api.mutate("project.remoteSessionStart", .from(["slug": self.slug, "sessionId": id])) }
    }

    func stop(_ id: String, api: TRPCClient?) {
        perform(api) { api in _ = try await api.mutate("project.remoteSessionStop", .from(["slug": self.slug, "sessionId": id])) }
    }

    func delete(_ id: String, api: TRPCClient?) {
        deletingId = id
        perform(api) { api in
            _ = try await api.mutate("project.deleteConversation", .from(["slug": self.slug, "sessionId": id]))
            self.gone.insert(id)
            self.deletingId = nil
        }
        Task { try? await Task.sleep(nanoseconds: 30_000_000_000); if deletingId == id { deletingId = nil } }
    }

    /// Archive in the Claude app; the transcript stays.
    func archive(_ id: String, remoteId: String?, api: TRPCClient?) {
        perform(api) { api in
            _ = try await api.mutate("project.archiveConversation", .from(["slug": self.slug, "sessionId": id, "apiId": remoteId]))
        }
    }

    /// Move a conversation's dialogue into a new one: `terminal` for an
    /// interactive conversation a terminal can join, nil for an app one.
    func handoff(_ id: String, target: String?, api: TRPCClient?) {
        perform(api) { api in
            var input: [String: Any?] = ["slug": self.slug, "sessionId": id]
            if let target { input["target"] = target }
            let r = try await api.mutate("project.sessionHandoff", .from(input))
            self.handoffResult = r
        }
    }

    func create(title: String?, api: TRPCClient?) {
        guard let api else { return }
        creating = true
        created = nil
        Task {
            do {
                var input: [String: Any?] = ["slug": slug]
                if let title, !title.isEmpty { input["title"] = title }
                let r = try await api.mutate("project.remoteSessionNew", .from(input))
                created = r["sessionId"].string ?? ""
            } catch { actionError = error }
            creating = false
            await load(api)
        }
    }
}

/// Facts about one conversation row, derived the way the web derives them.
struct ConversationFacts {
    let s: JSON
    var id: String { s["id"].string ?? "" }
    var remoteState: String? { s["remoteState"].string }
    var remoteId: String? { s["remoteId"].string }
    var messageCount: Int { s["messageCount"].int ?? 0 }
    /// Served by the project's Remote Control server: the phone owns it.
    var served: Bool { remoteState == "server" }
    var live: Bool { remoteState != nil }
    var environment: Bool { s["origin"].string == "phone" || remoteState == "server" }
    var terminal: Bool { !environment && (remoteId != nil || remoteState == "interactive") }
    var kind: String { environment ? "app" : remoteId != nil ? "terminal" : "worker only" }
    var title: String {
        if let t = s["title"].string, !t.isEmpty { return t }
        if let p = s["firstPrompt"].string, !p.isEmpty { return p }
        return "Untitled"
    }
    var lastPrompt: String? {
        let last = (s["lastPrompt"].string ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let t = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return last.isEmpty || last == t ? nil : last
    }
    /// https://claude.ai/code/session_<id without cse_>
    var url: URL? {
        guard let r = remoteId else { return nil }
        let bare = r.hasPrefix("cse_") ? String(r.dropFirst(4)) : r
        return URL(string: "https://claude.ai/code/session_\(bare)")
    }
    /// An idle bound conversation with no known remote id has nothing to be
    /// resumed with: resuming the transcript would mint a second remote session.
    var canResume: Bool { !live && (!environment || remoteId != nil) }
    var canStop: Bool { live && !served }
    var canMoveToTerminal: Bool { environment && messageCount > 0 }
    var canMoveToApp: Bool { !environment && messageCount > 0 }
}
