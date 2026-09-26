// tRPC: service.list, service.add, service.remove, service.detectPorts, system.authConfig
import SwiftUI

/// Exposed services (ServicesSection.tsx): running dev servers detected in the
/// worker, one tap to give one a subdomain, and the ones already exposed with
/// Open while their port is actually listening.
struct SvcExposedServices: View {
    let projectId: String
    let slug: String
    let isRunning: Bool
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @StateObject private var action = Action()
    @State private var services: [JSON]?
    @State private var listError: Error?
    /// Exposed services are the project owner's to manage (service.list).
    @State private var ownerOnly = false
    @State private var ports: [JSON] = []
    @State private var detected = false
    @State private var detectError: Error?
    @State private var baseDomain = ""
    @State private var routeFailed = false
    @State private var showAdd = false
    @State private var exposing: JSON?
    @State private var draftName = ""
    @State private var draftPort = ""

    private var activePorts: Set<Int> { Set(ports.compactMap { $0["port"].int }) }
    private var unexposed: [JSON] { ports.filter { $0["alreadyExposed"].bool != true } }

    var body: some View {
        Section {
            if routeFailed {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Saved, but the subdomain is not serving yet — restart the project to register it.").font(.callout)
                    Spacer()
                    Button("Close") { routeFailed = false }.buttonStyle(.borderless).font(.callout)
                }
            }
            if let detectError { ErrorBanner(error: detectError) { Task { await detect() } } }
            if let listError { ErrorBanner(error: listError) { Task { await load() } } }
            if ownerOnly {
                Text("Only the project's owner manages exposed services.").font(.callout).foregroundStyle(.secondary)
            }

            if !unexposed.isEmpty {
                Text("Detected ports").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(unexposed, id: \.self) { p in detectedRow(p) }
            }

            if let services {
                if !services.isEmpty {
                    HStack {
                        Text("Exposed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if !isRunning { StatePill(text: "Project stopped", tone: .warn) }
                    }
                    ForEach(services, id: \.self) { s in serviceRow(s) }
                } else if unexposed.isEmpty && (!isRunning || detected) && detectError == nil {
                    Text("No services detected — run a dev server in a terminal and it appears here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if listError == nil {
                ProgressView()
            }

            if !ownerOnly {
                Button { showAdd = true } label: { Label("Add a service", systemImage: "plus") }
            }
        } header: {
            Text("Exposed services")
        } footer: {
            Text("A service you expose gets a public subdomain; running dev servers appear here.")
        }
        .errorAlert(action)
        .task { await load() }
        .task(id: isRunning) {
            // The web's cadence: every 30s while the project runs.
            guard isRunning else { ports = []; return }
            while !Task.isCancelled {
                await detect()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: Binding(get: { exposing.map(SvcPortBox.init) }, set: { exposing = $0?.port })) { box in
            exposeSheet(box.port)
        }
    }

    // MARK: rows

    private func detectedRow(_ p: JSON) -> some View {
        let port = p["port"].int ?? 0
        let process = p["process"].string ?? ""
        let generic = process.hasPrefix("Port ")
        return HStack {
            Circle().fill(.green).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(generic ? "Port \(port)" : process).lineLimit(1)
                Text(":\(port)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Expose") { draftName = p["name"].string ?? "service"; exposing = p }
                .buttonStyle(.bordered).controlSize(.small).disabled(action.busy)
        }
    }

    private func serviceRow(_ s: JSON) -> some View {
        let port = s["internalPort"].int ?? 0
        let alive = isRunning && activePorts.contains(port)
        let name = s["name"].string ?? ""
        return HStack {
            Circle().fill(alive ? Color.green : Color.secondary).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(":\(port)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    if isRunning && !alive { StatePill(text: "Not running", tone: .warn) }
                }
            }
            Spacer()
            if alive, let url = url(name: name, subdomain: s["subdomain"].string ?? "\(name)-\(slug)") {
                Button { openURL(url) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.bordered).controlSize(.small).tint(.accentColor)
            }
        }
        .swipeActions {
            Button("Disable", role: .destructive) {
                guard let id = s["id"].string else { return }
                action.run {
                    _ = try await model.api?.mutate("service.remove", .from(["id": id]))
                    await load(); await detect()
                }
            }
        }
        .contextMenu {
            if let url = url(name: name, subdomain: s["subdomain"].string ?? "\(name)-\(slug)") {
                Button { UIPasteboard.general.url = url } label: { Label("Copy link", systemImage: "link") }
            }
        }
    }

    // MARK: sheets

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. vite-dev", text: $draftName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("5173", text: $draftPort).keyboardType(.numberPad).font(.system(.body, design: .monospaced))
                } footer: { publicWarning }
            }
            .navigationTitle("Add a service").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAdd = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let port = Int(draftPort), (1...65535).contains(port), !draftName.isEmpty else { return }
                        add(name: draftName, port: port) { showAdd = false; draftName = ""; draftPort = "" }
                    }
                    .disabled(draftName.isEmpty || Int(draftPort) == nil || action.busy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func exposeSheet(_ p: JSON) -> some View {
        let port = p["port"].int ?? 0
        let safe = SvcName.safe(draftName)
        return NavigationStack {
            Form {
                Section {
                    TextField("Service name", text: $draftName).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accessible at \(label(name: safe, subdomain: "\(safe)-\(slug)"))").font(.system(.caption, design: .monospaced))
                        publicWarning
                    }
                }
            }
            .navigationTitle("Expose :\(port)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { exposing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Expose") { add(name: draftName, port: port) { exposing = nil } }
                        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || action.busy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var publicWarning: some View {
        Label("Anyone with the link reaches it with no password, so never expose a database or an admin panel.", systemImage: "exclamationmark.shield")
            .foregroundStyle(.orange)
    }

    // MARK: URLs — the same rule as the web dashboard

    private func url(name: String, subdomain: String) -> URL? {
        guard let server = model.credentials?.server else { return nil }
        if !baseDomain.isEmpty {
            return URL(string: "\(server.scheme ?? "https")://\(subdomain).\(baseDomain)")
        }
        return server.appendingPathComponent("api/services/\(slug)/\(name)/")
    }

    private func label(name: String, subdomain: String) -> String {
        baseDomain.isEmpty ? "/\(slug)/\(name)" : "\(subdomain).\(baseDomain)"
    }

    // MARK: data

    private func add(name: String, port: Int, done: @escaping () -> Void) {
        let safe = SvcName.safe(name)
        action.run {
            let r = try await model.api?.mutate("service.add", .from(["projectId": projectId, "name": safe, "internalPort": port])) ?? .null
            // Exposed is not the same as reachable: a route that failed to register is said here.
            routeFailed = !(r["routeFailed"].isNull)
            done()
            await load(); await detect()
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        if baseDomain.isEmpty, let cfg = try? await api.query("system.authConfig") { baseDomain = cfg["baseDomain"].string ?? "" }
        do { services = try await api.query("service.list", .from(["projectId": projectId])).array; listError = nil }
        catch let e as TRPCError where e.code == "FORBIDDEN" || e.code == "NOT_FOUND" {
            services = []; listError = nil; ownerOnly = true
        } catch { listError = error }
    }

    private func detect() async {
        guard let api = model.api, isRunning else { return }
        do {
            ports = try await api.query("service.detectPorts", .from(["projectId": projectId]))["ports"].array
            detectError = nil
        } catch { detectError = error }
        detected = true
    }
}

/// `sheet(item:)` needs an Identifiable; a detected port is identified by its number.
private struct SvcPortBox: Identifiable {
    let port: JSON
    var id: Int { port["port"].int ?? 0 }
}
