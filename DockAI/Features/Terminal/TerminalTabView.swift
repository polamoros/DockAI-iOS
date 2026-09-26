// tRPC: project.getOpenTabs, project.saveOpenTabs, project.tmuxSessions, project.renameTmuxSession, project.killTmuxSession, project.getPinnedCommands, project.savePinnedCommands, project.getCommandHistory, project.saveCommandHistory
import SwiftUI
import Combine
import SwiftTerm

/// The Terminal tab: shell tabs over one SwiftTerm terminal each, on the same
/// WebSocket and the same tmux sessions as the web's (see TerminalSession).
///
/// Tabs are the web's layout, read from and written back to
/// `project.getOpenTabs` / `saveOpenTabs` (`{tabs:[{id,label,kind}], active}`)
/// so the phone and the browser show the same shells. A shell tab's id *is*
/// its tmux session name (`shell-<base36 ms>`). The web's panel tabs (git,
/// commands, prompts) are kept in the saved layout untouched; here history
/// and pinned commands are a sheet instead.
struct TerminalTabView: View {
    let slug: String
    let project: JSON
    @EnvironmentObject var model: AppModel
    @StateObject private var store = TerminalStore()
    @State private var renaming: TerminalStore.Tab?
    @State private var renameText = ""
    @State private var closing: TerminalStore.Tab?
    @State private var showHistory = false
    @State private var showSessions = false

    private var running: Bool { project["status"].string == "RUNNING" }

    var body: some View {
        Group {
            if !running {
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                    Text("The project is stopped").font(.headline)
                    Text("Start the project to open a terminal.").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.loadError, !store.loaded {
                // The saved layout is unknown, not empty: opening a default
                // shell here would overwrite the tabs we could not read.
                ErrorBanner(error: error, retry: { Task { await store.load() } }).padding()
                Spacer()
            } else if !store.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    tabStrip
                    Divider()
                    pane
                    if store.historyFailed {
                        Text("Command history could not be loaded, so new commands are not being recorded either.")
                            .font(.caption2).foregroundStyle(.orange).padding(.horizontal).padding(.vertical, 4)
                    }
                }
            }
        }
        .task {
            guard running, let api = model.api, let c = model.credentials else { return }
            store.configure(slug: slug, api: api, credentials: c)
            if !store.loaded { await store.load() } else { store.ensureActiveSession() }
        }
        .onDisappear { store.suspend() }
        .sheet(isPresented: $showHistory) {
            CommandHistorySheet(store: store) { cmd in
                showHistory = false
                store.activeSession?.type(cmd)
            }
        }
        .sheet(isPresented: $showSessions) {
            TmuxSessionsSheet(store: store, open: { name in
                showSessions = false
                store.openShell(id: name)
            })
        }
        .alert("Rename terminal", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let tab = renaming { store.rename(tab, to: renameText) }
                renaming = nil
            }
        } message: { Text("Letters, digits, - and _. The tmux session is renamed too.") }
        .confirmationDialog("End terminal?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            Button("End terminal", role: .destructive) {
                if let tab = closing { store.close(tab) }
                closing = nil
            }
        } message: { Text("Closing a shell ends its tmux session and whatever is running in it.") }
        .errorAlert(store.action)
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.shellTabs) { tab in
                            tabButton(tab).id(tab.id)
                        }
                        Button { store.openShell() } label: {
                            Image(systemName: "plus").padding(8)
                        }
                        .accessibilityLabel("New shell")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .onChange(of: store.active) { _, id in withAnimation { proxy.scrollTo(id) } }
            }
            Menu {
                Button { showHistory = true } label: { Label("History & pinned", systemImage: "clock.arrow.circlepath") }
                Button { showSessions = true } label: { Label("Terminals in the worker", systemImage: "list.bullet.rectangle") }
                if let s = store.activeSession {
                    Button { s.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    Button { s.reconnectIfDown() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").padding(8)
            }
            .accessibilityLabel("Terminal options")
        }
    }

    private func tabButton(_ tab: TerminalStore.Tab) -> some View {
        let selected = tab.id == store.active
        return Button {
            if selected { store.activeSession?.focus() } else { store.active = tab.id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.caption)
                Text(tab.label).font(.subheadline).lineLimit(1)
                if selected, let s = store.sessions[tab.id] { PhaseDot(session: s) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? SwiftUI.Color.accentColor.opacity(0.15) : SwiftUI.Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { renameText = tab.id; renaming = tab } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { closing = tab } label: { Label("Close", systemImage: "xmark") }
        }
        .accessibilityHint("Touch and hold to rename or close")
    }

    // MARK: Pane

    @ViewBuilder private var pane: some View {
        if let session = store.activeSession {
            SessionPane(session: session).id(session.name)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                Text("No open tabs").font(.headline)
                Button("Open a shell") { store.openShell() }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One shell's terminal, with its connection state over it.
private struct SessionPane: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        ZStack(alignment: .top) {
            TerminalSurface(session: session)
            if case .closed(let why) = session.phase, why != "Reconnecting…" {
                HStack {
                    Text(why).font(.caption)
                    Spacer()
                    Button("Reconnect") { session.reconnectIfDown() }.font(.caption)
                }
                .padding(8)
                .background(.orange.opacity(0.15))
            }
            if session.phase == .connecting || session.phase == .idle {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…").font(.caption) }
                    .padding(6).background(.thinMaterial, in: Capsule()).padding(.top, 8)
            }
        }
    }
}

private struct PhaseDot: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        Circle().frame(width: 6, height: 6).foregroundStyle(color)
    }
    private var color: SwiftUI.Color {
        switch session.phase {
        case .live: .green
        case .connecting, .idle: .orange
        case .closed: .red
        }
    }
}

