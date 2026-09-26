// tRPC: (none — helpers shared by the Settings screens)
import SwiftUI

/// The three account states, worded as the web dashboard words them: signed
/// in, token only, not signed in.
enum ClaudeAccountState {
    case signedIn, tokenOnly, notSignedIn

    init(_ account: JSON) {
        if account["isValid"].bool == true { self = .signedIn }
        else if account["hasSdkToken"].bool == true { self = .tokenOnly }
        else { self = .notSignedIn }
    }

    var label: String {
        switch self { case .signedIn: "Signed in"; case .tokenOnly: "Token only"; case .notSignedIn: "Not signed in" }
    }

    var tone: StatePill.Tone {
        switch self { case .signedIn: .ok; case .tokenOnly: .warn; case .notSignedIn: .danger }
    }

    var detail: String {
        switch self {
        case .signedIn: "Conversations, agent runs and Remote Control all work."
        case .tokenOnly: "Agent runs and the assistant API work; Remote Control does not."
        case .notSignedIn: "Sign in so this account's projects can run Claude."
        }
    }
}

/// `default_claude_max_20x` → "Max 20x": never a raw enum on screen.
func claudeTierLabel(_ raw: String) -> String {
    let known: [String: String] = [
        "default_claude_max_20x": "Max 20x", "default_claude_max_5x": "Max 5x",
        "claude_max": "Max", "claude_pro": "Pro", "pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise",
    ]
    if let hit = known[raw.lowercased()] { return hit }
    var s = raw
    for prefix in ["default_claude_", "claude_"] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
    return s.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

/// A date the server sent, as a short date and time.
func settingsDate(_ value: JSON) -> String? {
    if let d = value.date { return d.formatted(date: .abbreviated, time: .shortened) }
    if let ms = value.double { return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .shortened) }
    return nil
}

/// A page of the web dashboard, for what only a signed-in browser can do.
@MainActor func webURL(_ model: AppModel, _ path: String) -> URL? {
    model.credentials?.server.appendingPathComponent(path)
}

/// A value to copy, with a button that says it was copied.
struct CopyRow: View {
    let text: String
    var mono = true
    @State private var copied = false
    var body: some View {
        HStack {
            Text(text).font(mono ? .footnote.monospaced() : .footnote).textSelection(.enabled).lineLimit(3)
            Spacer()
            Button {
                UIPasteboard.general.string = text
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : "Copy")
        }
    }
}

/// The "saved, but these projects did not take it yet" note a library change can return.
struct NotUpdatedNote: View {
    let slugs: [String]
    var body: some View {
        if !slugs.isEmpty {
            Label("Saved, not yet live everywhere. These projects get it at their next start: \(slugs.joined(separator: ", ")).", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        }
    }
}
