// tRPC: device.createPairCode
import Foundation
import UserNotifications
import WatchConnectivity

/// Pairs the Apple Watch for the person (openspec/changes/watch-app): no QR
/// on a watch, so the iPhone — already paired — asks the server for a code
/// only a watch can redeem and hands the link over. The watch exchanges it
/// for its own device token and says so in its application context
/// (`watchPaired`); anything else means it still needs one.
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private let lastSentKey = "watch.pairLinkSentAt"
    private let revokedKey = "watch.revokedOnPhone"

    /// Whether the watch was removed and waits for the person to pair it again.
    var watchRevoked: Bool { UserDefaults.standard.bool(forKey: revokedKey) }

    /// The person asked to pair the watch again (Your devices).
    func pairAgain() {
        UserDefaults.standard.set(false, forKey: revokedKey)
        UserDefaults.standard.set(0, forKey: lastSentKey)
        guard WCSession.isSupported() else { return }
        pairIfNeeded(WCSession.default, force: true)
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        if s.activationState == .activated { pairIfNeeded(s) } else { s.activate() }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated { pairIfNeeded(session) }
    }

    /// The watch says whether it holds a token (after pairing, or after a revoke).
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        // A watch removed in Your devices stays removed until the person
        // pairs it again (`pairAgain`).
        if context["revoked"] as? Bool == true {
            UserDefaults.standard.set(true, forKey: revokedKey)
            return
        }
        if context["watchPaired"] as? Bool == false { pairIfNeeded(session, force: true) }
        if context["watchPaired"] as? Bool == true, !UserDefaults.standard.bool(forKey: "watch.pairedAnnounced") {
            // Said once: pairing happens in the background, and nothing
            // on either screen used to say it had worked.
            UserDefaults.standard.set(true, forKey: "watch.pairedAnnounced")
            let c = UNMutableNotificationContent()
            c.title = "Apple Watch paired"
            c.body = "DockAI is on your watch: what needs you, Ask by voice, projects and usage."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-paired", content: c, trigger: nil))
        }
    }

    /// An unpaired watch that can reach the iPhone asks straight away.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["needPair"] as? Bool == true && !watchRevoked { pairIfNeeded(session, force: true) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    private func pairIfNeeded(_ session: WCSession, force: Bool = false) {
        guard session.isPaired, session.isWatchAppInstalled, !watchRevoked else { return }
        if session.receivedApplicationContext["watchPaired"] as? Bool == true && !force { return }
        // A code lives ten minutes; do not mint another while one is in flight.
        let last = UserDefaults.standard.double(forKey: lastSentKey)
        if Date().timeIntervalSince1970 - last < 9 * 60 { return }
        guard let c = Credentials.load() else { return }
        Task {
            do {
                let r = try await TRPCClient(credentials: c).mutate("device.createPairCode", .from(["for": "watchos"]))
                guard let uri = r["uri"].string else { return }
                session.transferUserInfo(["pair": uri])
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSentKey)
            } catch {
                // Nothing to show on the iPhone; the watch's own screen says to open this app.
            }
        }
    }
}
