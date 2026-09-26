import SwiftUI

/// Projects, Settings and — for admins — Admin: the web's three top-level
/// places, as tabs.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView {
            NavigationStack { ProjectsView() }
                .tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
            if model.isAdmin {
                NavigationStack { AdminView() }
                    .tabItem { Label("Admin", systemImage: "server.rack") }
            }
        }
        .task { await model.refreshMe() }
        .sheet(item: Binding(get: { model.openProject.map(OpenSlug.init) }, set: { model.openProject = $0?.id })) { o in
            NavigationStack { ProjectView(slug: o.id) }
        }
    }
}

private struct OpenSlug: Identifiable { let id: String }

/// A project's eight tabs, as on the web: Overview · Conversations · Terminal ·
/// Agent · Browser · Services · Logs · Settings.
enum ProjectTab: String, CaseIterable, Identifiable {
    case overview, conversations, terminal, agent, browser, services, logs, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"; case .conversations: "Conversations"; case .terminal: "Terminal"; case .agent: "Agent"
        case .browser: "Browser"; case .services: "Services"; case .logs: "Logs"; case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"; case .conversations: "bubble.left.and.bubble.right"; case .terminal: "terminal"; case .agent: "cpu"
        case .browser: "globe"; case .services: "powerplug"; case .logs: "doc.plaintext"; case .settings: "gearshape"
        }
    }
}

/// The project screen: its header and a scrollable tab strip over the tab's content.
struct ProjectView: View {
    let slug: String
    @EnvironmentObject var model: AppModel
    @State private var tab: ProjectTab = .overview
    @State private var project: JSON = .null

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ProjectTab.allCases) { t in
                        Button { tab = t } label: {
                            Label(t.title, systemImage: t.icon).font(.subheadline)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(tab == t ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                        .accessibilityIdentifier("tab-\(t.rawValue)")
                    }
                }.padding(.horizontal).padding(.vertical, 6)
            }
            Divider()
            Group {
                switch tab {
                case .overview: ProjectOverviewView(slug: slug, project: project)
                case .conversations: ConversationsView(slug: slug, project: project)
                case .terminal: TerminalTabView(slug: slug, project: project)
                case .agent: AgentView(slug: slug, project: project)
                case .browser: BrowserTabView(slug: slug, project: project)
                case .services: ServicesView(slug: slug, project: project)
                case .logs: LogsView(slug: slug, project: project)
                case .settings: ProjectSettingsView(slug: slug, project: project, onChange: { Task { await load() } })
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(project["name"].string ?? slug)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ProjectPowerMenu(project: project, onDone: { Task { await load() } }) } }
        .task { await load() }
        // Live: a start or stop from anywhere (Overview, the web, the watch,
        // the health check) reaches every tab. It loaded once, so the
        // Terminal tab kept saying "stopped" after a start (audit 2026-09-26).
        .onAppear {
            subscription = model.events.on { event in
                guard let type = event["type"].string, type.hasPrefix("container:") || type == "project:updated",
                      event["projectId"].string == project["id"].string else { return }
                Task { await load() }
            }
        }
        .onDisappear { if let subscription { model.events.off(subscription) } }
        .task {
            // Behind the events, for a stream that dropped: every 30 s.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await load()
            }
        }
    }

    @State private var subscription: UUID?

    private func load() async {
        guard let api = model.api else { return }
        if let p = try? await api.query("project.getBySlug", .from(["slug": slug])) { project = p }
    }
}
