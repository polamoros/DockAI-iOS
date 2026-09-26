// tRPC: project.workerStats
import SwiftUI

/// The worker's CPU, memory, network and processes — a gauge, refreshed every 20s.
struct OverviewWorkerCard: View {
    let slug: String
    @EnvironmentObject var model: AppModel
    @State private var stats: JSON?
    @State private var error: Error?

    var body: some View {
        ProjCard("Worker resources", systemImage: "cpu") {
            if let stats {
                VStack(spacing: 10) {
                    let cpu = stats["cpuPercent"].double ?? 0
                    ProjMeter(label: "CPU", pct: cpu, value: "\(Self.fmt(cpu))%")
                    ProjMeter(label: "Memory", pct: stats["memoryPercent"].double ?? 0,
                              value: "\(stats["memoryUsageMB"].int ?? 0) / \(stats["memoryLimitMB"].int ?? 0) MB")
                    ProjFact(label: "Network", value: "\(Self.fmt(stats["networkRxMB"].double ?? 0)) MB in / \(Self.fmt(stats["networkTxMB"].double ?? 0)) MB out", mono: true)
                    ProjFact(label: "Processes", value: "\(stats["pids"].int ?? 0)", mono: true)
                }
            } else if let error {
                ErrorBanner(error: error) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    static func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let v = try await api.query("project.workerStats", .from(["slug": slug]))
            if v.isNull { error = TRPCError(code: "EMPTY", message: "The worker did not report its resources.") }
            else { stats = v; error = nil }
        } catch { self.error = error }
    }
}
