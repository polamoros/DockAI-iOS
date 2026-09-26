// tRPC: (none — WebSocket /api/ws/auth/<accountId>, the web's AuthTerminalModal protocol)
import SwiftUI
import SwiftTerm
import UIKit

/// Interactive `claude auth login` for one account, as the web's
/// AuthTerminalModal runs it: the server starts the login in a throwaway
/// container under tmux, sends the sign-in link as a `{type:"login-url"}`
/// text frame and the terminal as binary frames, and closes 1000 once new
/// credentials are saved (4000: the login ended and saved nothing). Any
/// other close is the socket going away — on a phone, every trip to the
/// browser — and the login is still waiting, so the sheet reconnects when
/// the app is active again. The terminal is kept, folded, because when this
/// goes wrong its output is the only thing that says why.
struct ClaudeSignInSheet: View {
    let accountId: String
    let onLinked: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = ClaudeSignInSession()
    @State private var code = ""
    @State private var showTerminal = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                if session.phase == .done {
                    Section {
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("The credentials are saved on the account; its projects pick them up.").font(.callout)
                    }
                } else {
                    Section("1. Approve in your browser") {
                        if let url = session.loginURL {
                            Button { openURL(url) } label: { Label("Open the login page", systemImage: "safari") }
                                .buttonStyle(.borderedProminent)
                            HStack {
                                Text(url.absoluteString).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Button {
                                    UIPasteboard.general.string = url.absoluteString
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                                    .buttonStyle(.borderless).accessibilityLabel(copied ? "Copied" : "Copy link")
                            }
                        } else {
                            HStack(spacing: 8) { ProgressView(); Text("Waiting for the sign-in link…").font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                    Section {
                        TextField("Paste the code here", text: $code)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.send)
                            .onSubmit(submit)
                        HStack {
                            PasteButton(payloadType: String.self) { strings in
                                if let s = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                                    Task { @MainActor in code = s }
                                }
                            }
                            .labelStyle(.titleAndIcon).buttonBorderShape(.capsule)
                            Spacer()
                            Button("Submit", action: submit)
                                .buttonStyle(.bordered)
                                .disabled(session.phase != .live || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } header: {
                        Text("2. Paste the code you get back")
                    } footer: {
                        Text("You can leave to sign in and come back — the sign-in waits for you.")
                    }
                    statusSection
                }
                Section {
                    DisclosureGroup("Terminal", isExpanded: $showTerminal) {
                        SignInTerminal(view: session.terminal)
                            .frame(height: 280)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .navigationTitle("Sign in to Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session.phase == .done ? "Done" : "Close") { dismiss() }
                }
            }
        }
        .onAppear {
            guard let c = model.credentials else { return }
            session.onLinked = onLinked
            session.start(credentials: c, accountId: accountId)
        }
        // Closing only detaches: the server keeps a waiting login for twenty
        // minutes, so opening this again resumes it.
        .onDisappear { session.stop() }
        .onChange(of: phase) { _, p in if p == .active { session.foreground() } }
    }

    @ViewBuilder private var statusSection: some View {
        switch session.phase {
        case .connecting:
            Section { HStack(spacing: 8) { ProgressView(); Text("Starting a sign-in session…").font(.callout) } }
        case .reconnecting:
            Section { HStack(spacing: 8) { ProgressView(); Text("Reconnecting to the sign-in…").font(.callout) } }
        case .ended:
            Section {
                Text("The login ended without signing in, so nothing was saved.").font(.callout)
                Button("Sign in again") { code = ""; session.restart() }
            }
        case .error:
            Section {
                Text("The sign-in session ended without completing. Close this and try again.").font(.callout).foregroundStyle(.orange)
            }
        case .live, .done:
            EmptyView()
        }
    }

    private func submit() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, session.phase == .live else { return }
        session.submitCode(value)
        code = ""
    }
}

/// The socket and the terminal it draws into; one per sheet.
@MainActor
final class ClaudeSignInSession: ObservableObject {
    enum Phase { case connecting, live, reconnecting, done, ended, error }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var loginURL: URL?
    var onLinked: (() -> Void)?

    let terminal: TerminalView
    private let bridge = SignInTerminalBridge()
    private let urlSession = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var credentials: Credentials?
    private var accountId = ""
    /// Bumped on every new socket and on stop, so a stale socket's callbacks are ignored.
    private var generation = 0
    private var retries = 0
    private var stopped = false
    private var retryWork: Task<Void, Never>?

    init() {
        terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 360, height: 280),
                                font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular))
        terminal.terminalDelegate = bridge
        bridge.owner = self
    }

    func start(credentials: Credentials, accountId: String) {
        guard task == nil else { return }
        self.credentials = credentials
        self.accountId = accountId
        stopped = false
        connect()
    }

    /// "Sign in again" after a login that ended unsigned: a new login.
    func restart() {
        loginURL = nil
        retries = 0
        phase = .connecting
        connect()
    }

    func stop() {
        stopped = true
        generation += 1
        retryWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Back from the browser: rejoin the waiting login at once.
    func foreground() {
        guard !stopped, phase == .reconnecting || phase == .connecting else { return }
        if task == nil || task?.state != .running {
            retryWork?.cancel()
            connect()
        }
    }

    /// The code, then Enter on its own: the CLI's prompt reads raw stdin and a
    /// code-plus-newline chunk can be consumed before its input has settled.
    func submitCode(_ value: String) {
        guard let task else { return }
        task.send(.string(value)) { _ in }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000)
            task.send(.string("\r")) { _ in }
        }
    }

    // MARK: Socket

    private func connect() {
        guard let credentials, !stopped else { return }
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        terminal.getTerminal().resetToInitialState()

        var comps = URLComponents(url: credentials.server.appendingPathComponent("api/ws/auth/\(accountId)"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let t = urlSession.webSocketTask(with: req)
        task = t
        t.resume()
        // The first answer to a ping is the socket being open.
        t.sendPing { [weak self] err in
            Task { @MainActor in
                guard let self, gen == self.generation, err == nil else { return }
                self.opened()
            }
        }
        sendResize()
        receive(t, gen: gen)
    }

    private func opened() {
        retries = 0
        if phase != .done { phase = .live }
        sendResize()
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    if self.phase == .connecting || self.phase == .reconnecting { self.opened() }
                    self.handle(message)
                    self.receive(t, gen: gen)
                case .failure:
                    await self.closed(t, gen: gen)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let s):
            // The link travels as its own text frame; terminal output is binary.
            if s.hasPrefix("{"), let data = s.data(using: .utf8),
               let json = try? JSONDecoder().decode(JSON.self, from: data),
               json["type"].string == "login-url", let u = json["url"].string, let url = URL(string: u) {
                loginURL = url
                return
            }
            terminal.feed(text: s)
        case .data(let d):
            terminal.feed(byteArray: ArraySlice([UInt8](d)))
        @unknown default:
            break
        }
    }

    private func closed(_ t: URLSessionWebSocketTask, gen: Int) async {
        // The close code can land a moment after the failed receive.
        var code = t.closeCode.rawValue
        if code == 0 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            code = t.closeCode.rawValue
        }
        guard gen == generation else { return }
        task = nil
        if code == 1000 {
            phase = .done
            onLinked?()
            return
        }
        if code == 4000 { phase = .ended; return }
        if stopped { return }
        if retries >= 12 { phase = .error; return }
        phase = .reconnecting
        // Right away when the person is looking, with a growing pause so a
        // server that is down is not hammered; in the background, on return.
        guard UIApplication.shared.applicationState == .active else { return }
        let delay = min(pow(2.0, Double(retries)), 15)
        retries += 1
        retryWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.stopped, self.phase == .reconnecting else { return }
            self.connect()
        }
    }

    // MARK: Terminal → socket

    fileprivate func sendInput(_ data: ArraySlice<UInt8>) {
        guard let task, phase == .live else { return }
        task.send(.data(Data(data))) { _ in }
    }

    fileprivate func sendResize() {
        guard let task else { return }
        let t = terminal.getTerminal()
        let msg = "{\"type\":\"resize\",\"cols\":\(t.cols),\"rows\":\(t.rows)}"
        task.send(.string(msg)) { _ in }
    }
}

/// SwiftTerm's delegate, kept apart from the main-actor session.
final class SignInTerminalBridge: NSObject, TerminalViewDelegate {
    weak var owner: ClaudeSignInSession?

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { () -> Void in owner?.sendInput(data) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { () -> Void in owner?.sendResize() }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The session's one TerminalView, so folding the terminal away keeps its output.
struct SignInTerminal: UIViewRepresentable {
    let view: TerminalView
    func makeUIView(context: Context) -> TerminalView { view }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
}
