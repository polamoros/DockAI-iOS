import Foundation

/// An error the server answered with — its own message, shown as the web shows it.
struct TRPCError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// DockAI's API is tRPC with superjson: a query is
/// `GET /api/trpc/<path>?input={"json":…}`, a mutation `POST` with body
/// `{"json":…}`, and the answer is `{"result":{"data":{"json":…}}}`. Dates
/// arrive as ISO strings inside `json`; superjson's `meta` is ignored.
/// The device token is sent as a bearer token.
final class TRPCClient {
    let credentials: Credentials
    private let session: URLSession

    init(credentials: Credentials) {
        self.credentials = credentials
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: cfg)
    }

    func query(_ path: String, _ input: JSON = .null) async throws -> JSON {
        var comps = URLComponents(url: credentials.server.appendingPathComponent("api/trpc/\(path)"), resolvingAgainstBaseURL: false)!
        if input != .null {
            let body = try JSONEncoder().encode(JSON.object(["json": input]))
            comps.queryItems = [URLQueryItem(name: "input", value: String(data: body, encoding: .utf8))]
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        return try await send(req)
    }

    func mutate(_ path: String, _ input: JSON = .null) async throws -> JSON {
        var req = URLRequest(url: credentials.server.appendingPathComponent("api/trpc/\(path)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSON.object(["json": input]))
        return try await send(req)
    }

    /// Plain JSON endpoints outside tRPC (`/api/devices/*`).
    func post(_ path: String, _ body: JSON) async throws -> JSON {
        var req = URLRequest(url: credentials.server.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TRPCError(code: "\(http.statusCode)", message: json["error"].string ?? "Request failed (\(http.statusCode)).")
        }
        return json
    }

    /// Plain JSON GET outside tRPC (`/api/devices/push-config`).
    func get(_ path: String) async throws -> JSON {
        var req = URLRequest(url: credentials.server.appendingPathComponent(path))
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TRPCError(code: "\(http.statusCode)", message: json["error"].string ?? "Request failed (\(http.statusCode)).")
        }
        return json
    }

    private func send(_ request: URLRequest) async throws -> JSON {
        var req = request
        req.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let err = json["error"]["json"]
            throw TRPCError(code: err["data"]["code"].string ?? "\(status)", message: err["message"].string ?? "Request failed (\(status)).")
        }
        return json["result"]["data"]["json"]
    }
}

/// Pairing: exchange the one-time code from the QR for a device token.
enum Pairing {
    /// `dockai://pair?server=…&code=…`
    static func parse(_ scanned: String) -> (server: URL, code: String)? {
        guard let comps = URLComponents(string: scanned), comps.scheme == "dockai", comps.host == "pair",
              let s = comps.queryItems?.first(where: { $0.name == "server" })?.value, let server = URL(string: s),
              server.scheme == "https", server.host != nil,
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        return (server, code)
    }

    static func pair(server: URL, code: String, deviceName: String, platform: String = "ios") async throws -> Credentials {
        var req = URLRequest(url: server.appendingPathComponent("api/devices/pair"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSON.from(["code": code, "name": deviceName, "platform": platform]))
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = json["token"].string else {
            throw TRPCError(code: "PAIR", message: json["error"].string ?? "Pairing failed.")
        }
        // Kept so signing out can revoke this device on the server — in the
        // Keychain beside the token, so it survives what the token survives
        // (UserDefaults alone lost it on reinstall, audit 2026-09-26).
        Keychain.set(json["deviceId"].string, for: "deviceId")
        UserDefaults.standard.set(json["deviceId"].string, forKey: "deviceId")
        return Credentials(server: server, token: token)
    }
}
