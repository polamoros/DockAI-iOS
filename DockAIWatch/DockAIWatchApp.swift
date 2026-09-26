import SwiftUI
import UserNotifications

/// DockAI on the Apple Watch (openspec/changes/watch-app): what is waiting on
/// the person, the projects and the usage, one swipe apart.
@main
struct DockAIWatchApp: App {
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.credentials == nil {
                    UnpairedView()
                } else {
                    TabView(selection: $model.tab) {
                        NeedsYouView().tag(0)
                        AskView().tag(1)
                        WatchProjectsView().tag(2)
                        WatchUsageView().tag(3)
                    }
                    .tabViewStyle(.verticalPage)
                }
            }
            .environmentObject(model)
            .onAppear { model.start() }
            // The Ask complication opens here.
            .onOpenURL { url in if url.host == "ask" { model.tab = 1 } }
            .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
        .onChange(of: phase) { _, p in model.visible(p == .active) }
    }
}

struct UnpairedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward").font(.title2)
            Text("Open DockAI on your iPhone").font(.headline).multilineTextAlignment(.center)
            Text("It pairs this watch for you.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

/// A notification's buttons on the wrist — the iPhone's categories, answered
/// with the watch's own token, through the same endpoint.
final class WatchPush: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchPush()
    private weak var model: WatchModel?

    func register(model: WatchModel) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let ask = UNNotificationCategory(identifier: "DOCKAI_ASK", actions: (0..<4).map { UNNotificationAction(identifier: "opt\($0)", title: "Option \($0 + 1)") }
            + [UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Answer")], intentIdentifiers: [])
        let perm = UNNotificationCategory(identifier: "DOCKAI_PERMISSION", actions: [
            UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired]),
            UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
        ], intentIdentifiers: [])
        let auto = UNNotificationCategory(identifier: "DOCKAI_AUTOMATION", actions: [
            UNNotificationAction(identifier: "run", title: "Run again"),
            UNNotificationAction(identifier: "pause", title: "Pause"),
        ], intentIdentifiers: [])
        // An answer to an Ask: reply by voice, to the same conversation.
        let answer = UNNotificationCategory(identifier: "DOCKAI_ANSWER", actions: [
            UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Reply"),
        ], intentIdentifiers: [])
        center.setNotificationCategories([ask, perm, auto, answer])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let c = Credentials.load() else { return }
        let info = response.notification.request.content.userInfo["dockai"] as? [String: Any] ?? [:]
        let id = response.actionIdentifier
        let kind = response.notification.request.content.categoryIdentifier.split(separator: ":").first.map(String.init) ?? ""
        var body: [String: Any?]?
        switch kind {
        case "DOCKAI_ASK":
            if let reply = response as? UNTextInputNotificationResponse { body = ["kind": "ask", "id": info["askId"], "text": reply.userText] }
            else if id.hasPrefix("opt"), let i = Int(id.dropFirst(3)) { body = ["kind": "ask", "id": info["askId"], "index": i] }
        case "DOCKAI_PERMISSION":
            if id == "allow" || id == "deny" { body = ["kind": "permission", "key": info["key"], "allow": id == "allow"] }
        case "DOCKAI_AUTOMATION":
            if id == "run" || id == "pause" { body = ["kind": "automation", "scheduleId": info["scheduleId"], "what": id] }
        case "DOCKAI_ANSWER":
            if let reply = response as? UNTextInputNotificationResponse, let slug = info["slug"] as? String {
                let sid = info["sessionId"] as? String
                _ = try? await TRPCClient(credentials: c).mutate("device.ask", .from(["slug": slug, "sessionId": sid.map { JSON.string($0) } ?? JSON.null, "text": reply.userText]))
            }
        default: break
        }
        if let body { _ = try? await TRPCClient(credentials: c).post("api/devices/action", .from(body)) }
        await model?.refresh()
    }
}
