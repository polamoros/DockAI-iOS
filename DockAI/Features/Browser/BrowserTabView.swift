// tRPC: project.browserStatus, project.browserStart, project.browserStop, project.browserSize
import SwiftUI

/// The Browser tab: the project's one Chromium, on screen.
///
/// The same browser the agent drives over CDP, so a site signed into here is
/// a site the agent is signed into. The screen is RFB over
/// `/api/ws/browser/<slug>` (RFBClient), which authenticates — it is
/// deliberately not an exposed-service subdomain.
///
/// The remote display is a fixed 1280×800 unless someone asks otherwise:
/// it is shared with the agent, so opening the viewer or rotating the phone
/// must not resize the browser under a run. The viewer adapts instead — Fit
/// or Zoom, full screen, and an explicit "Phone size" that reshapes the
/// display on purpose (`project.browserSize`).
struct BrowserTabView: View {
    let slug: String
    let project: JSON
    @EnvironmentObject var model: AppModel
    @StateObject private var client = RFBClient()
    @StateObject private var action = Action()
    @State private var status: JSON?
    @State private var statusError: Error?
    @State private var zoomed = false
    @State private var immersive = false
    @State private var keyboardRequest = 0
    @State private var keyboardRequestFull = 0
    @State private var fullScreenSize: CGSize = .zero
    @State private var showHowTo = false

    private static let desktop = (width: 1280, height: 800)

    private var projectRunning: Bool { project["status"].string == "RUNNING" }
    private var running: Bool { status?["running"].bool ?? false }
    /// Chromium and the screen server are separate processes; the viewer
    /// needs the second. An older worker reports no `vnc` at all, and absent
    /// means "assume yes".
    private var viewable: Bool { running && status?["vnc"].bool != false }
    private var matchesDesktop: Bool { status?["screen"].string == "\(Self.desktop.width)x\(Self.desktop.height)" }

