// tRPC: none (WebSocket /api/ws/terminal/<slug>)
import SwiftUI
import UIKit
import SwiftTerm

/// A WebSocket request to one of DockAI's upgrade routes. The server accepts
/// a `dka_` bearer token on the upgrade (`resolveWsUser` in ws-handler.ts),
/// which is what a paired device holds.
func dockaiWebSocketRequest(_ credentials: Credentials, path: String) -> URLRequest {
    var comps = URLComponents(url: credentials.server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    comps.scheme = comps.scheme == "http" ? "ws" : "wss"
    var req = URLRequest(url: comps.url!)
    req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 30
    return req
}

/// One shell tab: a SwiftTerm view and the WebSocket behind it.
///
/// The protocol is the web's (`useTerminalConnection`, ws-handler.ts):
/// - open `/api/ws/terminal/<slug>` and send one text frame
///   `{"type":"init","mode":"shell","sessionName":…,"cols":…,"rows":…}` —
///   the server attaches to the tmux session of that name or creates it at
///   those dimensions, and replays scrollback first;
/// - output arrives as binary frames and is fed to the terminal as-is;
/// - keystrokes go up as binary frames;
/// - `{"type":"resize","cols":…,"rows":…}` as a text frame resizes the PTY.
///
/// A close with 1000/1001/1006 (or a network error) reconnects with the
/// web's backoff (2s × 1.5ⁿ, at most 30s) and re-sends init, which reattaches
/// the same tmux session; the app coming back to the foreground reconnects at
/// once. tmux survives all of it — a socket closing only detaches.
@MainActor
final class TerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
    enum Phase: Equatable { case idle, connecting, live, closed(String) }

    let slug: String
    private(set) var name: String
    let credentials: Credentials
    let host = TerminalHostView()
    let terminal: TerminalView
    @Published private(set) var phase: Phase = .idle
    @Published var ctrlArmed = false { didSet { accessory?.setCtrl(ctrlArmed) } }

    /// Command boundaries from shell integration (OSC 633), to the tab's store.
    var onCommandStart: ((String) -> Void)?
    var onCommandEnd: ((Int?) -> Void)?

    private var task: URLSessionWebSocketTask?
    /// Bumped on every connect and on dispose, so a stale receive loop from
    /// an earlier socket stops instead of acting on the live one.
    private var generation = 0
    private var retryCount = 0
    private var reconnectTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var lastSent: (cols: Int, rows: Int) = (0, 0)
    private var disposed = false
    private var accessory: KeyAccessoryBar?
    private var foregroundObserver: NSObjectProtocol?
    private var pendingCommandRow: Int?

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3600
        return URLSession(configuration: cfg)
    }()

    init(slug: String, name: String, credentials: Credentials) {
        self.slug = slug
        self.name = name
        self.credentials = credentials
        self.terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480),
                                     font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        super.init()
        terminal.terminalDelegate = self
        host.install(terminal)
        host.onFirstLayout = { [weak self] in self?.connectIfNeeded() }
        host.onAppearanceChange = { [weak self] in self?.applyTheme() }
        applyTheme()

        let bar = KeyAccessoryBar(keys: [.esc, .ctrl, .tab, .left, .up, .down, .right,
                                         .text("|"), .text("~"), .text("/"), .text("-"), .paste, .dismiss])
        bar.onKey = { [weak self] key in self?.accessoryKey(key) }
        terminal.inputAccessoryView = bar
        accessory = bar

        installShellIntegration()

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnectIfDown() }
        }
    }

    // MARK: Connection

    /// Connect the first time the pane is on screen with a real size — the
    /// web's rule: a hidden pane would report the default 80 columns and
    /// shrink the tmux window for everyone attached.
    func connectIfNeeded() {
        guard !disposed, task == nil, phase == .idle else { return }
        connect(isReconnect: false)
    }

    private func connect(isReconnect: Bool) {
        guard !disposed else { return }
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        phase = .connecting

        let ws = Self.session.webSocketTask(with: dockaiWebSocketRequest(credentials, path: "api/ws/terminal/\(slug)"))
        // The scrollback replay can be well over URLSession's 1 MB default.
        ws.maximumMessageSize = 16 * 1024 * 1024
        task = ws
        ws.resume()

        let t = terminal.getTerminal()
        let cols = t.cols, rows = t.rows
        lastSent = (cols, rows)
        sendJSON(["type": "init", "mode": "shell", "sessionName": name, "cols": cols, "rows": rows], on: ws)

        if isReconnect {
            // As the web does after a reconnect: Ctrl-L so the prompt repaints.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.generation == gen, let ws = self.task else { return }
                ws.send(.data(Data([0x0c]))) { _ in }
            }
        }

        Task { [weak self] in await self?.receiveLoop(ws, generation: gen) }
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask, generation gen: Int) async {
        while generation == gen {
            do {
                let message = try await ws.receive()
                guard generation == gen else { return }
                if phase != .live { phase = .live; retryCount = 0 }
                switch message {
                case .data(let data):
                    terminal.feed(byteArray: ArraySlice([UInt8](data)))
                case .string(let text):
                    // Control frames the server may send; anything else is output.
                    if let d = text.data(using: .utf8),
                       let obj = try? JSONDecoder().decode(JSON.self, from: d),
                       let type = obj["type"].string,
                       ["session-info", "account-validated", "session-id", "login-url"].contains(type) {
                        continue
                    }
                    terminal.feed(text: text)
                @unknown default:
                    break
                }
            } catch {
                guard generation == gen else { return }
                closed(code: ws.closeCode.rawValue, reason: ws.closeReason.flatMap { String(data: $0, encoding: .utf8) })
                return
            }
        }
    }

    private func closed(code: Int, reason: String?) {
        task = nil
        guard !disposed else { return }
        // 0 is URLSession's "no close frame" — the network went, or the
        // upgrade was refused. The web reconnects on 1000/1001/1006; iOS
        // backgrounding closes cleanly, which is why 1000 is among them.
        if [0, 1000, 1001, 1006].contains(code) {
            scheduleReconnect()
        } else {
            let why = reason.map { $0.isEmpty ? "" : " — \($0)" } ?? ""
            terminal.feed(text: "\r\n\u{1b}[33mDisconnected (\(code))\(why).\u{1b}[0m\r\n")
            phase = .closed("Disconnected (\(code))\(why)")
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        // Four failures in a row with nothing received is a connection that
        // is being refused (no terminal access, a stopped project), not a
        // dropped one: say so and stop, rather than retry for ever in silence
        // (audit 2026-09-26). Retry and coming back to the app start again.
        if retryCount >= 4 {
            terminal.feed(text: "\r\n\u{1b}[33mThe terminal could not be opened. You may not have terminal access to this project, or its worker is not running.\u{1b}[0m\r\n")
            phase = .closed("Could not open the terminal")
            return
        }
        let delay = min(2.0 * pow(1.5, Double(retryCount)), 30)
        retryCount += 1
        terminal.feed(text: "\r\n\u{1b}[33mDisconnected. Reconnecting in \(Int(delay.rounded()))s...\u{1b}[0m\r\n")
        phase = .closed("Reconnecting…")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect(isReconnect: true)
        }
    }

    /// Back from the background, or the Retry button: reconnect now.
    func reconnectIfDown() {
        guard !disposed, phase != .idle, phase != .live || task == nil else { return }
        reconnectTask?.cancel()
        retryCount = 0
        connect(isReconnect: true)
    }

    /// The tab closed or the screen went away. tmux keeps the session.
    func dispose() {
        disposed = true
        generation += 1
        reconnectTask?.cancel()
        resizeTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        if let o = foregroundObserver { NotificationCenter.default.removeObserver(o) }
        foregroundObserver = nil
    }

    /// After `renameTmuxSession` the tab reattaches under its new name.
    func rename(to newName: String) {
        name = newName
        if phase != .idle { retryCount = 0; connect(isReconnect: true) }
    }

    // MARK: Writing

    /// Everything typed goes through here so a sticky Ctrl applies to it.
    func write(_ bytes: [UInt8]) {
        var out = bytes
        if ctrlArmed, out.count == 1 {
            let b = out[0]
            switch b {
            case 0x61...0x7a: out = [b - 0x60]          // a-z → ^A…^Z
            case 0x40...0x5f: out = [b & 0x1f]          // @, A-Z, [ \ ] ^ _
            case 0x20: out = [0x00]                     // Ctrl-Space
            case 0x3f: out = [0x7f]                     // Ctrl-?
            default: break
            }
            ctrlArmed = false
        } else if ctrlArmed {
            ctrlArmed = false
        }
        guard let ws = task else { return }
        ws.send(.data(Data(out))) { _ in }
    }

    /// Type a command and press Enter, as the web's `typeIntoTerminal`.
    func type(_ text: String, enter: Bool = true) {
        guard let ws = task else { return }
        ws.send(.data(Data((text + (enter ? "\r" : "")).utf8))) { _ in }
    }

    private func sendJSON(_ object: [String: Any], on ws: URLSessionWebSocketTask? = nil) {
        guard let target = ws ?? task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        target.send(.string(text)) { _ in }
    }

    private func accessoryKey(_ key: KeyAccessoryBar.Key) {
        let app = terminal.getTerminal().applicationCursor
        switch key {
        case .esc: write([0x1b])
        case .ctrl: ctrlArmed.toggle()
        case .tab: write([0x09])
        case .up: write(Array((app ? "\u{1b}OA" : "\u{1b}[A").utf8))
        case .down: write(Array((app ? "\u{1b}OB" : "\u{1b}[B").utf8))
        case .right: write(Array((app ? "\u{1b}OC" : "\u{1b}[C").utf8))
        case .left: write(Array((app ? "\u{1b}OD" : "\u{1b}[D").utf8))
        case .text(let s): write(Array(s.utf8))
        case .paste: paste()
        case .dismiss: _ = terminal.resignFirstResponder()
        }
    }

    func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        type(text, enter: false)
    }

    func focus() { _ = terminal.becomeFirstResponder() }

    // MARK: Theme

    private func applyTheme() {
        let dark = host.traitCollection.userInterfaceStyle == .dark
        terminal.nativeBackgroundColor = dark ? UIColor(red: 0x0a / 255, green: 0x0a / 255, blue: 0x0a / 255, alpha: 1) : .white
        terminal.nativeForegroundColor = dark ? UIColor(red: 0xe5 / 255, green: 0xe5 / 255, blue: 0xe5 / 255, alpha: 1)
            : UIColor(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1a / 255, alpha: 1)
        host.backgroundColor = terminal.nativeBackgroundColor
    }

    // MARK: Shell integration (OSC 633)

    /// The worker's entrypoint emits VS Code's shell-integration marks
    /// through tmux: `A` prompt start, `B` prompt end, `C` command executed,
    /// `D;<exit>` command finished. As on the web, the command text is read
    /// off the screen at `C` — from the line where the prompt ended, after
    /// the last `$ ` — because the echo in the byte stream carries readline's
    /// own editing.
    private func installShellIntegration() {
        let t = terminal.getTerminal()
        t.registerOscHandler(code: 633) { [weak self] payload in
            let text = String(decoding: payload, as: UTF8.self)
            let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard let code = parts.first else { return }
            // The handler runs during `feed`, on the main thread.
            MainActor.assumeIsolated { self?.shellMark(code, parts: parts) }
        }
    }

    private func shellMark(_ code: String, parts: [String]) {
        let t = terminal.getTerminal()
        switch code {
        case "B":
            pendingCommandRow = t.buffer.yDisp + t.getCursorLocation().y
        case "C":
            guard let start = pendingCommandRow else { return }
            pendingCommandRow = nil
            let cursorRow = t.buffer.yDisp + t.getCursorLocation().y
            // The prompt line, plus any rows the command wrapped onto.
            var line = ""
            var row = start
            while row < max(start + 1, cursorRow), row - start < 8 {
                if let l = t.getLine(row: row - t.buffer.yDisp) { line += l.translateToString(trimRight: true) }
                row += 1
            }
            guard let promptEnd = line.range(of: "$ ", options: .backwards) else { return }
            let command = line[promptEnd.upperBound...].trimmingCharacters(in: .whitespaces)
            if !command.isEmpty { onCommandStart?(command) }
        case "D":
            onCommandEnd?(parts.count > 1 ? Int(parts[1]) : nil)
        default:
            break
        }
    }

    // MARK: TerminalViewDelegate
    //
    // `nonisolated` because SwiftTerm's protocol is not main-actor isolated;
    // it calls every one of these on the main thread, which is what
    // `assumeIsolated` asserts.

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated { write(bytes) }
    }

    /// Resize after the layout settles (500ms), and only
    /// when the size really changed. A pane that is not on screen does not
    /// resize at all, or it would shrink tmux for every other client.
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { scheduleResize(cols: newCols, rows: newRows) }
    }

    private func scheduleResize(cols newCols: Int, rows newRows: Int) {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.host.window != nil, self.host.bounds.width > 0, newCols > 0, newRows > 0 else { return }
            guard newCols != self.lastSent.cols || newRows != self.lastSent.rows, self.phase == .live else { return }
            self.lastSent = (newCols, newRows)
            self.sendJSON(["type": "resize", "cols": newCols, "rows": newRows])
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated { UIPasteboard.general.string = s }
    }
}

/// Holds a TerminalView and says when it first has a real size, so the
/// session connects with the right columns rather than the default 80.
final class TerminalHostView: UIView {
    var onFirstLayout: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    private var laidOut = false

    func install(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !laidOut, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        laidOut = true
        // Next turn, once the terminal has computed its columns from the frame.
        DispatchQueue.main.async { [weak self] in self?.onFirstLayout?() }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { onAppearanceChange?() }
    }
}

/// The session's host view, hosted in SwiftUI. The same UIView instance is
/// re-hosted when the tab comes back, so its scrollback and socket survive
/// switching tabs.
struct TerminalSurface: UIViewRepresentable {
    let session: TerminalSession
    func makeUIView(context: Context) -> TerminalHostView { session.host }
    func updateUIView(_ uiView: TerminalHostView, context: Context) {}
}
