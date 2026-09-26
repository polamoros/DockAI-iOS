// tRPC: admin.system.serverInfo, admin.system.dockerStats, system.version
import SwiftUI

/// Admin → Overview (pages/admin/SystemSection.tsx): the install's counts,
/// the Docker daemon's facts — loaded separately, because Docker can be
/// unreachable while the database answers, and that difference is the
/// diagnosis — and the running workers.
struct AdminOverviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var info: JSON?
    @State private var infoError: Error?
    @State private var docker: JSON?
    @State private var dockerLoaded = false
    @State private var dockerError: Error?
    @State private var version: JSON?

    var body: some View {
        List {
            Section {
                if let infoError {
                    ErrorBanner(error: infoError, retry: { Task { await load() } })
                } else if let info {
                    LabeledContent("Users", value: "\(info["userCount"].int ?? 0)")
                    LabeledContent("Projects", value: "\(info["projectCount"].int ?? 0)")
                    LabeledContent("Accounts", value: "\(info["accountCount"].int ?? 0)")
                    let c = info["containers"]
                    LabeledContent("Workers") {
                        VStack(alignment: .trailing) {
                            Text("\(c["running"].int ?? 0)").foregroundStyle((c["running"].int ?? 0) > 0 ? .green : .secondary)
                            if (c["running"].int ?? 0) > 0 {
                                Text("\(c["working"].int ?? 0) busy / \(c["idle"].int ?? 0) idle").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }

            Section("Docker system") {
                if let dockerError {
                    ErrorBanner(error: dockerError, retry: { Task { await load() } })
                } else if !dockerLoaded {
                    ProgressView()
                } else if let d = docker, !d.isNull {
                    LabeledContent("Docker version", value: "v\(d["serverVersion"].string ?? "?")")
                    LabeledContent("CPUs", value: "\(d["cpus"].int ?? 0)")
                    LabeledContent("Memory", value: AdminFormat.bytes(d["memoryTotal"].double ?? 0))
                    LabeledContent("Containers", value: "\(d["containersRunning"].int ?? 0) / \(d["containers"].int ?? 0)")
                    LabeledContent("Images", value: "\(d["images"].int ?? 0)")
                    LabeledContent("OS", value: d["operatingSystem"].string ?? "—")
                } else {
                    Label("Could not reach the Docker daemon", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }

            if let workers = info?["workers"].array, !workers.isEmpty {
                Section("Active workers (\(workers.count))") {
                    ForEach(workers, id: \.self) { w in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w["name"].string ?? "").lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(w["slug"].string ?? "").font(.caption.monospaced())
                                    if let d = w["startedAt"].date { Text("· \(AdminFormat.uptime(since: d))").font(.caption) }
                                }.foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(status: w["status"].string)
                            if w["claudeStatus"].string == "working" { StatePill(text: "Busy", tone: .warn) }
                            else { StatePill(text: "Idle") }
                        }
                    }
                }
            }

            if let version {
                Section("DockAI") {
                    LabeledContent("Server", value: version["server"].string ?? "—")
                    LabeledContent("Minimum CLI", value: version["minCli"].string ?? "—")
                }
            }
        }
        .navigationTitle("Overview")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        async let i = adminAttempt { try await api.query("admin.system.serverInfo") }
        async let d = adminAttempt { try await api.query("admin.system.dockerStats") }
        async let v = adminAttempt { try await api.query("system.version") }
        switch await i { case .success(let x): info = x; infoError = nil; case .failure(let e): infoError = e }
        switch await d { case .success(let x): docker = x; dockerError = nil; case .failure(let e): dockerError = e }
        dockerLoaded = true
        if case .success(let x) = await v { version = x }
    }
}

/// Run one request and keep its failure beside the others' answers.
func adminAttempt(_ body: () async throws -> JSON) async -> Result<JSON, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