    var body: some View {
        Group {
            if !projectRunning {
                emptyState(icon: "globe", title: "The project is stopped", detail: "Start the project to open its browser.", action: nil)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        heading
                        if status == nil, let statusError {
                            ErrorBanner(error: statusError, retry: { Task { await loadStatus() } })
                        } else if status == nil {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                        } else if viewable {
                            viewer(immersive: false)
                                .aspectRatio(aspect, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            emptyState(
                                icon: "globe",
                                title: running ? "The screen is not up yet" : "The browser is not running",
                                detail: running ? "Chromium is up but its screen server is not answering; restart the browser."
                                    : "Start it to sign into the sites the agent needs; those logins persist.",
                                action: (running ? "Restart browser" : "Start browser", start))
                        }
                        Text("Anything you sign into here, the agent can act as. Its settings are in Settings → Browser.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .task(id: slug) { await pollStatus() }
            }
        }
        .onChange(of: viewable) { _, isViewable in
            if !isViewable { client.disconnect() }
        }
        // A full-screen cover takes this view off screen too; the
        // connection belongs to both, so only leaving the tab drops it.
        .onDisappear { if !immersive { client.disconnect() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // A backgrounded app loses the socket; come back by itself, but
            // only from a lost connection, never over a working one.
            if viewable && client.phase == .lost { connect() }
        }
        .fullScreenCover(isPresented: $immersive) {
            viewer(immersive: true)
                .background(Color.black.ignoresSafeArea())
        }
        .errorAlert(action)
    }

    private var aspect: CGFloat {
        client.size.width > 0 && client.size.height > 0 ? client.size.width / client.size.height : 8.0 / 5.0
    }

    // MARK: Heading

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Browser").font(.headline)
                    Button { showHowTo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("How to use")
                        .popover(isPresented: $showHowTo) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sign into a site here and the agent is signed in too.")
                                Text("Fit shows the whole screen; Zoom shows it full size. Pinch and drag with two fingers to move around.")
                                Text("Tap to click, touch and hold then drag to select, drag with one finger to scroll the page, tap with two fingers to right-click.")
                                Text("Phone size reshapes the display and goes full screen.")
                            }
                            .font(.callout).padding().frame(idealWidth: 320)
                            .presentationCompactAdaptation(.popover)
                        }
                }
                Text("One browser for this project, shared with the agent.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            // Stop only: while stopped, the panel below carries Start with
            // the sentence that explains it.
            if running {
                Button("Stop browser") {
                    action.run {
                        guard let api = model.api else { return }
                        _ = try await api.mutate("project.browserStop", .from(["slug": slug]))
                        await loadStatus()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(action.busy)
            }
        }
    }

    // MARK: Viewer

    @ViewBuilder private func viewer(immersive full: Bool) -> some View {
        VStack(spacing: 0) {
            browserToolbar(immersive: full)
            ZStack {
                GeometryReader { geo in
                    RFBScreen(client: client, zoomed: zoomed, keyboardRequest: full ? $keyboardRequestFull : $keyboardRequest)
                        .onAppear { if full { fullScreenSize = geo.size } }
                        .onChange(of: geo.size) { _, s in if full { fullScreenSize = s } }
                }
                if client.phase != .live { overlay }
            }
        }
        .background(Color.black)
    }

    private func browserToolbar(immersive full: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().frame(width: 7, height: 7).foregroundStyle(dotColor)
            Text(statusLine).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            toolbarButton(zoomed ? "Fit" : "Zoom", icon: zoomed ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass") {
                zoomed.toggle()
            }
            toolbarButton(matchesDesktop ? "Phone size" : "Desktop size", icon: matchesDesktop ? "iphone" : "desktopcomputer") {
                if matchesDesktop { fitDisplayToPhone() } else { resize(width: Self.desktop.width, height: Self.desktop.height) }
            }
            .disabled(action.busy)
            if client.phase == .live {
                toolbarButton("Paste", icon: "doc.on.clipboard") {
                    guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                    Task { await client.pasteTyping(text) }
                }
                toolbarButton("Keyboard", icon: "keyboard") { if full { keyboardRequestFull += 1 } else { keyboardRequest += 1 } }
            }
            toolbarButton(full ? "Exit full screen" : "Full screen", icon: full ? "arrow.down.right.and.arrow.up.left.rectangle" : "arrow.up.left.and.arrow.down.right.rectangle") {
                immersive = !full
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.bar)
    }

    private func toolbarButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 32, height: 32) }
            .accessibilityLabel(label)
            .help(label)
    }

    private var overlay: some View {
        VStack(spacing: 8) {
            if client.phase == .connecting || client.phase == .idle {
                ProgressView()
                Text("Connecting…").font(.subheadline.weight(.medium))
            } else {
                Image(systemName: "display.trianglebadge.exclamationmark").font(.title2).foregroundStyle(.secondary)
                Text("Disconnected").font(.subheadline.weight(.medium))
                if let error = client.error { Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                Button { connect() } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var dotColor: Color {
        switch client.phase { case .live: .green; case .connecting, .idle: .orange; case .lost: .red }
    }

    private var statusLine: String {
        switch client.phase {
        case .live:
            let parts = [status?["browser"].string, status?["screen"].string?.replacingOccurrences(of: "x", with: "×")].compactMap { $0 }
            return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
        case .connecting, .idle: return "Connecting…"
        case .lost: return "Disconnected"
        }
    }

    // MARK: Actions

    private func connect() {
        guard let c = model.credentials else { return }
        client.connect(credentials: c, slug: slug)
    }

    private var start: () -> Void {
        {
            action.run {
                guard let api = model.api else { return }
                _ = try await api.mutate("project.browserStart", .from(["slug": slug]))
                await loadStatus()
            }
        }
    }

    /// Reshape the display to this phone's full-screen viewer, no narrower
    /// than the browser's own minimum window (the server reports it).
    private func fitDisplayToPhone() {
        let wasImmersive = immersive
        immersive = true
        action.run {
            if !wasImmersive { try? await Task.sleep(nanoseconds: 600_000_000) }
            var w = Int(fullScreenSize.width.rounded()), h = Int(fullScreenSize.height.rounded())
            guard w > 0, h > 0 else { return }
            let minimum = status?["minWidth"].int ?? 508
            if w < minimum {
                h = Int((Double(h) * Double(minimum) / Double(w)).rounded())
                w = minimum
            }
            try await applySize(width: w, height: h)
        }
    }

    private func resize(width: Int, height: Int) {
        action.run { try await applySize(width: width, height: height) }
    }

    private func applySize(width: Int, height: Int) async throws {
        guard let api = model.api else { return }
        _ = try await api.mutate("project.browserSize", .from(["slug": slug, "width": min(width, 4096), "height": min(height, 4096)]))
        zoomed = false
        await loadStatus()
        connect()
    }

    // MARK: Status

    private func pollStatus() async {
        while !Task.isCancelled {
            await loadStatus()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func loadStatus() async {
        guard let api = model.api else { return }
        do {
            let s = try await api.query("project.browserStatus", .from(["slug": slug]))
            let wasViewable = viewable
            status = s
            statusError = nil
            if viewable && (!wasViewable || client.phase == .idle) { connect() }
        } catch {
            statusError = error
        }
    }

    private func emptyState(icon: String, title: String, detail: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.borderedProminent).disabled(self.action.busy)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding()
    }
}
