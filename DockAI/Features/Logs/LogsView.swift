// tRPC: project.logs, project.getCommandHistory, project.getCommandOutput, project.stopCommand
import SwiftUI

/// The Logs tab, as the web's `LogViewer`: one timeline braiding the worker's
/// log (`project.logs`, a raw string) with the terminal's command history
/// (`project.getCommandHistory`), newest first and grouped by day.
///
/// An entry is a meta line (time, kind, outcome) over a block of text that
/// wraps on word boundaries — never a row with the text as its only
/// shrinkable column. Only a command has something to reveal, so only a
/// command expands, and its output is fetched when it opens, not before.
struct LogsView: View {
    let slug: String
    let project: JSON
    @EnvironmentObject var model: AppModel

    @State private var filter: LogFilter = .all
    @State private var tail = 200
    @State private var logs: String?
    @State private var history: [JSON]?
    @State private var error: Error?
    @State private var loading = false

    /// What the server accepts (`tail` is 1…5000).
    private static let tailSteps = [200, 1000, 5000]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: "\(project["id"].string ?? "")-\(tail)") { await poll() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Activity").font(.headline)
                Label("\(counts.commands)", systemImage: "terminal").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Label("\(counts.worker)", systemImage: "shippingbox").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Picker("What to show", selection: $filter) {
                ForEach(LogFilter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if logs == nil || history == nil {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } }).padding()
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if filtered.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
                Text("No activity yet").font(.subheadline)
                Button("Reload") { Task { await load() } }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if let error { ErrorBanner(error: error, retry: { Task { await load() } }).listRowSeparator(.hidden) }
                ForEach(grouped) { group in
                    Section(group.day) {
                        ForEach(group.entries) { entry in
                            if entry.kind == .command {
                                CommandEntryRow(entry: entry, slug: slug)
                            } else {
                                EntryBody(entry: entry)
                                    .listRowBackground(entry.status == .error ? Color.red.opacity(0.08) : nil)
                            }
                        }
                    }
                }
                // The oldest end of a newest-first list is where asking for more of it belongs.
                if let next = Self.tailSteps.first(where: { $0 > tail }) {
                    Button("More lines") { tail = next }
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.plain)
            .refreshable { await load() }
        }
    }

    // MARK: Data

    /// The web polls every 15s: nothing on the server emits `container:logs`,
    /// so without the interval the tab would freeze on whatever it read first.
    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    private func load() async {
        guard let api = model.api, let id = project["id"].string else { return }
        loading = true
        defer { loading = false }
        do {
            // Command history is the owner's; asking for it in the same
            // request made the whole tab an error for anyone else (audit
            // 2026-09-26).
            async let l = api.query("project.logs", .from(["id": id, "tail": tail]))
            async let h = Proj.isOwner(project) ? (try? await api.query("project.getCommandHistory", .from(["slug": slug]))) : nil
            let lv = try await l
            logs = lv["logs"].string ?? ""
            history = (await h)?.array ?? []
            error = nil
        } catch {
            self.error = error
        }
    }

    private var entries: [LogEntry] {
        var out: [LogEntry] = []
        for c in history ?? [] {
            guard let command = c["command"].string, let start = c["startTime"].double else { continue }
            let end = c["endTime"].double
            let exit = c["exitCode"].int
            var detail: String?
            if let end {
                let code = exit.map { String($0) } ?? "?"
                detail = "\(exit == 0 ? "exited 0" : "exit \(code)") · \(formatElapsed(start, end))"
            }
            let status: LogEntry.Status = end == nil ? .running : exit == 0 ? .success : .error
            out.append(LogEntry(id: "cmd-\(Int(start))", kind: .command, timestamp: start, content: command, detail: detail, status: status))
        }
        let lines = (logs ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let now = Date().timeIntervalSince1970 * 1000
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (i, line) in lines.enumerated() {
            var ts = now - Double(lines.count - i) * 100
            var content = line
            // Docker's own timestamp at the start of a line, when there is one.
            if let space = line.firstIndex(of: " "), line.first?.isNumber == true {
                let head = String(line[..<space])
                if head.contains("T"), let d = iso.date(from: head) ?? ISO8601DateFormatter().date(from: head) {
                    ts = d.timeIntervalSince1970 * 1000
                    content = String(line[line.index(after: space)...])
                }
            }
            let lower = content.lowercased()
            let status: LogEntry.Status? = (lower.contains("error") || lower.contains("fail") || lower.contains("fatal")) ? .error
                : lower.contains("warn") ? .info : nil
            out.append(LogEntry(id: "log-\(i)", kind: .worker, timestamp: ts, content: content.trimmingCharacters(in: .whitespaces), detail: nil, status: status))
        }
        return out.sorted { $0.timestamp > $1.timestamp }
    }

    private var counts: (commands: Int, worker: Int) {
        let all = entries
        let c = all.filter { $0.kind == .command }.count
        return (c, all.count - c)
    }

    private var filtered: [LogEntry] {
        switch filter {
        case .all: entries
        case .command: entries.filter { $0.kind == .command }
        case .worker: entries.filter { $0.kind == .worker }
        }
    }

    private var grouped: [LogDay] {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        var order: [String] = []
        var map: [String: [LogEntry]] = [:]
        for e in filtered {
            let key = f.string(from: Date(timeIntervalSince1970: e.timestamp / 1000))
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { LogDay(day: $0, entries: map[$0] ?? []) }
    }
}

enum LogFilter: String, CaseIterable, Identifiable {
    case all, command, worker
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "All"; case .command: "Commands"; case .worker: "Worker" }
    }
}

