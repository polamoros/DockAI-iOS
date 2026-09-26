// tRPC: project.update, project.getBySlug, project.restart
import SwiftUI

/// Settings → Worker (WorkerSettings.tsx): everything the entrypoint bakes in
/// at creation — network firewall (§16), image, memory, packages, variables.
/// Saving any of them on a running project owes a worker restart.
struct PSWorkerSettings: View {
    let slug: String
    let onChange: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var box: PSProjectBox
    @StateObject private var action = Action()
    @State private var networkMode = "full"
    @State private var allowedHosts = ""
    @State private var customImage = ""
    @State private var memory = ""
    @State private var packages = ""
    @State private var workerEnv = ""
    @State private var saved = false
    @State private var loaded = false

    init(slug: String, project: JSON, onChange: @escaping () -> Void) {
        self.slug = slug
        self.onChange = onChange
        _box = StateObject(wrappedValue: PSProjectBox(project))
    }

    private var p: JSON { box.project }

    private var values: [String: JSON] {
        [
            "networkMode": .string(networkMode),
            "networkAllowedHosts": .array(PSPatch.lines(allowedHosts).map(JSON.string)),
            "customWorkerImage": .string(customImage.trimmingCharacters(in: .whitespaces)),
            "memoryLimitMb": Int(memory.trimmingCharacters(in: .whitespaces)).map { JSON.number(Double($0)) } ?? .null,
            "extraPackages": .string(packages),
            "workerEnv": .string(workerEnv),
        ]
    }

    private var patch: [String: JSON] {
        PSPatch.changed(values, project: p, defaults: [
            "networkMode": .string("full"), "networkAllowedHosts": .array([]),
            "customWorkerImage": .string(""), "extraPackages": .string(""), "workerEnv": .string(""),
        ])
    }

    /// The server's own rule (createProjectSchema.workerEnv), said before the press.
    private var envError: String? {
        for line in workerEnv.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            if l.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) == nil {
                return "Each line must be KEY=VALUE (letters, digits and _ in the key)"
            }
        }
        return nil
    }

    var body: some View {
        Form {
            PSRestartOwedSection(project: p) { Task { await box.reload(model.api, slug: slug); onChange() } }

            Section {
                Picker("Local network", selection: $networkMode) {
                    Text("Internet only (no LAN)").tag("internet")
                    Text("Internet + specific hosts").tag("custom")
                    Text("Full local network").tag("full")
                }
                if networkMode == "custom" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allowed hosts").font(.subheadline.weight(.medium))
                        TextEditor(text: $allowedHosts)
                            .font(.system(.footnote, design: .monospaced)).frame(minHeight: 80)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("One IP, IP:port or CIDR per line — names are not resolved. e.g. 192.168.1.50:8123")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("What this project can reach on your local network; the internet and package registries always work.")
            }
            .ownerOnly(p)

            Section {
                TextField("e.g. node:22, python:3.12", text: $customImage)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Custom image")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replaces the standard worker image. It must still run the entrypoint, so start from the worker image or a close relative.")
                    PSOwnerOnlyNote(project: p)
                }
            }
            .ownerOnly(p)

            Section("Resources and packages") {
                LabeledContent {
                    TextField("Server default", text: $memory).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                } label: {
                    PSLabel(title: "Memory limit (MB)", detail: "A worker over its limit is killed, not throttled; empty uses the server default. At least 512.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra packages").font(.subheadline.weight(.medium))
                    TextField("e.g. php redis-tools npm:tsx npm:prisma", text: $packages)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Installed on every worker start. Apt packages by name, npm packages with an npm: prefix.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Worker variables").font(.subheadline.weight(.medium))
                    TextEditor(text: $workerEnv)
                        .font(.system(.footnote, design: .monospaced)).frame(minHeight: 90)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .ownerOnly(p)
                    PSOwnerOnlyNote(project: p)
                    Text("KEY=VALUE per line, exported into every shell and process of the worker.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let envError { Text(envError).font(.caption).foregroundStyle(.red) }
                }
            }

            if let dc = p["devcontainerJson"].string, !dc.isEmpty {
                Section {
                    ScrollView(.horizontal) {
                        Text(prettyJSON(dc)).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                } header: {
                    Text("Devcontainer detected")
                } footer: {
                    Text(".devcontainer/devcontainer.json")
                }
            }

            PSSaveSection(
                consequence: PSRestart.consequence(changed: Set(patch.keys), running: p.psRunning),
                busy: action.busy, saved: saved,
                disabled: patch.isEmpty || envError != nil || !p.psCan("configure"), save: save)
        }
        .errorAlert(action)
        .onAppear { if !loaded { fill(); loaded = true } }
    }

    private func prettyJSON(_ s: String) -> String {
        guard let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: out, encoding: .utf8) else { return s }
        return str
    }

    private func fill() {
        networkMode = p["networkMode"].string ?? "full"
        allowedHosts = p["networkAllowedHosts"].array.compactMap(\.string).joined(separator: "\n")
        customImage = p["customWorkerImage"].string ?? ""
        memory = p["memoryLimitMb"].int.map(String.init) ?? ""
        packages = p["extraPackages"].string ?? ""
        workerEnv = p["workerEnv"].string ?? ""
    }

    private func save() {
        guard let id = p["id"].string else { return }
        var input = patch
        guard !input.isEmpty else { return }
        input["id"] = .string(id)
        action.run {
            _ = try await model.api?.mutate("project.update", .object(input))
            await box.reload(model.api, slug: slug)
            fill()
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
            onChange()
        }
    }
}
