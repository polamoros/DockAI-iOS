// tRPC: project.start
import SwiftUI

/// The Overview tab: what the page is opened for first — conversations — then
/// Claude's meters, the project's facts, the worker's numbers, and the laptop
/// command. A stopped project shows its facts and a Start; a starting one its
/// startup steps, live.
struct ProjectOverviewView: View {
    let slug: String
    let project: JSON
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    /// Status from `container:status` events, newer than `project`.
    @State private var liveStatus: [String: String] = [:]
    @State private var subscription: UUID?

    private var status: String? { project["id"].string.flatMap { liveStatus[$0] } ?? project["status"].string }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if project.isNull {
                    ProgressView().padding(.top, 40)
                } else {
                    ProjectRestartOwedBanner(project: project, onDone: {})
                    stateHeader
                    if status == "RUNNING" {
                        ConversationsSummaryCard(slug: slug, project: project)
                        OverviewClaudeCard(slug: slug, accountLabel: project["claudeAccount"]["label"].string)
                        OverviewProjectCard(project: project)
                        OverviewWorkerCard(slug: slug)
                        OverviewLaptopCard(slug: slug)
                    } else {
                        OverviewProjectCard(project: project)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .errorAlert(action)
        .onChange(of: project["status"].string) { _, _ in liveStatus = [:] }
        .onAppear {
            guard subscription == nil else { return }
            subscription = model.events.on { event in
                // Keyed by project id: this view appears before the project
                // has loaded, so its id cannot be captured here.
                guard event["type"].string == "container:status", let id = event["projectId"].string,
                      let s = event["data"]["status"].string else { return }
                Task { @MainActor in liveStatus[id] = s }
            }
        }
        .onDisappear { if let id = subscription { model.events.off(id); subscription = nil } }
    }

    @ViewBuilder private var stateHeader: some View {
        switch status {
        case "STARTING", "CREATING":
            ProjectStartupProgress(projectId: project["id"].string ?? "", status: status)
        case "ERROR":
            VStack(alignment: .leading, spacing: 8) {
                Label("The worker did not start", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Check the Logs tab for why, then try again.").font(.footnote).foregroundStyle(.secondary)
                if Proj.canDrive(project) { startButton("Retry") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        case "STOPPED", "STOPPING", nil:
            VStack(spacing: 10) {
                Image(systemName: "play.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text(status == "STOPPING" ? "Stopping…" : "The project is stopped. Start it to begin.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if status != "STOPPING" && Proj.canDrive(project) { startButton("Start") }
            }
            .frame(maxWidth: .infinity).padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        default:
            EmptyView()
        }
    }

    private func startButton(_ title: String) -> some View {
        Button {
            guard let id = project["id"].string, let api = model.api else { return }
            action.run {
                liveStatus[id] = "STARTING"
                _ = try await api.mutate("project.start", .from(["id": id]))
            }
        } label: {
            if action.busy { ProgressView() } else { Label(title, systemImage: "play.fill") }
        }
        .buttonStyle(.borderedProminent).disabled(action.busy)
    }
}

/// The project's own facts: slug, repository, branch, account.
struct OverviewProjectCard: View {
    let project: JSON
    var body: some View {
        ProjCard("Project", systemImage: "folder") {
            VStack(spacing: 6) {
                ProjFact(label: "Slug", value: project["slug"].string ?? "—", mono: true)
                if let url = project["githubRepoUrl"].string, !url.isEmpty {
                    HStack {
                        Text("Repository").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        if let link = URL(string: url.hasSuffix(".git") ? String(url.dropLast(4)) : url) {
                            Link(Proj.repoName(url) ?? url, destination: link).font(.footnote).lineLimit(1)
                        }
                    }
                    ProjFact(label: "Branch", value: project["githubBranch"].string ?? "main", mono: true)
                }
                ProjFact(label: "Account", value: project["claudeAccount"]["label"].string ?? "No account linked")
            }
        }
    }
}

/// From your computer: the one command that is typed again — `dockai claude
/// <slug>`, which joins the conversation the Claude app is on.
struct OverviewLaptopCard: View {
    let slug: String
    var body: some View {
        ProjCard("From your computer", systemImage: "laptopcomputer") {
            VStack(alignment: .leading, spacing: 6) {
                ProjCommandLine(command: "dockai claude \(slug)")
                Text("Joins the conversation the Claude app is on. Leave with Ctrl-b d; it keeps running.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Set up once per computer: npm install -g dockai, then dockai login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
