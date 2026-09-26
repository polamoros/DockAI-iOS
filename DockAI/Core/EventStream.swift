import Foundation

/// The server's live events (`/api/events`, SSE) — the same stream the web
/// dashboard reads for project status, startup steps and run output. Each
/// event is `data: {"type": …, "projectId": …, "data": …}`. Reconnects with a
/// growing delay; the app restarts it when it comes to the foreground.
@MainActor
final class EventStream: ObservableObject {
    @Published private(set) var connected = false
    private var task: Task<Void, Never>?
    private var handlers: [UUID: (JSON) -> Void] = [:]

    func start(_ credentials: Credentials) {
        task?.cancel()
        task = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: credentials.server.appendingPathComponent("api/events"))
                    req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 3600
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    self?.connected = true
                    delay = 1
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let data = payload.data(using: .utf8), let event = try? JSONDecoder().decode(JSON.self, from: data) {
                            self?.dispatch(event)
                        }
                    }
                } catch {}
                self?.connected = false
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    func stop() { task?.cancel(); task = nil; connected = false }

    /// Subscribe; keep the returned id to unsubscribe.
    @discardableResult
    func on(_ handler: @escaping (JSON) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func off(_ id: UUID) { handlers[id] = nil }

    private func dispatch(_ event: JSON) { for h in handlers.values { h(event) } }
}
