// tRPC: project.remoteSessionStart, project.remoteSessionStop, project.deleteConversation, project.archiveConversation, project.sessionHandoff (through ConversationsStore)
import SwiftUI

/// One conversation as a row — the same row on the Overview's summary and in
/// the Conversations tab. Activity pill when live (busy, idle, needs you,
/// starting), the kind and age on the meta line, one inline action (resume
/// on the phone, or open in the Claude app), and a menu for the rest.
struct ConversationRowView: View {
    let conversation: JSON
    @ObservedObject var store: ConversationsStore
    /// Stop and Delete are the owner's (the server refuses anyone else);
    /// resume, move and archive are anyone's who may use the project.
    var isOwner: Bool = true
    var onShare: ((String, String) -> Void)?
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false

    private var f: ConversationFacts { ConversationFacts(s: conversation) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let last = f.lastPrompt {
                    Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if f.live, let pill = activity { StatePill(text: pill.0, tone: pill.1) }
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            primary
            menu
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .confirmationDialog("Delete this conversation? Its transcript and tool output are removed from the worker.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete conversation", role: .destructive) { store.delete(f.id, api: model.api) }
        }
    }

    private var activity: (String, StatePill.Tone)? {
        let r = store.roster[f.id]
        switch r {
        case "blocked": return ("Needs you", .warn)
        case "working": return ("Busy", .ok)
        case nil where store.rosterKnown: return ("Starting", .neutral)
        default: return ("Idle", .ok)
        }
    }

    private var meta: String {
        var parts = [f.kind]
        let age = Proj.relative(ms: conversation["updatedAt"].double)
        if !age.isEmpty { parts.append(age) }
        if f.messageCount > 0 { parts.append("\(f.messageCount) msg\(f.messageCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var primary: some View {
        if store.deletingId == f.id {
            ProgressView().controlSize(.small)
        } else if f.canResume {
            Button { store.resume(f.id, api: model.api) } label: {
                Image(systemName: "iphone.and.arrow.forward").accessibilityLabel("Resume in app")
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(store.busy)
        } else if let url = f.url {
            Button { openURL(url) } label: {
                Image(systemName: "arrow.up.right.square").accessibilityLabel("Open")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var menu: some View {
        Menu {
            if let url = f.url {
                Button { openURL(url) } label: { Label("Open in the Claude app", systemImage: "arrow.up.right.square") }
            }
            if f.canResume {
                Button { store.resume(f.id, api: model.api) } label: { Label("Resume in app", systemImage: "iphone") }
            }
            if f.canStop && isOwner {
                Button { store.stop(f.id, api: model.api) } label: { Label("Stop", systemImage: "stop") }
            }
            Divider()
            Button { store.handoff(f.id, target: "terminal", api: model.api) } label: {
                Label("Move to terminal", systemImage: "terminal")
                if !f.canMoveToTerminal { Text(f.messageCount == 0 ? "Nothing said in it yet." : "Already a terminal conversation.") }
            }.disabled(store.busy || !f.canMoveToTerminal)
            Button { store.handoff(f.id, target: nil, api: model.api) } label: {
                Label("Move to app", systemImage: "arrow.left.arrow.right")
                if !f.canMoveToApp { Text(f.messageCount == 0 ? "Nothing said in it yet." : "Already an app conversation.") }
            }.disabled(store.busy || !f.canMoveToApp)
            if let onShare {
                Button { onShare(f.id, f.title) } label: { Label("Share to Telegram", systemImage: "paperplane") }
            }
            Divider()
            Button { store.archive(f.id, remoteId: f.remoteId, api: model.api) } label: {
                Label("Archive", systemImage: "archivebox")
                if f.remoteId == nil { Text("Not in the Claude app yet.") }
            }.disabled(store.busy || f.remoteId == nil)
            if isOwner {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(store.busy)
            }
        } label: {
            Image(systemName: "ellipsis.circle").imageScale(.large).accessibilityLabel("More")
        }
        .buttonStyle(.borderless)
    }
}

/// The outcome of a hand-off: where the conversation went, the message to
/// send if the new one does not pick it up by itself, and the file it reads.
struct ConversationHandoffResult: View {
    let slug: String
    let result: JSON
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline).font(.subheadline.weight(.semibold))
            Text(instruction).font(.footnote)
            if let message = result["message"].string {
                Text(message).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            if let file = result["relativeFile"].string {
                Text("The dialogue is in \(file) in the workspace.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let message = result["message"].string { ProjCopyButton(text: message) }
                if let s = result["url"].string, let url = URL(string: s) {
                    Button { openURL(url) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Button("Close", action: onDismiss).controlSize(.small).buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var headline: String {
        let title = result["title"].string ?? ""
        let turns = result["turns"].int ?? 0, total = result["totalTurns"].int ?? 0
        return result["terminalSessionId"].string != nil
            ? "Moved “\(title)” to the terminal (\(turns) of \(total) turns) — join with: dockai claude \(slug)"
            : "Moved “\(title)” to the app — \(turns) of \(total) turns carried"
    }

    private var instruction: String {
        if result["autoPickup"].bool == true { return "Say anything in the new conversation — it reads the hand-off first. Otherwise send this:" }
        if result["pickupReason"].string == "agents_md" { return "This project uses AGENTS.md, so no start-up note was written. Send this:" }
        return "Send this as the first message in the new conversation:"
    }
}

/// "Remote Control · On" — the line that replaced the Remote Control card.
struct ConversationsRCLine: View {
    let rc: JSON
    let failed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("Remote Control").font(.caption).foregroundStyle(.secondary)
            StatePill(text: state.0, tone: state.1)
            if let err = rc["lastError"].string, !err.isEmpty, rc["running"].bool != true {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
        }
    }

    private var state: (String, StatePill.Tone) {
        if failed { return ("Unknown", .danger) }
        if rc.isNull { return ("…", .neutral) }
        let running = rc["running"].bool ?? false
        let blocked = rc["blockedReason"].string != nil
        if running { return ("On", .ok) }
        if !blocked && (rc["supervised"].bool ?? false) { return ("Retrying…", .warn) }
        if blocked { return ("Unavailable", .neutral) }
        return ("Off", .neutral)
    }
}
