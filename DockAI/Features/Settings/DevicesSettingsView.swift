// tRPC: device.list, device.revoke
import SwiftUI

/// Settings → Your devices: the phones that can act as you, this one marked.
/// Pairing a new one needs a signed-in browser (`device.createPairCode` is
/// session-only — a device does not pair other devices), so it happens on
/// the web.
struct DevicesSettingsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var action = Action()
    private var thisDevice: String? { Credentials.deviceId }

    var body: some View {
        Loader(load: { try await model.api?.query("device.list") ?? .array([]) }) { devices, reload in
            List {
                Section {
                    if devices.array.isEmpty {
                        ContentUnavailableView("No devices yet", systemImage: "iphone",
                                               description: Text("Pair the DockAI iOS app to get pushes and control DockAI from your iPhone."))
                    }
                    ForEach(devices.array, id: \.self) { d in row(d, reload: reload) }
                } footer: {
                    Text("To add a device, open Settings → Your devices → Add a device on the web and scan the code with the new phone. Revoking a device revokes its token and stops its pushes.")
                }
                if WatchLink.shared.watchRevoked {
                    Section {
                        Button("Pair Apple Watch again") { WatchLink.shared.pairAgain(); reload() }
                    } footer: {
                        Text("The watch was removed, so it stays signed out until you pair it here.")
                    }
                }
            }
        }
        .navigationTitle("Your devices")
        .errorAlert(action)
    }

    @ViewBuilder private func row(_ d: JSON, reload: @escaping () -> Void) -> some View {
        let id = d["id"].string ?? ""
        let mine = id == thisDevice
        let active = d["active"].bool == true
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(d["name"].string ?? "Device").lineLimit(1)
                if mine { StatePill(text: "This iPhone", tone: .accent) }
                Spacer()
                if !active { StatePill(text: "Revoked") }
                else if d["platform"].string == "watchos" { StatePill(text: "Via iPhone") }
                else if d["push"].bool == true { StatePill(text: "Push on", tone: .ok) }
                else { StatePill(text: "No push") }
            }
            HStack {
                Text(settingsDate(d["lastSeenAt"]).map { "Seen \($0)" } ?? "Not used yet")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if active {
                    ConfirmButton(title: mine ? "Sign out" : "Revoke", confirmTitle: mine ? "Sign out?" : "Revoke?") {
                        if mine {
                            // Revoking this phone is signing out: its token stops working.
                            Task { await model.signOut() }
                        } else {
                            action.run {
                                _ = try await model.api?.mutate("device.revoke", .from(["id": id]))
                                reload()
                            }
                        }
                    }
                    .buttonStyle(.borderless).font(.callout)
                }
            }
        }
    }
}