// MARK: - Store

/// The tabs, their sessions, command history and pinned commands.
@MainActor
final class TerminalStore: ObservableObject {
    struct Tab: Identifiable, Equatable {
        var id: String
        var label: String
        var kind: String
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var active = "" { didSet { if oldValue != active { ensureActiveSession(); schedulePersist() } } }
    @Published private(set) var sessions: [String: TerminalSession] = [:]
    @Published private(set) var loaded = false
    @Published private(set) var loadError: Error?
    @Published private(set) var history: [JSON] = []
    @Published private(set) var historyLoaded = false
    @Published private(set) var historyFailed = false
    @Published private(set) var pinned: [String] = []
    @Published private(set) var tmux: [JSON] = []
    let action = Action()

    private var slug = ""
    private var api: TRPCClient?
    private var credentials: Credentials?
    private var persistTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var actionForward: AnyCancellable?

    init() {
        // The view observes the store; the store's Action has to say when
        // its error changes, or the error alert never shows.
        actionForward = action.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var shellTabs: [Tab] { tabs.filter { $0.kind == "shell" } }
    var activeSession: TerminalSession? {
        guard shellTabs.contains(where: { $0.id == active }) else { return nil }
        return sessions[active]
    }

    func configure(slug: String, api: TRPCClient, credentials: Credentials) {
        self.slug = slug
        self.api = api
        self.credentials = credentials
    }

    func load() async {
        guard let api else { return }
        do {
            let saved = try await api.query("project.getOpenTabs", .from(["slug": slug]))
            var restored: [Tab] = []
            for t in saved["tabs"].array {
                guard let id = t["id"].string, let label = t["label"].string, let kind = t["kind"].string,
                      ["shell", "git", "commands", "prompts"].contains(kind) else { continue }
                restored.append(Tab(id: id, label: label, kind: kind))
            }
            tabs = restored
            loadError = nil
            loaded = true
            if restored.contains(where: { $0.kind == "shell" }) {
                let a = saved["active"].string ?? ""
                active = restored.contains(where: { $0.id == a && $0.kind == "shell" }) ? a : (restored.first { $0.kind == "shell" }?.id ?? "")
            } else {
                openShell()
            }
        } catch {
            loadError = error
        }
        async let h: Void = loadHistory()
        async let p: Void = loadPinned()
        _ = await (h, p)
    }

    func loadHistory() async {
        guard let api else { return }
        do {
            history = try await api.query("project.getCommandHistory", .from(["slug": slug])).array
            historyLoaded = true
            historyFailed = false
        } catch {
            historyFailed = !historyLoaded
        }
    }

    func loadPinned() async {
        guard let api else { return }
        if let p = try? await api.query("project.getPinnedCommands", .from(["slug": slug])) {
            pinned = p.array.compactMap(\.string)
        }
    }

    func loadTmux() async {
        guard let api else { return }
        do { tmux = try await api.query("project.tmuxSessions", .from(["slug": slug])).array }
        catch { action.error = error }
    }

    // MARK: Sessions

    /// A session is made when its tab is first shown and connects once it
    /// is laid out — tabs never looked at cost nothing, as on the web.
    func ensureActiveSession() {
        guard sessions[active] == nil, shellTabs.contains(where: { $0.id == active }), let credentials else { return }
        let s = TerminalSession(slug: slug, name: active, credentials: credentials)
        s.onCommandStart = { [weak self] cmd in self?.commandStarted(cmd) }
        s.onCommandEnd = { [weak self] code in self?.commandEnded(code) }
        sessions[active] = s
    }

    /// The Terminal tab went away: drop the sockets, keep tmux.
    func suspend() {
        persistNow()
        for s in sessions.values { s.dispose() }
        sessions = [:]
    }

    // MARK: Tab operations

    func openShell(id: String? = nil) {
        let shellId = id ?? "shell-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))"
        if !tabs.contains(where: { $0.id == shellId }) {
            let index = shellTabs.count
            let label = shellId == "shell-quickcmd" ? "Quick commands" : (index == 0 ? "Shell" : "Shell \(index + 1)")
            tabs.append(Tab(id: shellId, label: id != nil && !shellId.hasPrefix("shell-") ? shellId : label, kind: "shell"))
        }
        active = shellId
        ensureActiveSession()
        schedulePersist()
    }

    /// Closing a shell ends its tmux session — as on the web.
    func close(_ tab: Tab) {
        let next = tabs.filter { $0.id != tab.id }
        sessions[tab.id]?.dispose()
        sessions[tab.id] = nil
        tabs = next
        if active == tab.id { active = next.last(where: { $0.kind == "shell" })?.id ?? "" }
        schedulePersist()
        guard let api else { return }
        let slug = self.slug
        action.run {
            _ = try await api.mutate("project.killTmuxSession", .from(["slug": slug, "sessionName": tab.id]))
        }
    }

    /// Renames the tmux session; the tab's id follows it, since it is the name.
    func rename(_ tab: Tab, to newName: String) {
        let wanted = newName.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, wanted != tab.id, let api else { return }
        let slug = self.slug
        action.run { [weak self] in
            let r = try await api.mutate("project.renameTmuxSession", .from(["slug": slug, "oldName": tab.id, "newName": wanted]))
            guard let self, let name = r["name"].string else { return }
            if let i = self.tabs.firstIndex(where: { $0.id == tab.id }) {
                self.tabs[i].id = name
                self.tabs[i].label = name
            }
            if let s = self.sessions[tab.id] {
                self.sessions[tab.id] = nil
                self.sessions[name] = s
                s.rename(to: name)
            }
            if self.active == tab.id { self.active = name }
            self.schedulePersist()
        }
    }

    // MARK: Persistence

    private func schedulePersist() {
        guard loaded else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        guard loaded, !tabs.isEmpty, let api else { return }
        let payload: JSON = .object([
            "slug": .string(slug),
            "tabs": .array(tabs.map { .object(["id": .string($0.id), "label": .string($0.label), "kind": .string($0.kind)]) }),
            "active": .string(active),
        ])
        let action = self.action
        action.run { _ = try await api.mutate("project.saveOpenTabs", payload) }
    }

    // MARK: Command history (OSC 633)

    private func commandStarted(_ command: String) {
        var list = history
        list.append(.from(["command": command, "startTime": Date().timeIntervalSince1970 * 1000]))
        history = Array(list.suffix(100))
        persistHistory()
    }

    private func commandEnded(_ exit: Int?) {
        guard var last = history.last, last["endTime"].isNull else { return }
        var o = last.object
        o["endTime"] = .number(Date().timeIntervalSince1970 * 1000)
        if let exit { o["exitCode"] = .number(Double(exit)) }
        last = .object(o)
        history[history.count - 1] = last
        persistHistory()
    }

    /// Debounced 2s, last 100 — and never before the stored list has been
    /// read, or the first command would be written over the whole history.
    private func persistHistory() {
        guard historyLoaded, let api else { return }
        historyTask?.cancel()
        let slug = self.slug
        historyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let cmds = self.history.suffix(100).map { c -> JSON in
                var o: [String: JSON] = ["command": c["command"], "startTime": c["startTime"]]
                if !c["exitCode"].isNull { o["exitCode"] = c["exitCode"] }
                if !c["endTime"].isNull { o["endTime"] = c["endTime"] }
                return .object(o)
            }
            _ = try? await api.mutate("project.saveCommandHistory", .object(["slug": .string(slug), "commands": .array(Array(cmds))]))
        }
    }

