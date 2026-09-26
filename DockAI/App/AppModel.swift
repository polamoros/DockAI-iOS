import SwiftUI

/// The signed-in state: credentials, the one tRPC client, the live event
/// stream, and who the user is (for Admin). Everything reads it from the
/// environment.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var credentials: Credentials?
    @Published private(set) var me: JSON = .null
    @Published var locked = false
    /// A project a link asked to open (`dockai://project/<slug>`, from a Live Activity).
    @Published var openProject: String?
    @AppStorage("faceIDLock") var faceIDLock = false
    /// Something the person must be told once: this iPhone was removed, a
    /// sign-out could not reach the server, a pairing link failed.
    @Published var notice: String?
    let events = EventStream()

    var api: TRPCClient? { credentials.map(TRPCClient.init(credentials:)) }
    var isAdmin: Bool { me["role"].string == "ADMIN" }

    init() {
        credentials = Credentials.load()
        RunActivityController.shared.events = events
        locked = faceIDLock && credentials != nil
        // Every launch, not only at pairing: iOS can hand out a new push
        // token, and permission may have been given later in Settings.
        if credentials != nil { PushCoordinator.shared.register(); WatchLink.shared.start() }
    }

    func signedIn(_ c: Credentials) {
        c.save()
        credentials = c
        Task { await refreshMe(); events.start(c) }
        PushCoordinator.shared.register()
        WatchLink.shared.start()
    }

    func refreshMe() async {
        guard let api else { return }
        do {
            self.me = try await api.query("users.me")
        } catch let e as TRPCError where e.code == "UNAUTHORIZED" {
            // The server no longer knows this token: the iPhone was removed
            // in Your devices, or its token revoked. It showed errors on
            // every screen instead (audit 2026-09-26).
            forgetLocally()
            notice = "This iPhone was removed from DockAI. Pair it again from Settings → Your devices on the web."
        } catch {}
    }

    /// Sign out: revoke this device on the server, forget the token. A revoke
    /// that fails still signs out here, and says so: the device would
    /// otherwise stay active on the server, still receiving pushes.
    func signOut() async {
        if let api, let id = Credentials.deviceId {
            do { _ = try await api.mutate("device.revoke", .from(["id": id])) }
            catch { notice = "Signed out on this iPhone, but DockAI could not be reached to remove it — remove it under Settings → Your devices on the web." }
        }
        forgetLocally()
    }

    private func forgetLocally() {
        events.stop()
        Credentials.clear()
        ScreenCache.clear()
        credentials = nil
        me = .null
    }

    func foreground() {
        guard let c = credentials else { return }
        events.start(c)
        Task { await refreshMe() }
    }
}
