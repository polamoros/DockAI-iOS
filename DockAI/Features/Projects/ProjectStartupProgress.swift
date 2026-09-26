// tRPC: (none — reads `project:startup-step` events from the live stream)
import SwiftUI

/// The steps of a worker starting, as the server reports them over the event
/// stream. Only steps that are reported are shown, beside the three that
/// always happen; a failed start stops the spinner on the step it died on.
struct ProjectStartupProgress: View {
    let projectId: String
    let status: String?
    @EnvironmentObject var model: AppModel
    @State private var current = "creating"
    @State private var reported: Set<String> = ["creating"]
    @State private var completed: Set<String> = []
    @State private var messages: [String: String] = [:]
    @State private var subscription: UUID?

    private struct Step: Identifiable {
        let id: String
        let label: String
        var hint: String? = nil
    }
    private static let steps: [Step] = [
        Step(id: "pulling", label: "Downloading the image (2 GB)", hint: "Only on the first start, and only if the host does not have it."),
        Step(id: "creating", label: "Creating the worker"),
        Step(id: "configuring", label: "Configuring environment"),
        Step(id: "ssh", label: "Starting SSH server"),
        Step(id: "cloning", label: "Cloning repository"),
        Step(id: "packages", label: "Installing packages"),
        Step(id: "docker", label: "Starting the Docker daemon"),
        Step(id: "docker-ready", label: "Docker daemon ready"),
        Step(id: "ready", label: "Ready"),
    ]
    private static let alwaysVisible: Set<String> = ["creating", "configuring", "ready"]

    private var failed: Bool { status == "ERROR" }
    private var active: Bool { current != "ready" && !failed }
    private var visible: [Step] {
        Self.steps.filter { Self.alwaysVisible.contains($0.id) || reported.contains($0.id) }
    }

    var body: some View {
        ProjCard(failed ? "The worker did not start" : active ? "Starting project" : "Project started",
                 systemImage: failed ? "xmark.octagon" : "shippingbox") {
            if active { ProgressView() }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visible) { step in
                    let done = completed.contains(step.id) || (step.id == "ready" && current == "ready")
                    let isCurrent = step.id == current && !done
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Group {
                            if failed && isCurrent { Image(systemName: "xmark").foregroundStyle(.red) }
                            else if done { Image(systemName: "checkmark").foregroundStyle(.green) }
                            else if isCurrent { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                        }.frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((isCurrent || done) ? (messages[step.id] ?? step.label) : step.label)
                                .font(.subheadline.weight(isCurrent ? .medium : .regular))
                                .foregroundStyle(failed && isCurrent ? Color.red : (done || isCurrent) ? Color.primary : Color.secondary)
                            if isCurrent, messages[step.id] == nil, let hint = step.hint {
                                Text(hint).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            guard subscription == nil else { return }
            subscription = model.events.on { event in
                guard event["type"].string == "project:startup-step", event["projectId"].string == projectId,
                      let step = event["data"]["step"].string else { return }
                Task { @MainActor in apply(step: step, message: event["data"]["message"].string) }
            }
        }
        .onDisappear { if let id = subscription { model.events.off(id); subscription = nil } }
    }

    private func apply(step: String, message: String?) {
        reported.insert(step)
        if let message { messages[step] = message }
        let order = visible.map(\.id)
        if let index = order.firstIndex(of: step) {
            for s in order.prefix(index) { completed.insert(s) }
        }
        current = step
    }
}