    func clearHistory() {
        guard let api else { return }
        let slug = self.slug
        action.run { [weak self] in
            _ = try await api.mutate("project.saveCommandHistory", .object(["slug": .string(slug), "commands": .array([])]))
            self?.history = []
        }
    }

    func togglePin(_ command: String) {
        let next = pinned.contains(command) ? pinned.filter { $0 != command } : pinned + [command]
        savePinned(next)
    }

    func savePinned(_ next: [String]) {
        guard let api else { return }
        let slug = self.slug
        let previous = pinned
        pinned = next
        action.run { [weak self] in
            do {
                _ = try await api.mutate("project.savePinnedCommands", .object(["slug": .string(slug), "commands": .array(next.map { .string($0) })]))
            } catch {
                self?.pinned = previous
                throw error
            }
        }
    }

    func killTmux(_ name: String) {
        guard let api else { return }
        let slug = self.slug
        action.run { [weak self] in
            _ = try await api.mutate("project.killTmuxSession", .from(["slug": slug, "sessionName": name]))
            if let self, let tab = self.tabs.first(where: { $0.id == name }) {
                self.sessions[name]?.dispose()
                self.sessions[name] = nil
                self.tabs.removeAll { $0.id == name }
                if self.active == tab.id { self.active = self.shellTabs.last?.id ?? "" }
                self.schedulePersist()
            }
            await self?.loadTmux()
        }
    }
}

// MARK: - History sheet

/// Pinned commands and the command history, as the web's CommandHistoryPanel:
/// tap to run in the active shell, pin or unpin, clear.
private struct CommandHistorySheet: View {
    @ObservedObject var store: TerminalStore
    let run: (String) -> Void
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section("Pinned") {
                    if store.pinned.isEmpty {
                        Text("Pin a command from the history below to keep it here.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.pinned, id: \.self) { cmd in
                        Button { run(cmd) } label: {
                            Label { Text(cmd).font(.callout.monospaced()).lineLimit(2) } icon: { Image(systemName: "pin.fill") }
                        }
                        .swipeActions { Button("Unpin", role: .destructive) { store.togglePin(cmd) } }
                    }
                    .onMove { from, to in
                        var next = store.pinned
                        next.move(fromOffsets: from, toOffset: to)
                        store.savePinned(next)
                    }
                }
                Section("History") {
                    if store.historyFailed {
                        Text("Command history could not be loaded.").font(.footnote).foregroundStyle(.orange)
                    } else if store.history.isEmpty {
                        Text("No commands tracked yet").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(store.history.reversed().enumerated()), id: \.offset) { _, c in
                        let cmd = c["command"].string ?? ""
                        Button { run(cmd) } label: { HistoryRow(entry: c) }
                            .swipeActions(edge: .leading) {
                                Button(store.pinned.contains(cmd) ? "Unpin" : "Pin") { store.togglePin(cmd) }.tint(.accentColor)
                            }
                            .contextMenu {
                                Button { run(cmd) } label: { Label("Run", systemImage: "play") }
                                Button { store.togglePin(cmd) } label: {
                                    Label(store.pinned.contains(cmd) ? "Unpin" : "Pin", systemImage: store.pinned.contains(cmd) ? "pin.slash" : "pin")
                                }
                                Button { UIPasteboard.general.string = cmd } label: { Label("Copy", systemImage: "doc.on.doc") }
                            }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.history.isEmpty {
                        Button("Clear", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Clear the command history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { store.clearHistory() }
            }
            .refreshable { await store.loadHistory(); await store.loadPinned() }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct HistoryRow: View {
    let entry: JSON
    var body: some View {
        let start = entry["startTime"].double ?? 0
        let end = entry["endTime"].double
        let exit = entry["exitCode"].int
        VStack(alignment: .leading, spacing: 2) {
            Text(entry["command"].string ?? "").font(.callout.monospaced()).foregroundStyle(.primary).lineLimit(3)
            HStack(spacing: 6) {
                if end == nil {
                    Image(systemName: "clock").foregroundStyle(.orange)
                } else {
                    Image(systemName: exit == 0 ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(exit == 0 ? .green : .red)
                }
                Text(Date(timeIntervalSince1970: start / 1000), format: .dateTime.hour().minute().second())
                Text(end.map { formatElapsed(start, $0) } ?? "Running")
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - tmux sessions sheet

/// Every tmux session in the worker (`project.tmuxSessions`): open one as a
/// tab, or end it — the web's Settings → Terminals list.
private struct TmuxSessionsSheet: View {
    @ObservedObject var store: TerminalStore
    let open: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if store.tmux.isEmpty {
                    Text("No terminals are running.").foregroundStyle(.secondary)
                }
                ForEach(sorted, id: \.self) { s in
                    let name = s["name"].string ?? ""
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.callout.monospaced())
                            HStack(spacing: 6) {
                                StatePill(text: s["attached"].bool == true ? "Connected" : "Background", tone: s["attached"].bool == true ? .ok : .neutral)
                                if let created = s["createdAt"].double, created > 0 {
                                    Text(Date(timeIntervalSince1970: created / 1000).relative).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Button("Open") { open(name) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .swipeActions {
                        Button("End", role: .destructive) { store.killTmux(name) }
                    }
                }
            }
            .navigationTitle("Terminals")
            .navigationBarTitleDisplayMode(.inline)
            .task { await store.loadTmux() }
            .refreshable { await store.loadTmux() }
        }
        .presentationDetents([.medium, .large])
    }

    private var sorted: [JSON] {
        store.tmux.sorted { a, b in
            let aa = a["attached"].bool == true, ba = b["attached"].bool == true
            if aa != ba { return aa }
            return (a["name"].string ?? "") < (b["name"].string ?? "")
        }
    }
}
