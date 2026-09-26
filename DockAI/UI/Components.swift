import SwiftUI

/// Shared building blocks, named after the web's: a state pill, a card, the
/// loading / error / empty states, and a two-tap destructive button.

struct StatePill: View {
    enum Tone { case ok, warn, danger, accent, neutral }
    let text: String
    var tone: Tone = .neutral
    var body: some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
    private var color: Color {
        switch tone { case .ok: .green; case .warn: .orange; case .danger: .red; case .accent: .accentColor; case .neutral: .secondary }
    }
}

/// A project status as the web shows it.
struct StatusPill: View {
    let status: String?
    var body: some View {
        switch status {
        case "RUNNING": StatePill(text: "Running", tone: .ok)
        case "STARTING", "CREATING": StatePill(text: "Starting", tone: .accent)
        case "ERROR": StatePill(text: "Error", tone: .danger)
        case "STOPPED": StatePill(text: "Stopped")
        default: StatePill(text: status?.capitalized ?? "—")
        }
    }
}

struct ErrorBanner: View {
    let error: Error
    var retry: (() -> Void)?
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.localizedDescription).font(.callout)
            Spacer()
            if let retry { Button("Retry", action: retry).font(.callout) }
        }.padding().background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Loads `JSON` from the server and draws loading, error or content.
struct Loader<Content: View>: View {
    let load: () async throws -> JSON
    @ViewBuilder let content: (JSON, @escaping () -> Void) -> Content
    @State private var value: JSON?
    @State private var error: Error?

    var body: some View {
        Group {
            if let value { content(value, reload) }
            else if let error { ErrorBanner(error: error, retry: reload).padding() }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task { await run() }
        .refreshable { await run() }
    }

    private func reload() { Task { await run() } }
    private func run() async {
        do { value = try await load(); error = nil } catch { self.error = error }
    }
}

/// Two taps to do something that cannot be undone, like the web's inline confirm.
struct ConfirmButton: View {
    let title: String
    var confirmTitle: String = "Confirm"
    var role: ButtonRole? = .destructive
    let action: () -> Void
    @State private var armed = false
    var body: some View {
        Button(role: role) {
            if armed { armed = false; action() } else { armed = true }
        } label: { Text(armed ? confirmTitle : title) }
        .onChange(of: armed) { _, a in if a { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { armed = false } } }
    }
}

/// Run a mutation and surface its error as an alert.
@MainActor
final class Action: ObservableObject {
    @Published var error: Error?
    @Published var busy = false
    func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await work() } catch { self.error = error }
            busy = false
        }
    }
}

extension View {
    func errorAlert(_ action: Action) -> some View {
        alert("Something went wrong", isPresented: Binding(get: { action.error != nil }, set: { if !$0 { action.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(action.error?.localizedDescription ?? "") }
    }
}

extension Date {
    var relative: String { RelativeDateTimeFormatter().localizedString(for: self, relativeTo: .now) }
}
