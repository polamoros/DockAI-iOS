import Foundation
import Security

/// The device token and server URL, in the Keychain, shared with the widget
/// extension through the app's keychain access group.
enum Keychain {
    private static let service = "ai.dockai.device"

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        // This device only: the token must not travel to another phone in a
        // backup or iCloud Keychain — a restored phone pairs again.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Where this install lives and how the app signs in to it.
struct Credentials: Equatable {
    let server: URL
    let token: String

    static func load() -> Credentials? {
        #if DEBUG
        // The simulator UI tests (DockAIUITests, ci/mock-server.mjs) start
        // the app pointed at a local test server with invented data. Debug
        // builds only: a TestFlight or App Store build has no such door.
        let env = ProcessInfo.processInfo.environment
        if let s = env["DOCKAI_TEST_SERVER"], let url = URL(string: s), let t = env["DOCKAI_TEST_TOKEN"] {
            return Credentials(server: url, token: t)
        }
        #endif
        guard let s = Keychain.get("server"), let url = URL(string: s), let t = Keychain.get("token") else { return nil }
        return Credentials(server: url, token: t)
    }

    func save() {
        Keychain.set(server.absoluteString, for: "server")
        Keychain.set(token, for: "token")
    }

    static func clear() {
        Keychain.set(nil, for: "server")
        Keychain.set(nil, for: "token")
        Keychain.set(nil, for: "deviceId")
        UserDefaults.standard.removeObject(forKey: "deviceId")
    }

    /// This device's id on the server (for revoking it on sign-out).
    static var deviceId: String? { Keychain.get("deviceId") ?? UserDefaults.standard.string(forKey: "deviceId") }
}
