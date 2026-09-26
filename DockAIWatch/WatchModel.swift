// tRPC: device.pending, project.list, project.usage, project.start, device.ask, project.claudeSessions, project.remoteSessionNew
import Foundation
import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's state (openspec/changes/watch-app). It holds its own device
/// token — paired by the iPhone through WatchConnectivity — and talks to the
/// DockAI server directly, so it works with the iPhone in a pocket.
@MainActor
final class WatchModel: NSObject, ObservableObject {
    @Published private(set) var credentials: Credentials? = Credentials.load()
    @Published private(set) var pending: JSON = .null
    @Published private(set) var projects: [JSON] = []
    @Published private(set) var usage: [WatchUsage] = []
    @Published private(set) var loading = false
    @Published var message: String?

    var api: TRPCClient? { credentials.map(TRPCClient.init(credentials:)) }

    /// Everything waiting, for the count on the face.
    var needsYouCount: Int {
        pending["permissions"].array.count + pending["questions"].array.count + pending["blocked"].array.count
    }

    private var timer: Timer?

    // MARK: Ask — the saved target, on this watch only.

    /// Where Ask sends: a project and one of its conversations (nil = a one-off run).
    struct AskTarget: Codable, Equatable {
        var slug: String
        var projectName: String
        var sessionId: String?
        var sessionTitle: String?
    }
    @Published var askTarget: AskTarget? = {
        guard let d = UserDefaults.standard.data(forKey: "ask.target") else { return nil }
        return try? JSONDecoder().decode(AskTarget.self, from: d)
    }() {
        didSet { if let d = try? JSONEncoder().encode(askTarget) { UserDefaults.standard.set(d, forKey: "ask.target") } }
    }
    /// Said once when a saved conversation had gone and Ask fell back.
    @Published var askNotice: String?
    /// The tab to show — a complication's `dockai://ask` opens Ask.
    @Published var tab = 0

