import SwiftUI
import LocalAuthentication

@main
struct DockAIApp: App {
    @State private var pendingPair: PendingPair?
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.credentials == nil {
                    PairingView()
                } else if model.locked {
                    LockView()
                } else {
                    RootView()
                }
            }
            .environmentObject(model)
            .environmentObject(model.events)
            .onOpenURL { url in
                if url.scheme == "dockai", url.host == "project", let slug = url.pathComponents.dropFirst().first {
                    model.openProject = slug
                    return
                }
                // A pairing link can be opened by anything — a web page, a
                // message — so it never pairs on its own: the person sees the
                // server it names and says yes. A silent switch would hand a
                // look-alike server whatever is typed into the app next.
                if let p = Pairing.parse(url.absoluteString) { pendingPair = PendingPair(server: p.server, code: p.code) }
            }
            .alert("Pair with this server?", isPresented: Binding(get: { pendingPair != nil }, set: { if !$0 { pendingPair = nil } }), presenting: pendingPair) { p in
                Button("Pair") {
                    Task {
                        do { model.signedIn(try await Pairing.pair(server: p.server, code: p.code, deviceName: UIDevice.current.name)) }
                        catch { model.notice = "Pairing failed: \(error.localizedDescription) Codes last ten minutes and work once — make a new one on the web." }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { p in
                Text("\(p.server.host ?? p.server.absoluteString)\n\nOnly pair with your own DockAI. This replaces the server the app is signed in to.")
            }
            .alert("DockAI", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.notice ?? "") }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active { model.foreground() }
            if newPhase == .background, model.faceIDLock { model.locked = true }
        }
    }
}

/// Face ID before the app shows anything, when switched on in Settings.
struct LockView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Button("Unlock") { unlock() }.buttonStyle(.borderedProminent)
        }
        .onAppear { unlock() }
    }
    private func unlock() {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock DockAI") { ok, _ in
            if ok { Task { @MainActor in model.locked = false } }
        }
    }
}


/// A pairing link waiting for the person's yes.
struct PendingPair { let server: URL; let code: String }
