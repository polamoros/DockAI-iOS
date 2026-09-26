// tRPC: device.ask
import SwiftUI
import UserNotifications

/// Push: registration with the server, the actionable categories, and what a
/// tap on an action sends back (`/api/devices/action`) — the same handlers
/// Telegram's buttons use on the server.
final class PushCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushCoordinator()

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Merged, not replaced: the notification extension registers a
        // category per message (the real option / button labels), and a
        // replace here would drop those on every launch.
        center.getNotificationCategories { existing in
            let ours = Set(Self.categories.map(\.identifier))
            center.setNotificationCategories(existing.filter { !ours.contains($0.identifier) }.union(Self.categories))
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
        }
    }

    /// Called by the app delegate with the APNs token.
    func didRegister(token: Data) {
        guard let c = Credentials.load() else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        Task { await Self.register(hex: hex, env: env, credentials: c) }
    }

    /// Straight to this server when it holds the app's APNs key; through its
    /// push relay when it has none (the relay gives a handle, and the server
    /// pushes to the handle — the device token goes only to the relay).
    private static func register(hex: String, env: String, credentials c: Credentials) async {
        let api = TRPCClient(credentials: c)
        var body: [String: Any?] = ["token": hex, "env": env]
        if let cfg = try? await api.get("api/devices/push-config"), cfg["mode"].string == "relay",
           let relay = cfg["relayUrl"].string, let installation = cfg["installationId"].string,
           let url = URL(string: relay)?.appendingPathComponent("api/push-relay/v1/devices"), url.scheme == "https" {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(JSON.from(["installationId": installation, "apnsToken": hex, "env": env]))
            if let result = try? await URLSession.shared.data(for: req),
               (result.1 as? HTTPURLResponse)?.statusCode == 200,
               let handle = (try? JSONDecoder().decode(JSON.self, from: result.0))?["handle"].string {
                body["relayHandle"] = handle
            }
        }
        _ = try? await api.post("api/devices/apns-token", .from(body))
    }

    static var categories: Set<UNNotificationCategory> {
        let ask = UNNotificationCategory(identifier: "DOCKAI_ASK", actions: (0..<4).map { UNNotificationAction(identifier: "opt\($0)", title: "Option \($0 + 1)") }
            + [UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Answer")], intentIdentifiers: [])
        let perm = UNNotificationCategory(identifier: "DOCKAI_PERMISSION", actions: [
            UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired]),
            UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
        ], intentIdentifiers: [])
        let auto = UNNotificationCategory(identifier: "DOCKAI_AUTOMATION", actions: [
            UNNotificationAction(identifier: "run", title: "Run again"),
            UNNotificationAction(identifier: "pause", title: "Pause"),
        ] + (0..<3).map { UNNotificationAction(identifier: "b\($0)", title: "Button \($0 + 1)") }, intentIdentifiers: [])
        let info = UNNotificationCategory(identifier: "DOCKAI_INFO", actions: [], intentIdentifiers: [])
        // An answer to an Ask from the watch: reply to the same conversation.
        let answer = UNNotificationCategory(identifier: "DOCKAI_ANSWER", actions: [
            UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Reply"),
        ], intentIdentifiers: [])
        return [ask, perm, auto, info, answer]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let c = Credentials.load() else { return }
        let info = response.notification.request.content.userInfo["dockai"] as? [String: Any] ?? [:]
        let id = response.actionIdentifier
        var body: [String: Any?]?
        // Per-message categories are "DOCKAI_ASK:<request id>" — match on the kind.
        let kind = response.notification.request.content.categoryIdentifier.split(separator: ":").first.map(String.init) ?? ""
        switch kind {
        case "DOCKAI_ASK":
            if let reply = response as? UNTextInputNotificationResponse { body = ["kind": "ask", "id": info["askId"], "text": reply.userText] }
            else if id.hasPrefix("opt"), let i = Int(id.dropFirst(3)) { body = ["kind": "ask", "id": info["askId"], "index": i] }
        case "DOCKAI_PERMISSION":
            if id == "allow" || id == "deny" { body = ["kind": "permission", "key": info["key"], "allow": id == "allow"] }
        case "DOCKAI_AUTOMATION":
            if id == "run" || id == "pause" { body = ["kind": "automation", "scheduleId": info["scheduleId"], "what": id] }
            else if id.hasPrefix("b"), let i = Int(id.dropFirst()) { body = ["kind": "automation", "scheduleId": info["scheduleId"], "button": i] }
        default: break
        }
        if kind == "DOCKAI_ANSWER", let reply = response as? UNTextInputNotificationResponse, let slug = info["slug"] as? String {
            let sid = info["sessionId"] as? String
            do { _ = try await TRPCClient(credentials: c).mutate("device.ask", .from(["slug": slug, "sessionId": sid.map { JSON.string($0) } ?? JSON.null, "text": reply.userText])) }
            catch { await Self.tell("Not sent: \(error.localizedDescription)") }
            return
        }
        guard let body else { return }
        // What the server made of the tap is said back when it was not what
        // was meant — "Already answered", "not yours", "expired" — instead of
        // being thrown away (audit 2026-09-26).
        do {
            let r = try await TRPCClient(credentials: c).post("api/devices/action", .from(body))
            if let m = r["message"].string, !["Allowed", "Denied", "Sent."].contains(m), !m.hasPrefix("Running") {
                await Self.tell(m)
            }
        } catch {
            await Self.tell("DockAI could not be reached: \(error.localizedDescription)")
        }
    }

    /// A one-line notification in place of the one just acted on.
    private static func tell(_ text: String) async {
        let c = UNMutableNotificationContent()
        c.title = "DockAI"
        c.body = text
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dockai-action-\(UUID().uuidString)", content: c, trigger: nil))
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCoordinator.shared.didRegister(token: deviceToken)
    }
}
