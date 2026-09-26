// tRPC: project.list, project.start, project.stop, project.restart
import SwiftUI

/// The dashboard: every project you own or were shared, with its state, a
/// restart-owed marker, search, live status from the event stream, and a
/// selection mode for starting and stopping several at once.
struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var store = ProjectsStore()
    @State private var search = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmBulk: String?
    @State private var bulkFailures: [String] = []
    @State private var subscription: UUID?
    @State private var creating = false
    @State private var justCreated: ProjectRoute?

    var body: some View {
        content
            .navigationTitle("Projects")
            .searchable(text: $search, prompt: "Search projects")
            .toolbar { toolbar }
            .refreshable { await store.load(model.api) }
            .task { await store.load(model.api) }
            .onAppear {
                let s = store, m = model
                guard subscription == nil else { return }
                subscription = model.events.on { event in
                    Task { @MainActor in s.handle(event, api: m.api) }
                }
            }
            .onDisappear { if let id = subscription { model.events.off(id); subscription = nil } }
            .navigationDestination(for: ProjectRoute.self) { route in ProjectView(slug: route.slug) }
            .navigationDestination(item: $justCreated) { route in ProjectView(slug: route.slug) }
            .sheet(isPresented: $creating) {
                NavigationStack {
                    NewProjectView { slug in
                        creating = false
                        Task { await store.load(model.api) }
                        justCreated = ProjectRoute(slug: slug)
                    }
                }
            }
            .confirmationDialog(bulkTitle, isPresented: Binding(get: { confirmBulk != nil }, set: { if !$0 { confirmBulk = nil } }), titleVisibility: .visible) {
                if let action = confirmBulk {
                    Button(action.capitalized, role: .destructive) { runBulk(action) }
                }
            }
            .alert("Some projects failed", isPresented: Binding(get: { !bulkFailures.isEmpty }, set: { if !$0 { bulkFailures = [] } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(bulkFailures.joined(separator: "\n")) }
            .alert("Something went wrong", isPresented: Binding(get: { store.error != nil && store.projects != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.error?.localizedDescription ?? "") }
    }

    @ViewBuilder private var content: some View {
        if let projects = store.projects {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "cpu")
                } description: {
                    Text("Create your first project to get started.")
                } actions: {
                    Button("Create project") { creating = true }.buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        } else if let error = store.error {
            // A failed list is not an empty one.
            ErrorBanner(error: error) { Task { await store.load(model.api) } }.padding()
            Spacer()
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        let rows = store.sorted(matching: search)
        let running = (store.projects ?? []).filter { store.status($0) == "RUNNING" }.count
        return List {
            Section {
                ForEach(rows, id: \.self) { p in row(p) }
            } header: {
                if selecting {
                    HStack {
                        Text("\(selected.count) selected")
                        Spacer()
                        Button(selected.count == rows.count ? "Deselect all" : "Select all") {
                            selected = selected.count == rows.count ? [] : Set(rows.compactMap { $0["id"].string })
                        }.font(.footnote).textCase(nil)
                    }
                } else {
                    Text("\(running) of \(store.projects?.count ?? 0) running")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder private func row(_ p: JSON) -> some View {
        let id = p["id"].string ?? ""
        let status = store.status(p)
        if selecting {
            Button { toggle(id) } label: {
                HStack {
                    Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(id) ? Color.accentColor : .secondary).font(.title3)
                    ProjectListRow(project: p, status: status)
                }
            }.buttonStyle(.plain)
        } else {
            NavigationLink(value: ProjectRoute(slug: p["slug"].string ?? "")) {
                ProjectListRow(project: p, status: status, busy: store.busyIds.contains(id))
            }
            .contextMenu {
                Button { selecting = true; selected = [id] } label: { Label("Select", systemImage: "checkmark.circle") }
                if Proj.canDrive(p) && Proj.startable(status) {
                    Button { Task { await store.act("start", id: id, api: model.api) } } label: { Label("Start", systemImage: "play") }
                }
                if Proj.canDrive(p) && status == "RUNNING" {
                    Button { Task { await store.act("restart", id: id, api: model.api) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { Task { await store.act("stop", id: id, api: model.api) } } label: { Label("Stop", systemImage: "stop") }
                }
            }
            .swipeActions(edge: .trailing) {
                if Proj.canDrive(p) && Proj.startable(status) {
                    Button { Task { await store.act("start", id: id, api: model.api) } } label: { Label("Start", systemImage: "play.fill") }.tint(.green)
                } else if Proj.canDrive(p) && status == "RUNNING" {
                    Button(role: .destructive) { Task { await store.act("stop", id: id, api: model.api) } } label: { Label("Stop", systemImage: "stop.fill") }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if bulkLocked { ProgressView() }
                Button { runBulk("start") } label: { Label("Start", systemImage: "play") }
                    .disabled(bulkLocked || !selectedProjects.contains { Proj.startable(store.status($0)) })
                Button { confirmBulk = "stop" } label: { Label("Stop", systemImage: "stop") }
                    .disabled(bulkLocked || !selectedProjects.contains { store.status($0) == "RUNNING" })
                Button { confirmBulk = "restart" } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .disabled(bulkLocked || !selectedProjects.contains { store.status($0) == "RUNNING" })
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { exitSelection() }.disabled(store.bulkRunning)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if (store.projects?.count ?? 0) > 1 {
                    Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                }
                Button { creating = true } label: { Label("New project", systemImage: "plus") }
            }
        }
    }

    /// Locked while a bulk request is in flight *and* while any selected
    /// project is still starting, stopping or being acted on: the request
    /// returns once the server accepts it, long before the worker is up, and
    /// a second tap then meant a second start or a stop mid-start.
    private var bulkLocked: Bool {
        store.bulkRunning || selectedProjects.contains { p in
            let id = p["id"].string ?? ""
            return store.busyIds.contains(id) || ["STARTING", "CREATING", "STOPPING"].contains(store.status(p) ?? "")
        }
    }

    private var selectedProjects: [JSON] {
        (store.projects ?? []).filter { selected.contains($0["id"].string ?? "") && Proj.canDrive($0) }
    }

    private var bulkTitle: String {
        guard let a = confirmBulk else { return "" }
        let n = selectedProjects.filter { store.status($0) == "RUNNING" }.count
        return a == "restart"
            ? "Restart \(n) project\(n == 1 ? "" : "s")? Their workers are recreated; conversations take a minute to come back."
            : "Stop \(n) project\(n == 1 ? "" : "s")?"
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func exitSelection() { selecting = false; selected = [] }

    /// Each action applies to the selected projects it makes sense for —
    /// Start to the stopped ones, Stop and Restart to the running ones.
    private func runBulk(_ action: String) {
        let targets = selectedProjects.filter { action == "start" ? Proj.startable(store.status($0)) : store.status($0) == "RUNNING" }
        Task {
            let failures = await store.bulk(action, projects: targets, api: model.api)
            bulkFailures = failures.map { "\(action.capitalized) failed — \($0)" }
            exitSelection()
        }
    }
}

/// A project to open — its own type, so this stack's destination cannot
/// collide with a plain `String` route another screen registers.
struct ProjectRoute: Hashable, Identifiable {
    let slug: String
    var id: String { slug }
}
