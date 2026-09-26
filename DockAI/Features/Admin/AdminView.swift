// tRPC: none directly — each section names its own procedures.
import SwiftUI

/// Admin, sub-paged like the web (pages/Admin.tsx): Overview and Users, then
/// Operations (Deploy, Access, Backups), then Policy (Authentication,
/// Notifications, Experimental). Only drawn for admins (RootView).
struct AdminView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { AdminOverviewView() } label: { Label("Overview", systemImage: "server.rack") }
                NavigationLink { AdminUsersView() } label: { Label("Users", systemImage: "person.2") }
            }
            Section("Operations") {
                NavigationLink { AdminDeployView() } label: { Label("Deploy", systemImage: "paperplane") }
                NavigationLink { AdminAccessView() } label: { Label("Access", systemImage: "key") }
                NavigationLink { AdminBackupsView() } label: { Label("Backups", systemImage: "archivebox") }
            }
            Section("Policy") {
                NavigationLink { AdminSecurityView() } label: { Label("Authentication", systemImage: "shield") }
                NavigationLink { AdminNotificationsView() } label: { Label("Notification service", systemImage: "bell") }
                NavigationLink { AdminExperimentalView() } label: { Label("Experimental", systemImage: "flask") }
            }
        }
        .navigationTitle("Admin")
    }
}

// MARK: - Small shared pieces for the Admin screens

enum AdminFormat {
    static func bytes(_ b: Double) -> String {
        let gb = b / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", b / 1_048_576)
    }

    /// `2d 4h`, `3h 12m`, `5m`, `<1m` — as the web's worker list.
    static func uptime(since start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        let m = s / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func dateTime(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The state of an updater run (DockAI's own deploy or a deploy target's).
struct AdminDeployStatePill: View {
    let state: String?
    var exitCode: Int?
    var restarting = false
    var body: some View {
        if restarting { StatePill(text: "Orchestrator restarting…", tone: .warn) }
        else if state == "running" { StatePill(text: "Deploying…", tone: .warn) }
        else if state == "done" { StatePill(text: "Last deploy succeeded", tone: .ok) }
        else if state == "failed" { StatePill(text: "Last deploy failed (exit \(exitCode.map(String.init) ?? "?"))", tone: .danger) }
    }
}

/// A log behind a disclosure, open while the thing producing it is running.
struct AdminLogDisclosure: View {
    let title: String
    let log: String
    let running: Bool
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(title, isExpanded: Binding(get: { expanded || running }, set: { expanded = $0 })) {
            ScrollView {
                Text(log).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: 260)
        }
    }
}

/// Copy text with a short confirmation.
struct AdminCopyButton: View {
    let text: String
    var title = "Copy"
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: { Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc") }
    }
}
