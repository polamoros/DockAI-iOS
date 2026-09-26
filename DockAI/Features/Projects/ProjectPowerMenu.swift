// tRPC: project.start, project.stop, project.restart
import SwiftUI

/// The project page's power control: Start, Stop, Restart — and, when a
/// restart is owed, that reason on the menu's Restart. A viewer gets no
/// controls, because the server would refuse them.
struct ProjectPowerMenu: View {
    let project: JSON
    let onDone: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    @State private var confirm: String?

    private var status: String? { project["status"].string }
    private var id: String? { project["id"].string }

    var body: some View {
        Group {
            if action.busy {
                ProgressView()
            } else if project.isNull || !Proj.canDrive(project) {
                EmptyView()
            } else {
                Menu {
                    if Proj.startable(status) {
                        Button { run("start") } label: { Label("Start", systemImage: "play") }
                    }
                    if status == "RUNNING" {
                        if let reason = Proj.restartReason(project) {
                            Section(reason) {
                                Button { run("restart") } label: { Label("Restart now", systemImage: "arrow.clockwise") }
                            }
                        } else {
                            Button { confirm = "restart" } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        }
                        Button(role: .destructive) { confirm = "stop" } label: { Label("Stop", systemImage: "stop") }
                    }
                    if status == "STARTING" || status == "CREATING" || status == "STOPPING" {
                        Text(status == "STOPPING" ? "Stopping…" : "Starting…")
                    }
                } label: {
                    Image(systemName: Proj.restartReason(project) != nil && status == "RUNNING" ? "power.circle.fill" : "power")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Proj.restartReason(project) != nil && status == "RUNNING" ? Color.orange : Color.accentColor)
                        .accessibilityLabel("Power")
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if let c = confirm {
                Button(c == "stop" ? "Stop" : "Restart", role: .destructive) { run(c) }
            }
        }
        .errorAlert(action)
    }

    private var confirmTitle: String {
        confirm == "stop"
            ? "Stop this project? Conversations in it stop answering until it starts again."
            : "Restart this project? The worker is recreated; conversations take a minute to come back."
    }

    private func run(_ verb: String) {
        guard let id, let api = model.api else { return }
        action.run {
            _ = try await api.mutate("project.\(verb)", .from(["id": id]))
            onDone()
        }
    }
}

/// "A restart is owed" as a one-line notice with its one action — the web's
/// `RestartPendingBanner`, for the Overview.
struct ProjectRestartOwedBanner: View {
    let project: JSON
    let onDone: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()

    var body: some View {
        if let reason = Proj.restartReason(project), project["status"].string == "RUNNING" {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.clockwise").foregroundStyle(.orange)
                Text(reason).font(.footnote)
                Spacer(minLength: 4)
                if Proj.canDrive(project) {
                    Button {
                        guard let id = project["id"].string, let api = model.api else { return }
                        action.run {
                            _ = try await api.mutate("project.restart", .from(["id": id]))
                            onDone()
                        }
                    } label: {
                        if action.busy { ProgressView() } else { Text("Restart now") }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(action.busy)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .errorAlert(action)
        }
    }
}
