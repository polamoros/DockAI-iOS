// tRPC: project.update, project.getBySlug
import SwiftUI

/// Settings → Browser (BrowserSettings.tsx): whose logins the project's
/// browser holds, and which browser Claude reaches for. Saves on change.
struct PSBrowserSettings: View {
    let slug: String
    let onChange: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var box: PSProjectBox
    @StateObject private var action = Action()
    @State private var saved = false

    init(slug: String, project: JSON, onChange: @escaping () -> Void) {
        self.slug = slug
        self.onChange = onChange
        _box = StateObject(wrappedValue: PSProjectBox(project))
    }

    private var p: JSON { box.project }
    private var profile: String { p["browserProfile"].string ?? "project" }
    private var agent: String { p["agentBrowser"].string ?? "project" }

    var body: some View {
        Form {
            Section {
                Picker("Logins", selection: Binding(get: { profile }, set: { set("browserProfile", $0) })) {
                    Text("Just this project").tag("project")
                    Text("Shared").tag("shared")
                }.ownerOnly(p)
                Text(profile == "shared" ? "One set of logins across every project set to shared." : "Its own logins, kept on this project's volume.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Claude's browser", selection: Binding(get: { agent }, set: { set("agentBrowser", $0) })) {
                    Text("This project's").tag("project")
                    Text("My computer's Chrome").tag("laptop")
                    Text("Both").tag("both")
                }
                Text(agent == "laptop" ? "Only while dockai claude is attached from that computer."
                     : agent == "both" ? "Whichever the agent reaches for." : "Always there, the Claude app included.")
                    .font(.caption).foregroundStyle(.secondary)
                Label("Anything you sign into here, the agent can act as.", systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(.orange)
            } header: {
                Text("The project's browser")
            } footer: {
                VStack(alignment: .leading) {
                    Text("One browser for this project, shared with the agent. Open it from the Browser tab.")
                    if action.busy { Text("Saving…") } else if saved { Text("Saved") }
                }
            }
        }
        .disabled(!p.psCan("configure") || action.busy)
        .errorAlert(action)
    }

    private func set(_ key: String, _ value: String) {
        guard let id = p["id"].string, p[key].string ?? "project" != value else { return }
        action.run {
            _ = try await model.api?.mutate("project.update", .from(["id": id, key: value]))
            await box.reload(model.api, slug: slug)
            saved = true
            onChange()
        }
    }
}

/// Settings → Your computer (LaptopSettings.tsx): the set-up commands to copy,
/// where the SSH keys live, and the one grant a conversation has there.
struct PSComputerSettings: View {
    let slug: String
    let onChange: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var box: PSProjectBox
    @StateObject private var action = Action()

    init(slug: String, project: JSON, onChange: @escaping () -> Void) {
        self.slug = slug
        self.onChange = onChange
        _box = StateObject(wrappedValue: PSProjectBox(project))
    }

    private var p: JSON { box.project }
    private var origin: String {
        var s = model.credentials?.server.absoluteString ?? ""
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    var body: some View {
        Form {
            Section {
                PSCommandRow(label: "Install the CLI", command: "npm install -g dockai", hint: "Once per computer.")
                PSCommandRow(label: "Sign in", command: "dockai login --server \(origin)", hint: "Once per computer.")
                PSCommandRow(label: "Open Claude here", command: "dockai claude \(slug)",
                             hint: "Joins the conversation the Claude app is on. Leave with Ctrl-b d; it keeps running.")
                PSCommandRow(label: "SSH host", command: "dockai-\(slug)", hint: "For VS Code or the Claude desktop app.")
                PSLabel(title: "SSH keys", detail: "Your public keys, shared by every project — managed under Settings → SSH keys.")
            } header: {
                Text("Connecting")
            } footer: {
                Text("Working on this project from the computer in front of you.")
            }

            Section("Permissions") {
                Toggle(isOn: Binding(
                    get: { p["clientAllowRun"].bool == true },
                    set: { v in
                        guard let id = p["id"].string else { return }
                        action.run {
                            _ = try await model.api?.mutate("project.update", .from(["id": id, "clientAllowRun": v]))
                            await box.reload(model.api, slug: slug)
                            onChange()
                        }
                    }
                )) {
                    PSLabel(title: "Computer commands",
                            detail: "A conversation may run commands on your Mac while dockai claude is attached. "
                                + (p["clientAllowRun"].bool == true ? "Allowed by default." : "Only with --allow-run."))
                }
                .disabled(action.busy || !p.psOwner)
                PSOwnerOnlyNote(project: p)
            }
        }
        .errorAlert(action)
    }
}
