// tRPC: (none directly — AgentAutomationsList and AgentRunsList call agentRun.*)
import SwiftUI

/// The Agent tab, as on the web (`AgentTab.tsx`): a switch between
/// Automations and Runs — automations first, since they are what a person sets
/// up and comes back to; runs are the history they leave behind.
struct AgentView: View {
    let slug: String
    let project: JSON

    enum Filter: String, CaseIterable, Identifiable {
        case automations, runs
        var id: String { rawValue }
    }

    @State private var filter: Filter = .automations
    /// Counts for the switch's labels, reported by the two lists once loaded.
    @State private var automationCount: Int?
    @State private var runCount: Int?

    private var projectId: String? { project["id"].string }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Runs or automations", selection: $filter) {
                Text(label("Automations", automationCount)).tag(Filter.automations)
                Text(label("Runs", runCount)).tag(Filter.runs)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let projectId {
                switch filter {
                case .automations:
                    AgentAutomationsList(projectId: projectId, slug: slug, onCount: { automationCount = $0 })
                case .runs:
                    AgentRunsList(projectId: projectId, access: AgentAccess(project: project), onCount: { runCount = $0 })
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func label(_ title: String, _ count: Int?) -> String {
        count.map { "\(title) \($0)" } ?? title
    }
}

/// Whether the tab refuses to start a run, and why — `isAgentBlocked` on the
/// web. `hasSdkToken` is three-valued: unknown does not block (the server
/// still refuses a run with no token, and its error says why).
struct AgentAccess {
    let hasClaudeAccount: Bool
    let hasSdkToken: Bool?

    init(project: JSON) {
        hasClaudeAccount = project["claudeAccountId"].string != nil
        hasSdkToken = project["claudeAccount"].isNull ? nil : project["claudeAccount"]["hasSdkToken"].bool
    }

    var blocked: Bool { !hasClaudeAccount || hasSdkToken == false }

    /// The sentence the web's empty pane shows when blocked.
    var reason: String? {
        if !hasClaudeAccount { return "This project has no Claude account linked. Assign one in project settings." }
        if hasSdkToken == false { return "The linked Claude account needs a token. Generate one with `claude setup-token` and add it on the account's settings page." }
        return nil
    }
}

/// Shared formatting for the Agent tab.
enum AgentFormat {
    /// "21 Sept 2026, 16:04", in the viewer's locale.
    static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `elapsed()` from the web's `lib/datetime.ts`.
    static func elapsed(_ start: Date?, _ end: Date?) -> String? {
        guard let start, let end else { return nil }
        let ms = max(0, end.timeIntervalSince(start) * 1000)
        if ms < 1000 { return "\(Int(ms.rounded()))ms" }
        if ms < 60_000 { return String(format: "%.1fs", ms / 1000) }
        return "\(Int(ms / 60_000))m \(Int((ms.truncatingRemainder(dividingBy: 60_000) / 1000).rounded()))s"
    }
}

/// A run's state as a word (`RunStatusPill` on the web).
struct AgentRunStatusPill: View {
    let status: String
    var body: some View {
        StatePill(text: text, tone: tone)
    }
    private var text: String {
        switch status {
        case "completed": "Done"
        case "failed": "Failed"
        case "running": "Running"
        case "pending": "Queued"
        case "canceled": "Stopped"
        default: status
        }
    }
    private var tone: StatePill.Tone {
        switch status {
        case "completed": .ok
        case "failed": .danger
        case "running": .accent
        case "pending": .warn
        default: .neutral
        }
    }
}
