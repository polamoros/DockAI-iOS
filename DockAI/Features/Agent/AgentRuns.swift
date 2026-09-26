// tRPC: agentRun.list, agentRun.get, agentRun.start, agentRun.cancel
import SwiftUI

/// The runs (`RunsList` in `AgentTab.tsx`): one row per run whose prompt (or
/// label) wraps to two lines, over its state, when it started and how long it
/// took. New run opens the composer.
struct AgentRunsList: View {
    let projectId: String
    let access: AgentAccess
    var onCount: (Int) -> Void = { _ in }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var events: EventStream
    @State private var runs: [JSON]?
    @State private var loadError: Error?
    @State private var openRun: String?
    @State private var composing = false
    @State private var subscription: UUID?

    var body: some View {
        Group {
            if let runs {
                if runs.isEmpty {
                    ContentUnavailableView {
                        Label("No runs yet.", systemImage: "cpu")
                    } description: {
                        Text("Start one and it runs headless against this workspace.")
                    } actions: {
                        Button { composing = true } label: { Label("New run", systemImage: "plus") }
                            .buttonStyle(.bordered)
                    }
                } else {
                    List {
                        Section {
                            ForEach(runs, id: \.self) { run in
                                Button { openRun = run["id"].string } label: { AgentRunRow(run: run) }
                                    .buttonStyle(.plain)
                            }
                        } footer: {
                            Text("A run is one prompt the agent works through on its own, starting the project first.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            } else if let loadError {
                VStack {
                    ErrorBanner(error: loadError, retry: { Task { await load() } }).padding()
                    Spacer()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { composing = true } label: { Label("New run", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $composing) {
            NavigationStack {
                AgentComposer(projectId: projectId, access: access) { runId in
                    composing = false
                    openRun = runId
                    Task { await load() }
                }
                .padding()
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("New run")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { composing = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(item: $openRun) { id in
            AgentRunDetail(projectId: projectId, initialRunId: id, access: access)
        }
        .task { await load() }
        .onAppear {
            // Runs that start or end elsewhere (an automation, Telegram) show
            // up without pulling to refresh.
            subscription = events.on { event in
                guard event["projectId"].string == projectId else { return }
                if event["type"].string == "agentRun:end" { Task { await load() } }
            }
        }
        .onDisappear { if let subscription { events.off(subscription) } }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list = try await api.query("agentRun.list", .from(["projectId": projectId, "limit": 50])).array
            runs = list
            loadError = nil
            onCount(list.count)
        } catch {
            loadError = error
        }
    }
}

struct AgentRunRow: View {
    let run: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run["label"].string ?? run["prompt"].string ?? "")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                AgentRunStatusPill(status: run["status"].string ?? "")
                Text(AgentFormat.dateTime(run["createdAt"].date))
                if let took = AgentFormat.elapsed(run["startedAt"].date, run["finishedAt"].date) { Text(took) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// The prompt box — the tab's one "New run". Disabled, with the reason, when
/// the project has no account or no token.
struct AgentComposer: View {
    let projectId: String
    let access: AgentAccess
    let onStarted: (String) -> Void

    @EnvironmentObject var model: AppModel
    @State private var prompt = ""
    @State private var starting = false
    @State private var error: Error?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = access.reason {
                Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if let error { ErrorBanner(error: error) }
            TextField(access.blocked ? "Link a Claude account with a token to start a run." : "Describe a run", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .disabled(access.blocked)
            HStack {
                Text(starting ? "Starting…" : "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { start() } label: {
                    if starting { ProgressView() } else { Label("Run", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || access.blocked || starting)
            }
        }
    }

    private func start() {
        guard let api = model.api else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        starting = true
        Task {
            do {
                let res = try await api.mutate("agentRun.start", .from(["projectId": projectId, "prompt": text]))
                error = nil
                prompt = ""
                if let id = res["runId"].string {
                    RunActivityController.shared.trackRun(runId: id, projectId: projectId, title: String(text.prefix(40)))
                    onStarted(id)
                }
            } catch {
                self.error = error
            }
            starting = false
        }
    }
}

/// A run's transcript, live or stored (`RunTranscript`). Only the run that is
/// streaming has lines on the event bus; any other shows its stored output.
/// The composer stays under it, so the next run starts from here.
struct AgentRunDetail: View {
    let projectId: String
    let initialRunId: String
    let access: AgentAccess

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var events: EventStream
    @StateObject private var action = Action()
    @State private var runId: String = ""
    @State private var run: JSON?
    @State private var loadError: Error?
    @State private var liveLines: [String] = []
    @State private var endStatus: String?
    @State private var endError: String?
    @State private var subscription: UUID?
    @State private var showComposer = false

    private var status: String? { endStatus ?? run?["status"].string }
    private var isStreaming: Bool {
        guard endStatus == nil else { return false }
        guard let s = run?["status"].string else { return true }
        return s == "running" || s == "pending"
    }
    private var error: String? { endError ?? run?["error"].string }

    private var messages: [AgentMessage] {
        let lines: [String]
        if !liveLines.isEmpty { lines = liveLines }
        else { lines = (run?["output"].string ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        return AgentTranscript.parse(lines, alreadyShown: error)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if let loadError, liveLines.isEmpty {
                        ErrorBanner(error: loadError, retry: { Task { await load() } })
                    } else if run == nil && liveLines.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if messages.isEmpty {
                        Text("Waiting for output…").font(.caption).italic().foregroundStyle(.secondary)
                    }
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                        AgentMessageView(message: m)
                    }
                    if let error, !error.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Run failed").font(.subheadline.bold())
                            Text(error).font(.callout).textSelection(.enabled)
                        }
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: liveLines.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom) {
            if showComposer {
                AgentComposer(projectId: projectId, access: access) { id in
                    showComposer = false
                    switchTo(id)
                }
                .padding()
                .background(.bar)
            }
        }
        .navigationTitle("Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isStreaming {
                    Button(role: .destructive) { cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(action.busy)
                }
                Button { showComposer.toggle() } label: { Label("New run", systemImage: "square.and.pencil") }
            }
        }
        .errorAlert(action)
        .onAppear {
            if runId.isEmpty { runId = initialRunId }
            subscription = events.on { event in handle(event) }
        }
        .onDisappear { if let subscription { events.off(subscription) } }
        .task(id: runId) { if !runId.isEmpty { await load() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(firstLine(run?["label"].string ?? run?["prompt"].string ?? "Run"))
                .font(.headline).lineLimit(2)
            Spacer()
            if isStreaming { ProgressView() }
            else if let status { AgentRunStatusPill(status: status) }
        }
    }

    private func firstLine(_ s: String) -> String {
        (s.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map { String($0).trimmingCharacters(in: .whitespaces) } ?? s
    }

    private func switchTo(_ id: String) {
        liveLines = []
        endStatus = nil
        endError = nil
        run = nil
        runId = id
    }

    private func handle(_ event: JSON) {
        guard event["projectId"].string == projectId, event["data"]["runId"].string == runId else { return }
        switch event["type"].string {
        case "agentRun:chunk":
            if let line = event["data"]["line"].string { liveLines.append(line) }
        case "agentRun:end":
            endStatus = event["data"]["status"].string
            endError = event["data"]["error"].string
            // Its output is only in the database now; fall back to it.
            Task { await load() }
        default: break
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        let id = runId
        do {
            let r = try await api.query("agentRun.get", .from(["runId": id]))
            guard id == runId else { return }
            run = r
            loadError = nil
        } catch {
            loadError = error
        }
    }

    private func cancel() {
        guard let api = model.api else { return }
        let id = runId
        action.run {
            _ = try await api.mutate("agentRun.cancel", .from(["runId": id]))
            await load()
        }
    }
}

// MARK: - Transcript

struct AgentMessage {
    enum Kind { case system, assistant, tool, user, result, error, raw }
    let kind: Kind
    let text: String
}

/// The runner's NDJSON, made readable (`parseLines` in `AgentTab.tsx`):
/// assistant text, tool calls as one line each, the result, and errors —
/// except an error the run row already shows in full.
enum AgentTranscript {
    private static let toolSubject = ["command", "file_path", "notebook_path", "path", "pattern", "url", "query", "prompt", "description", "name"]

    static func parse(_ lines: [String], alreadyShown: String?) -> [AgentMessage] {
        var out: [AgentMessage] = []
        for line in lines {
            guard let data = line.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSON.self, from: data), case .object = parsed else {
                out.append(AgentMessage(kind: .raw, text: line))
                continue
            }
            switch parsed["type"].string {
            case "error":
                let text = parsed["error"].string ?? "Unknown error"
                let shown = (alreadyShown ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let dup = !shown.isEmpty && (shown.hasPrefix(t) || t.hasPrefix(shown))
                if !dup { out.append(AgentMessage(kind: .error, text: text)) }
            case "started":
                out.append(AgentMessage(kind: .system, text: "Run started"))
            case "done":
                out.append(AgentMessage(kind: .system, text: "Run complete"))
            case "message":
                let m = parsed["message"]
                let content = m["message"]["content"]
                switch m["type"].string {
                case "assistant":
                    let text = extractText(content)
                    if !text.isEmpty { out.append(AgentMessage(kind: .assistant, text: text)) }
                    for call in toolCalls(content) { out.append(AgentMessage(kind: .tool, text: call)) }
                case "result":
                    out.append(AgentMessage(kind: .result, text: m["result"].string ?? "(empty result)"))
                case "user":
                    let text = extractText(content)
                    if !text.isEmpty { out.append(AgentMessage(kind: .user, text: text)) }
                default: break
                }
            default: break
            }
        }
        return out
    }

    private static func extractText(_ content: JSON) -> String {
        content.array
            .filter { $0["type"].string == "text" }
            .compactMap { $0["text"].string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tool call as a line — "Bash: pnpm -r typecheck" — not its JSON.
    private static func toolCalls(_ content: JSON) -> [String] {
        content.array.filter { $0["type"].string == "tool_use" }.map { b in
            let name = b["name"].string ?? "tool"
            if let subject = subject(b["input"]) { return "→ \(name): \(subject)" }
            return "→ \(name)"
        }
    }

    private static func subject(_ input: JSON) -> String? {
        for field in toolSubject {
            if let v = input[field].string?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                let line = String(v.split(separator: "\n", omittingEmptySubsequences: false).first ?? Substring(v))
                return line.count > 120 ? String(line.prefix(119)) + "…" : line
            }
        }
        return nil
    }
}

struct AgentMessageView: View {
    let message: AgentMessage
    var body: some View {
        switch message.kind {
        case .system:
            Text(message.text).font(.caption).italic().foregroundStyle(.secondary)
        case .tool:
            Text(message.text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
        case .raw:
            Text(message.text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        case .assistant, .user, .result, .error:
            Text(message.text)
                .font(.callout)
                .foregroundStyle(message.kind == .error ? Color.red : message.kind == .user ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private var background: Color {
        switch message.kind {
        case .result: .green.opacity(0.1)
        case .error: .red.opacity(0.1)
        case .user: Color(.tertiarySystemFill)
        default: Color(.secondarySystemBackground)
        }
    }
}
