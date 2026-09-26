import SwiftUI

/// Ask by voice (openspec/changes/watch-app): the saved target preselected,
/// dictation in the text field (speech becomes text on the watch), review,
/// Send. The answer comes back as a notification.
struct AskView: View {
    @EnvironmentObject var model: WatchModel
    @State private var text = ""
    @State private var sending = false
    @State private var sent = false

    private var ready: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Where it goes — a quiet line, not the action.
                    NavigationLink { AskProjectPicker() } label: {
                        HStack(spacing: 4) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.askTarget?.projectName ?? "Choose a project").font(.caption2.bold()).lineLimit(1)
                                Text(model.askTarget.map { $0.sessionId == nil ? "One-off question" : ($0.sessionTitle ?? "Conversation") } ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if let notice = model.askNotice {
                        Text(notice).font(.caption2).foregroundStyle(.orange)
                    }

                    // The action: tapping opens the watch's input, dictation
                    // first. Speech becomes text here, to check before sending.
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill").foregroundStyle(.tint)
                        TextField("Tap to speak", text: $text, axis: .vertical)
                            .textFieldStyle(.plain)
                    }
                    .padding(10)
                    .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))

                    if ready {
                        Button {
                            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            sending = true
                            Task {
                                if await model.ask(t) { text = ""; sent = true; model.askNotice = nil }
                                sending = false
                            }
                        } label: { Label("Send", systemImage: "arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || model.askTarget == nil)
                    } else if sent {
                        Label("Sent — the answer comes as a notification", systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Ask")
            .task { await model.resolveTarget() }
        }
    }
}

/// Another project, then one of its conversations — becomes the saved target.
private struct AskProjectPicker: View {
    @EnvironmentObject var model: WatchModel
    var body: some View {
        List(Array(model.projects.enumerated()), id: \.offset) { _, p in
            if let slug = p["slug"].string {
                NavigationLink(p["name"].string ?? slug) { AskConversationPicker(slug: slug, name: p["name"].string ?? slug) }
            }
        }
        .navigationTitle("Project")
    }
}

private struct AskConversationPicker: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    let slug: String
    let name: String
    @State private var list: [JSON] = []
    @State private var loading = true

    var body: some View {
        List {
            // A new conversation first, then a one-off question, then the
            // named conversations (live first).
            Button {
                Task { await model.newConversation(slug: slug, projectName: name); dismiss() }
            } label: { Label("New conversation", systemImage: "plus.bubble") }
            Button { pick(sessionId: nil, title: nil) } label: { Label("One-off question", systemImage: "bolt") }
            if loading { ProgressView() }
            ForEach(Array(list.enumerated()), id: \.offset) { _, s in
                Button {
                    pick(sessionId: s["id"].string, title: WatchModel.title(s))
                } label: {
                    HStack {
                        if !s["remoteState"].isNull { Circle().fill(.green).frame(width: 6, height: 6) }
                        Text(WatchModel.title(s)).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle(name)
        .task { list = await model.conversations(slug: slug); loading = false }
    }

    private func pick(sessionId: String?, title: String?) {
        model.askTarget = .init(slug: slug, projectName: name, sessionId: sessionId, sessionTitle: title)
        model.askNotice = nil
        dismiss()
    }
}
