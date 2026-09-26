// tRPC: users.getNotifyPreferences, users.updateNotifyPreferences, telegram.status, telegram.createLinkCode, telegram.confirmChat, telegram.unlink, users.getDeliveryPrefs, users.setDeliveryPref
import SwiftUI

/// Settings → Notifications: the browser switches, Telegram (link, confirm,
/// unlink, what to send) and where each kind arrives — Telegram, push or both.
struct NotificationsSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @StateObject private var action = Action()

    /// Every key the server stores, with the default the web shows for a
    /// missing one. The whole object is sent on every change: the mutation
    /// replaces the stored JSON, so a partial one would reset the rest.
    private static let defaults: [(key: String, value: Bool)] = [
        ("soundEnabled", true), ("browserEnabled", true),
        ("telegramNeedsInput", false), ("telegramAgentRuns", false), ("telegramWorkerErrors", false),
        ("telegramUsage", false), ("telegramAuthExpired", true),
    ]
    private static let telegramKinds: [(key: String, label: String, detail: String)] = [
        ("telegramAuthExpired", "Claude sign-in expired", "A Claude account needs signing in again; its projects cannot start conversations."),
        ("telegramNeedsInput", "Claude needs input", "A conversation is waiting on a permission or an idle prompt."),
        ("telegramAgentRuns", "Agent runs", "A run from the Agent tab or an automation finishes or fails."),
        ("telegramWorkerErrors", "Worker errors", "A project's worker stops unexpectedly."),
        ("telegramUsage", "Usage limits", "An account's weekly window reaches its failover threshold."),
    ]
    private static let deliveryKinds: [(key: String, label: String)] = [
        ("ask", "Questions"), ("permission", "Approvals"), ("automation", "Automation results"), ("notify", "Messages"), ("alert", "Alerts"),
    ]

    @State private var prefs: [String: Bool]?
    @State private var prefsError: Error?
    @State private var telegram: JSON?
    @State private var telegramError: Error?
    @State private var delivery: JSON?
    @State private var linkCode: String?

    var body: some View {
        List {
            channelsSection
            telegramSection
            deliverySection
            if let chats = telegram?["chats"].array, !chats.isEmpty, prefs != nil {
                Section("Send to Telegram when") {
                    ForEach(Self.telegramKinds.indices, id: \.self) { i in
                        let kind = Self.telegramKinds[i]
                        Toggle(isOn: binding(kind.key)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.label)
                                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            browserSection
        }
        .navigationTitle("Notifications")
        .disabled(action.busy)
        .errorAlert(action)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Sections

    /// The two switches people look for first: this app, Telegram. They set
    /// every kind at once (users.setDeliveryAll); the per-kind choices below
    /// fine-tune. One always stays on, so a message has somewhere to go.
    @ViewBuilder private var channelsSection: some View {
        if let delivery {
            let kinds = Self.deliveryKinds.map { delivery["prefs"][$0.key].string ?? "both" }
            let appOn = kinds.contains { $0 != "telegram" }
            let telegramOn = kinds.contains { $0 != "push" }
            let canPush = delivery["pushAvailable"].bool == true || (delivery["pushDevices"].int ?? 0) > 0
            Section {
                Toggle("This app", isOn: Binding(get: { appOn }, set: { setAll(push: $0, telegram: telegramOn) }))
                    .disabled(!canPush || (appOn && !telegramOn))
                Toggle("Telegram", isOn: Binding(get: { telegramOn }, set: { setAll(push: appOn, telegram: $0) }))
                    .disabled(telegramOn && !appOn)
            } header: { Text("Send notifications to") } footer: {
                Text(canPush ? "One stays on, so nothing is lost. Choose per kind below." : "The server has no push key yet, so notifications go to Telegram.")
            }
        } else {
            Section { ProgressView() } header: { Text("Send notifications to") }
        }
    }

    private func setAll(push: Bool, telegram: Bool) {
        mutate("users.setDeliveryAll", ["push": push, "telegram": telegram])
    }

    @ViewBuilder private var browserSection: some View {
        Section {
            if let prefsError {
                ErrorBanner(error: prefsError, retry: { Task { await load() } })
            } else if prefs == nil {
                ProgressView()
            } else {
                Toggle(isOn: binding("soundEnabled")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notification sounds")
                        Text("A chime when Claude goes idle.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: binding("browserEnabled")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browser notifications")
                        Text("In the web dashboard; the browser asks for permission there.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("Web dashboard") }
    }

    @ViewBuilder private var telegramSection: some View {
        Section {
            if let telegramError {
                ErrorBanner(error: telegramError, retry: { Task { await load() } })
            } else if let telegram {
                if telegram["configured"].bool != true {
                    // Always present, so the phone path is discoverable on an
                    // install that has no bot yet.
                    Text(model.isAdmin
                         ? "Telegram can reach you when a conversation needs you or a run fails. Add a bot token in Admin → Notifications."
                         : "Telegram can reach you when a conversation needs you or a run fails. An administrator adds the token.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if telegram["chats"].array.isEmpty {
                    linkRows(username: telegram["username"].string)
                } else {
                    ForEach(telegram["chats"].array, id: \.self) { chat in chatRow(chat) }
                }
            } else {
                ProgressView()
            }
        } header: { Text("Telegram") }
    }

    @ViewBuilder private func linkRows(username: String?) -> some View {
        if let linkCode {
            Text("Send this to the bot within 10 minutes:").font(.callout).foregroundStyle(.secondary)
            CopyRow(text: "/start \(linkCode)")
            if let username, let url = URL(string: "https://t.me/\(username)?start=\(linkCode)") {
                Button { openURL(url) } label: { Label("Open @\(username) in Telegram", systemImage: "paperplane") }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("No chat linked")
                Text("Link a chat to get alerts and drive projects from Telegram.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Generate a link code") {
                action.run {
                    guard let api = model.api else { return }
                    let r = try await api.mutate("telegram.createLinkCode")
                    linkCode = r["code"].string
                }
            }
        }
    }

    @ViewBuilder private func chatRow(_ chat: JSON) -> some View {
        let id = chat["id"].string ?? ""
        let pending = chat["pendingConfirm"].bool == true
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "paperplane").foregroundStyle(.secondary)
                Text(chat["username"].string.map { "@\($0)" } ?? "chat \(chatIdText(chat["chatId"]))").lineLimit(1)
                if pending { StatePill(text: "Needs confirming", tone: .warn) }
                Spacer()
            }
            Text(chatIdText(chat["chatId"])).font(.caption.monospaced()).foregroundStyle(.secondary)
            if pending {
                // A chat a session opened is inert until its owner says it is
                // theirs — a personal binding is the whole console.
                Text("A conversation in a project opened this Telegram chat, so it stays inactive until you say it is yours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if pending {
                    Button("It's mine") { mutate("telegram.confirmChat", ["id": id]) }.buttonStyle(.bordered)
                }
                Spacer()
                ConfirmButton(title: "Unlink", confirmTitle: "Unlink?") { mutate("telegram.unlink", ["id": id]) }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var deliverySection: some View {
        // Shown once push is possible here: an APNs key on the server, or a
        // phone already registered.
        if let delivery, delivery["pushAvailable"].bool == true || (delivery["pushDevices"].int ?? 0) > 0 {
            Section {
                ForEach(Self.deliveryKinds.indices, id: \.self) { i in
                    let kind = Self.deliveryKinds[i]
                    Picker(kind.label, selection: Binding(
                        get: { delivery["prefs"][kind.key].string ?? "both" },
                        set: { pref in mutate("users.setDeliveryPref", ["kind": kind.key, "pref": pref]) }
                    )) {
                        Text("Telegram").tag("telegram")
                        Text("Push").tag("push")
                        Text("Both").tag("both")
                    }
                }
            } header: {
                Text("Per kind")
            } footer: {
                Text((delivery["pushDevices"].int ?? 0) > 0
                     ? "For each kind, Telegram, a push to your iPhone, or both."
                     : "Pair an iPhone in Your devices to choose push.")
            }
        }
    }

    // MARK: Data

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { prefs?[key] ?? Self.defaults.first { $0.key == key }?.value ?? false },
            set: { value in
                guard var next = prefs else { return }
                next[key] = value
                let sent = next
                prefs = next // answers at once; a failed save reloads the truth
                action.run {
                    guard let api = model.api else { return }
                    do {
                        _ = try await api.mutate("users.updateNotifyPreferences", .from(sent.mapValues { $0 as Any? }))
                    } catch {
                        await load()
                        throw error
                    }
                }
            }
        )
    }

    private func chatIdText(_ v: JSON) -> String {
        if let s = v.string { return s }
        if let n = v.double { return String(Int64(n)) }
        return "—"
    }

    private func mutate(_ path: String, _ input: [String: Any?]) {
        action.run {
            guard let api = model.api else { return }
            _ = try await api.mutate(path, .from(input))
            await load()
        }
    }

    /// Each section fills in when its own answer arrives: awaiting them in
    /// turn held the whole page on a spinner behind the slowest one.
    private func load() async {
        guard let api = model.api else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                switch await settingsAttempt({ try await api.query("users.getNotifyPreferences") }) {
                case .success(let json):
                    var out: [String: Bool] = [:]
                    for (key, def) in Self.defaults { out[key] = json[key].bool ?? def }
                    prefs = out; prefsError = nil
                case .failure(let e): prefsError = e
                }
            }
            group.addTask { @MainActor in
                switch await settingsAttempt({ try await api.query("telegram.status") }) {
                case .success(let json): telegram = json; telegramError = nil
                case .failure(let e): telegramError = e
                }
            }
            group.addTask { @MainActor in
                if case .success(let json) = await settingsAttempt({ try await api.query("users.getDeliveryPrefs") }) { delivery = json }
            }
        }
    }
}

/// A load that may fail, kept as a value so several can run at once.
func settingsAttempt<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
