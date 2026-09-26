import UserNotifications

/// Gives a push its real button titles.
///
/// The app registers fixed categories (PushCoordinator.categories) whose
/// action titles are placeholders — "Option 1", "Button 1" — because iOS
/// takes a category's actions from what was registered, not from the push.
/// The server sends the real labels in the payload (`dockai.options` for an
/// ask, `dockai.buttons` for an automation result: "Run again", "Pause",
/// then the automation's own), so this extension registers a category for
/// this one message, with those titles, and points the notification at it.
///
/// The action identifiers are the ones PushCoordinator maps back to
/// `/api/devices/action`: "opt0"…"opt3" and "reply" for an ask; "run",
/// "pause", "b0"…"b2" for an automation. The per-message category is named
/// `<base category>:<request id>` so its base stays readable by prefix.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    /// How many per-message categories to keep registered. Older ones belong
    /// to notifications long since answered or cleared.
    private static let keep = 30
    private static let storeKey = "dockai.messageCategories"

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.content = content

        let info = content.userInfo["dockai"] as? [String: Any] ?? [:]
        let base = content.categoryIdentifier
        guard let actions = Self.actions(category: base, info: info) else {
            contentHandler(content)
            return
        }

        let identifier = "\(base):\(request.identifier)"
        let category = UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            // Merge: the app's fixed categories stay, recent per-message ones stay, this one is added.
            let recent = Self.remember(identifier)
            let kept = existing.filter { !$0.identifier.contains(":") || recent.contains($0.identifier) }
            center.setNotificationCategories(kept.union([category]))
            content.categoryIdentifier = identifier
            // Registration is asynchronous; reading the categories back waits for it,
            // so the notification is not shown before its category exists.
            center.getNotificationCategories { _ in contentHandler(content) }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Out of time: deliver what we have (the fixed category still answers taps).
        if let contentHandler, let content { contentHandler(content) }
    }

    /// The actions for this message, or nil to leave the fixed category as it is.
    static func actions(category: String, info: [String: Any]) -> [UNNotificationAction]? {
        switch category {
        case "DOCKAI_ASK":
            let options = (info["options"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
            // No options: the question wants a typed answer, and "Option 1…4" would be wrong.
            let reply = UNTextInputNotificationAction(identifier: "reply", title: options.isEmpty ? "Reply" : "Other answer", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Answer")
            return options.prefix(4).enumerated().map { UNNotificationAction(identifier: "opt\($0.offset)", title: $0.element) } + [reply]
        case "DOCKAI_AUTOMATION":
            // Positional, as the server builds them: Run again, Pause, then up to three of the automation's own.
            guard let labels = (info["buttons"] as? [Any])?.compactMap({ $0 as? String }), !labels.isEmpty else { return nil }
            var actions: [UNNotificationAction] = []
            for (i, label) in labels.enumerated() {
                switch i {
                case 0: actions.append(UNNotificationAction(identifier: "run", title: label))
                case 1: actions.append(UNNotificationAction(identifier: "pause", title: label))
                case 2...4: actions.append(UNNotificationAction(identifier: "b\(i - 2)", title: label))
                default: break
                }
            }
            return actions
        default:
            return nil
        }
    }

    /// Record a per-message category and return the ones still worth keeping.
    private static func remember(_ identifier: String) -> Set<String> {
        let defaults = (Bundle.main.object(forInfoDictionaryKey: "DockAIAppGroup") as? String).flatMap(UserDefaults.init(suiteName:)) ?? .standard
        var list = defaults.stringArray(forKey: storeKey) ?? []
        list.append(identifier)
        if list.count > keep { list.removeFirst(list.count - keep) }
        defaults.set(list, forKey: storeKey)
        return Set(list)
    }
}
