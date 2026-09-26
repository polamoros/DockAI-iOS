// tRPC: device.pending
import SwiftUI

/// Everything waiting on the person, newest first: permission requests from
/// runs (Allow / Deny), questions (an option, or a dictated reply), and
/// conversations blocked in their own terminal, which only the Claude app can
/// answer, so they carry no buttons.
struct NeedsYouView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        let perms = model.pending["permissions"].array
        let questions = model.pending["questions"].array
        let blocked = model.pending["blocked"].array
        NavigationStack {
            List {
                if perms.isEmpty && questions.isEmpty && blocked.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Nothing waiting", systemImage: "checkmark.circle").foregroundStyle(.green)
                        if model.loading { ProgressView() }
                    }
                }
                ForEach(Array(perms.enumerated()), id: \.offset) { _, p in
                    PermissionRow(item: p)
                }
                ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                    NavigationLink { QuestionView(item: q) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q["project"].string ?? "").font(.caption2).foregroundStyle(.secondary)
                            Text(q["question"].string ?? "").font(.footnote).lineLimit(3)
                        }
                    }
                }
                ForEach(Array(blocked.enumerated()), id: \.offset) { _, b in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b["project"].string ?? "").font(.caption2).foregroundStyle(.secondary)
                        Text(b["name"].string ?? "A conversation").font(.footnote)
                        Text("Waiting in the Claude app").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Needs you")
            .refreshable { await model.refresh() }
        }
    }
}

private struct PermissionRow: View {
    @EnvironmentObject var model: WatchModel
    let item: JSON
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item["project"].string ?? "").font(.caption2).foregroundStyle(.secondary)
            Text("Wants to \(item["what"].string ?? item["tool"].string ?? "")").font(.footnote).lineLimit(4)
            HStack {
                Button("Deny", role: .destructive) { answer(false) }
                Button("Allow") { answer(true) }.tint(.green)
            }
            .disabled(busy)
        }
    }

    private func answer(_ allow: Bool) {
        guard let key = item["key"].string else { return }
        busy = true
        Task { await model.answerPermission(key: key, allow: allow); busy = false }
    }
}

private struct QuestionView: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    let item: JSON
    @State private var reply = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(item["project"].string ?? "").font(.caption2).foregroundStyle(.secondary)
                Text(item["question"].string ?? "").font(.footnote)
                ForEach(Array(item["options"].array.enumerated()), id: \.offset) { i, o in
                    Button(o.string ?? "") { send(index: i) }
                }
                // Dictation and scribble come with the watch's text field.
                TextField("Reply", text: $reply)
                    .onSubmit { if !reply.isEmpty { send(text: reply) } }
            }
        }
    }

    private func send(index: Int? = nil, text: String? = nil) {
        guard let id = item["id"].string else { return }
        Task { await model.answerQuestion(id: id, index: index, text: text); dismiss() }
    }
}