struct LogDay: Identifiable {
    let day: String
    let entries: [LogEntry]
    var id: String { day }
}

struct LogEntry: Identifiable {
    enum Kind { case command, worker }
    enum Status { case success, error, running, info }
    let id: String
    let kind: Kind
    /// Milliseconds since the epoch, as the server stores command times.
    let timestamp: Double
    let content: String
    let detail: String?
    let status: Status?
}

/// Two hours twenty is `2h 20m`, not `140m` — the web's `elapsed`.
func formatElapsed(_ startMs: Double, _ endMs: Double) -> String {
    let s = max(0, Int((endMs - startMs) / 1000))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
    return (s % 3600) / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \((s % 3600) / 60)m"
}

/// The meta line over the text: time, kind, outcome, detail.
private struct EntryBody: View {
    let entry: LogEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Date(timeIntervalSince1970: entry.timestamp / 1000), format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                StatePill(text: entry.kind == .command ? "Commands" : "Worker", tone: entry.kind == .command ? .accent : .neutral)
                if let status = entry.status { statusIcon(status) }
                if let detail = entry.detail { Text(detail).font(.caption2) }
            }
            .foregroundStyle(entry.status == .error ? Color.red : Color.secondary)
            Text(entry.content)
                .font(.caption.monospaced())
                .foregroundStyle(entry.status == .error ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func statusIcon(_ s: LogEntry.Status) -> some View {
        switch s {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .running: Image(systemName: "clock").foregroundStyle(.orange)
        case .info: Image(systemName: "minus").foregroundStyle(.secondary)
        }
    }
}

/// A command: a disclosure whose output is fetched only once it is opened.
private struct CommandEntryRow: View {
    let entry: LogEntry
    let slug: String
    @EnvironmentObject var model: AppModel
    @State private var open = false
    @State private var output: String?
    @State private var error: Error?
    @StateObject private var stop = Action()

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    ErrorBanner(error: error, retry: { Task { await fetch() } })
                } else if let output {
                    if output.isEmpty {
                        Text("No output captured").font(.caption).italic().foregroundStyle(.secondary)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(output).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .frame(maxHeight: 200)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                // A command still running can be interrupted: SIGINT to what matches it.
                if entry.status == .running {
                    Button(role: .destructive) {
                        stop.run {
                            guard let api = model.api else { return }
                            _ = try await api.mutate("project.stopCommand", .from(["slug": slug, "command": entry.content]))
                        }
                    } label: { Label("Stop", systemImage: "stop.circle") }
                    .buttonStyle(.bordered)
                    .disabled(stop.busy)
                }
            }
            .task(id: open) { if open && output == nil { await fetch() } }
        } label: {
            EntryBody(entry: entry)
        }
        .listRowBackground(entry.status == .error ? Color.red.opacity(0.08) : nil)
        .errorAlert(stop)
    }

    private func fetch() async {
        guard let api = model.api else { return }
        do {
            let r = try await api.query("project.getCommandOutput", .from(["slug": slug, "command": entry.content, "startTime": entry.timestamp]))
            output = r["output"].string ?? ""
            error = nil
        } catch {
            self.error = error
        }
    }
}