    func conversations(slug: String) async -> [JSON] {
        guard let api else { return [] }
        let list: [JSON]
        do {
            list = try await api.query("project.claudeSessions", .from(["slug": slug]))["sessions"].array
        } catch {
            // A load superseded by the next one (the target changed, the
            // screen went away) is not a failure; the simulator walk showed
            // "Could not load the conversations: cancelled" (2026-09-26).
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return [] }
            // Said, not swallowed: an empty list silently turned the first
            // target into a one-off run.
            askNotice = "Could not load the conversations: \(error.localizedDescription)"
            return []
        }
        // Only conversations with a name or a first message: an id is no
        // choice on a wrist. Live first, then most recent first.
        let named = list.filter(Self.isNamed)
        return named.filter { !$0["remoteState"].isNull } + named.filter { $0["remoteState"].isNull }
    }

    /// The first time, or when the saved conversation is gone: the project's most recent one.
    func resolveTarget() async {
        guard let t = askTarget, let sid = t.sessionId else {
            if askTarget == nil, let p = projects.first(where: { $0["status"].string == "RUNNING" }) ?? projects.first,
               let slug = p["slug"].string {
                let list = await conversations(slug: slug)
                askTarget = AskTarget(slug: slug, projectName: p["name"].string ?? slug, sessionId: list.first?["id"].string, sessionTitle: list.first.map(Self.title))
            }
            return
        }
        let list = await conversations(slug: t.slug)
        if !list.contains(where: { $0["id"].string == sid }), let first = list.first {
            askTarget = AskTarget(slug: t.slug, projectName: t.projectName, sessionId: first["id"].string, sessionTitle: Self.title(first))
            askNotice = "That conversation is gone — asking \(Self.title(first)) instead."
        }
    }

    static func isNamed(_ s: JSON) -> Bool {
        [s["title"].string, s["firstPrompt"].string].contains { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    static func title(_ s: JSON) -> String {
        let t = [s["title"].string, s["firstPrompt"].string].compactMap { $0 }.first { !$0.isEmpty }
        return t ?? String((s["id"].string ?? "").prefix(8))
    }

    /// Make this conversation the Ask target and show Ask.
    func askIn(slug: String, projectName: String, sessionId: String?, title: String?) {
        askTarget = AskTarget(slug: slug, projectName: projectName, sessionId: sessionId, sessionTitle: title)
        askNotice = nil
        tab = 1
    }

    /// A new conversation in the project (the iPhone's New conversation), made the Ask target.
    func newConversation(slug: String, projectName: String) async {
        guard let api else { return }
        do {
            let r = try await api.mutate("project.remoteSessionNew", .from(["slug": slug, "title": "From the watch"]))
            askIn(slug: slug, projectName: projectName, sessionId: r["sessionId"].string, title: "From the watch")
        } catch {
            message = error.localizedDescription
        }
    }

    /// Send what was dictated. The answer arrives as a notification.
    func ask(_ text: String, slug: String? = nil, sessionId: String?? = nil) async -> Bool {
        guard let api else { return false }
        let s = slug ?? askTarget?.slug
        let sid: String? = sessionId ?? askTarget?.sessionId
        guard let s else { return false }
        do {
            _ = try await api.mutate("device.ask", .from(["slug": s, "sessionId": sid.map { JSON.string($0) } ?? JSON.null, "text": text]))
            WKInterfaceDevice.current().play(.success)
            return true
        } catch {
            message = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
            return false
        }
    }

    func start() {
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        WatchPush.shared.register(model: self)
        Task { await refresh() }
    }

    /// Refresh every minute while the app is on screen.
    func visible(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let api else { askPhoneToPair(); return }
        loading = true
        defer { loading = false }
        do {
            pending = try await api.query("device.pending")
            projects = try await api.query("project.list").array
            usage = await readUsage(api)
            publishForComplications()
        } catch let e as TRPCError where e.code == "UNAUTHORIZED" || e.code == "401" {
            // Revoked in Your devices: forget the token and ask the iPhone again.
            UserDefaults.standard.set(true, forKey: "watch.revoked")
            signOut()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Answers — the same `/api/devices/action` the iPhone's buttons use.

    func answerPermission(key: String, allow: Bool) async {
        await act(["kind": "permission", "key": key, "allow": allow])
    }

    func answerQuestion(id: String, index: Int? = nil, text: String? = nil) async {
        var body: [String: Any?] = ["kind": "ask", "id": id]
        if let index { body["index"] = index }
        if let text { body["text"] = text }
        await act(body)
    }

    func start(projectId: String) async {
        guard let api else { return }
        do { _ = try await api.mutate("project.start", .from(["id": projectId])) } catch { message = error.localizedDescription }
        await refresh()
    }

    private func act(_ body: [String: Any?]) async {
        guard let api else { return }
        do {
            let r = try await api.post("api/devices/action", .from(body))
            // The server says so when it was answered elsewhere first.
            if let said = r["message"].string, !said.isEmpty { message = said }
            WKInterfaceDevice.current().play(.success)
        } catch {
            message = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
        await refresh()
    }

    // MARK: Usage — through a running project per account, as the iPhone widget does.

    private func readUsage(_ api: TRPCClient) async -> [WatchUsage] {
        var seen = Set<String>()
        var out: [WatchUsage] = []
        for p in projects where p["status"].string == "RUNNING" {
            guard let acc = p["claudeAccountId"].string, !seen.contains(acc), let slug = p["slug"].string else { continue }
            seen.insert(acc)
            guard let u = try? await api.query("project.usage", .from(["slug": slug])), !u.isNull, u["source"].string != "error" else { continue }
            out.append(WatchUsage(
                id: acc, name: p["claudeAccount"]["label"].string ?? "Claude",
                sessionPct: u["fiveHour"]["utilization"].double, sessionResetsAt: u["fiveHour"]["resetsAt"].date,
                weeklyPct: u["sevenDay"]["utilization"].double, weeklyResetsAt: u["sevenDay"]["resetsAt"].date))
        }
        return out
    }

    /// What the complications draw, in the shared app group.
    private func publishForComplications() {
        let d = WatchShared.defaults
        d?.set(needsYouCount, forKey: WatchShared.needsYouKey)
        if let w = usage.compactMap(\.weeklyPct).max() { d?.set(w, forKey: WatchShared.weeklyKey) }
        d?.set(Date().timeIntervalSince1970, forKey: WatchShared.updatedKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Pairing through the iPhone

    fileprivate func pair(with link: String) async {
        guard let p = Pairing.parse(link) else { return }
        do {
            let c = try await Pairing.pair(server: p.server, code: p.code, deviceName: WKInterfaceDevice.current().name, platform: "watchos")
            c.save()
            UserDefaults.standard.set(false, forKey: "watch.revoked")
            credentials = c
            try? WCSession.default.updateApplicationContext(["watchPaired": true])
            message = "Paired with DockAI."
            await refresh()
        } catch {
            message = "Pairing failed: \(error.localizedDescription)"
        }
    }

    private func askPhoneToPair() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        // Removed on purpose (Your devices) → only the person pairs it again,
        // from the iPhone. Asking here re-paired a revoked watch within
        // minutes (audit 2026-09-26).
        if UserDefaults.standard.bool(forKey: "watch.revoked") {
            try? WCSession.default.updateApplicationContext(["watchPaired": false, "revoked": true])
            return
        }
        try? WCSession.default.updateApplicationContext(["watchPaired": false])
        if WCSession.default.isReachable { WCSession.default.sendMessage(["needPair": true], replyHandler: nil) }
    }

    private func signOut() {
        Credentials.clear()
        credentials = nil
        pending = .null
        projects = []
        usage = []
        askPhoneToPair()
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in if self.credentials == nil { self.askPhoneToPair() } }
    }

    /// The pairing link the iPhone minted for this watch.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let link = userInfo["pair"] as? String else { return }
        Task { @MainActor in
            guard self.credentials == nil else { return }
            await self.pair(with: link)
        }
    }
}

struct WatchUsage: Identifiable {
    let id: String
    let name: String
    let sessionPct: Double?
    let sessionResetsAt: Date?
    let weeklyPct: Double?
    let weeklyResetsAt: Date?
}

/// What the app and the complications share.
enum WatchShared {
    static let needsYouKey = "watch.needsYou"
    static let weeklyKey = "watch.weekly"
    static let updatedKey = "watch.updated"
    static var defaults: UserDefaults? {
        (Bundle.main.object(forInfoDictionaryKey: "DockAIAppGroup") as? String).flatMap(UserDefaults.init(suiteName:))
    }
}
