import Foundation

/// The last answer a screen got, shown the moment it opens again while a
/// fresh one loads in the background.
///
/// Every screen used to start from a spinner: the Overview's conversations
/// card and the Conversations tab each fetched the same list separately, and
/// each visit waited for the server again (2026-09-25). Kept in memory and in
/// the Caches directory, so it also survives relaunching the app; the system
/// may clear that directory, which only costs one spinner.
@MainActor
enum ScreenCache {
    private static var memory: [String: JSON] = [:]

    private static var dir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("screens", isDirectory: true)
    }

    private static func file(_ key: String) -> URL? {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return dir?.appendingPathComponent(String(safe) + ".json")
    }

    static func get(_ key: String) -> JSON? {
        if let hit = memory[key] { return hit }
        guard let url = file(key), let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(JSON.self, from: data) else { return nil }
        memory[key] = value
        return value
    }

    static func set(_ key: String, _ value: JSON) {
        memory[key] = value
        guard let dir, let url = file(key), let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// On sign-out: another account's projects must not flash up.
    static func clear() {
        memory = [:]
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }
}
