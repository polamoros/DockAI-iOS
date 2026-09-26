// tRPC: project.getBySlug, project.update, project.restart
import SwiftUI

/// What a save costs, decided from the fields that actually changed — the same
/// two sets the server uses in `project.update` on the server.
/// Keep them in step with `WORKER_RESTART_FIELDS` / `RC_RESTART_FIELDS` there.
enum PSRestart {
    static let workerFields: Set<String> = [
        "claudeAccountId", "fallbackAccountIds", "claudeModel", "claudeTools",
        "githubRepoUrl", "githubBranch", "githubPat", "githubConnectionId",
        "extraPackages", "workerEnv", "devcontainerJson", "customWorkerImage", "sandbox", "hostAccess", "memoryLimitMb", "remoteName",
        "networkMode", "networkAllowedHosts",
    ]
    static let rcFields: Set<String> = [
        "claudeAutoRemote", "claudePermissionMode", "capacity", "claudeRcSpawn", "claudeRcInteractive", "claudeCustomFlags",
    ]

    /// The web SaveBar's sentence. The server restarts Remote Control only when
    /// an RC field changed and no worker field did; turning RC off stops it.
    static func consequence(changed: Set<String>, running: Bool, accountCanRc: Bool = true, autoRemoteAfter: Bool = true) -> [String] {
        guard running else { return [] }
        let worker = !changed.isDisjoint(with: workerFields)
        let rc = !changed.isDisjoint(with: rcFields)
        var lines: [String] = []
        if rc && !worker && accountCanRc {
            lines.append(autoRemoteAfter
                ? "Saving restarts Remote Control; conversations reconnect after about a minute."
                : "Saving stops Remote Control: the Claude app loses this project until you switch it back on.")
        }
        if worker { lines.append("Saving asks for a worker restart before it takes effect.") }
        return lines
    }
}

/// Only the fields that differ from what the project has, so a save never
/// resets a field this page does not show (the reason `updateProjectSchema`
/// strips defaults). `defaults` stands in for a column the server sent as null.
enum PSPatch {
    static func changed(_ values: [String: JSON], project: JSON, defaults: [String: JSON] = [:]) -> [String: JSON] {
        var out: [String: JSON] = [:]
        for (k, v) in values {
            var current = project[k]
            if current.isNull, let d = defaults[k] { current = d }
            if normalized(v) != normalized(current) { out[k] = v }
        }
        return out
    }

    /// An empty string and null are one value for optional text columns.
    private static func normalized(_ j: JSON) -> JSON {
        if case .string(let s) = j, s.isEmpty { return .null }
        return j
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init).filter { !$0.isEmpty }
    }
}

extension JSON {
    /// `capabilities` from project.getBySlug: read · use · configure · own.
    func psCan(_ capability: String) -> Bool {
        let caps = self["capabilities"].array
        if caps.isEmpty { return self["role"].string == "OWNER" || self["role"].isNull }
        return caps.contains(.string(capability))
    }
    var psRunning: Bool { self["status"].string == "RUNNING" }
    /// The project's owner — who alone changes the owner's configuration
    /// (OWNER_ONLY_PROJECT_FIELDS on the server: account, GitHub, `.env`,
    /// network, laptop, Telegram, image, slug).
    var psOwner: Bool { psCan("own") }
}

extension View {
    /// A control that holds the owner's configuration: a collaborator sees it
    /// but cannot change it, and is told why, instead of a save refused.
    func ownerOnly(_ project: JSON) -> some View {
        disabled(!project.psOwner)
    }
}

/// Said under a group a collaborator cannot change.
struct PSOwnerOnlyNote: View {
    let project: JSON
    var body: some View {
        if !project.psOwner {
            Text("Only the project's owner can change these.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A settings page's copy of the project: starts from what the parent gave it
/// and is re-read after each save, so the page never diffs against stale values
/// even if the pushed view's inputs do not update.
@MainActor
final class PSProjectBox: ObservableObject {
    @Published var project: JSON
    init(_ project: JSON) { self.project = project }

    func reload(_ api: TRPCClient?, slug: String) async {
        guard let api, let p = try? await api.query("project.getBySlug", .from(["slug": slug])) else { return }
        project = p
    }
}

/// The save row: the consequence sentence above the one button, and the
/// server's refusal under it — the web `SaveBar`.
struct PSSaveSection: View {
    let consequence: [String]
    let busy: Bool
    let saved: Bool
    var disabled = false
    var blockedReason: String?
    let save: () -> Void

    var body: some View {
        Section {
            Button {
                save()
            } label: {
                HStack {
                    if busy { ProgressView() }
                    Text(saved ? "Saved!" : "Save changes").frame(maxWidth: .infinity)
                }
            }
            .disabled(busy || disabled)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let blockedReason { Text(blockedReason).foregroundStyle(.orange) }
                ForEach(consequence, id: \.self) { Text($0) }
            }
        }
    }
}

/// "Saved — takes effect after a restart." with Restart now, for either reason
/// a restart is owed (a baked-in setting changed, or a newer worker image).
struct PSRestartOwedSection: View {
    let project: JSON
    let onRestarted: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()

    var body: some View {
        let pending = project["restartPending"].bool == true
        let stale = project["container"]["imageStale"].bool == true
        if (pending || stale) && project.psRunning {
            Section {
                HStack(alignment: .center) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.orange)
                    Text(pending && stale ? "Saved, and a newer worker image is available — restart applies both."
                         : stale ? "A newer worker image is available — restart to use it."
                         : "Saved — takes effect after a restart.")
                        .font(.callout)
                    Spacer()
                    Button {
                        guard let id = project["id"].string else { return }
                        action.run {
                            _ = try await model.api?.mutate("project.restart", .from(["id": id]))
                            onRestarted()
                        }
                    } label: {
                        if action.busy { ProgressView() } else { Text("Restart now") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(action.busy)
                }
            }
            .errorAlert(action)
        }
    }
}

/// A command shown in full, wrapping, with a copy button.
struct PSCommandRow: View {
    let label: String
    let command: String
    var hint: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium))
            HStack(alignment: .top) {
                Text(command).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = command
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied" : "Copy")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

/// A label with a secondary sentence under it, for rows that carry a control.
struct PSLabel: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
