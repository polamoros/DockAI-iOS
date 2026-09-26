// tRPC: none (WebSocket /api/ws/browser/<slug>, RFB inside)
import Foundation
import CoreGraphics
import SwiftUI

/// A minimal RFB (VNC) client over DockAI's browser tunnel.
///
/// `/api/ws/browser/<slug>` carries raw RFB in binary WebSocket frames: the
/// orchestrator pipes it to the worker agent's `/v1/browser/vnc`, which pipes
/// it to x11vnc on the worker's loopback (`-localhost -nopw`). Nothing on the
/// way translates, so this speaks RFB itself — RoyalVNCKit only dials TCP
/// sockets of its own (its transport protocol is internal) and its iOS view
/// is unfinished, so bridging it would have meant a loopback TCP relay in the
/// app for a library whose drawing we would still have to write.
///
/// What it implements, per RFC 6143:
/// - handshake at 3.8 (3.3 and 3.7 accepted from the server), security type
///   None — x11vnc runs `-nopw` behind the authenticated tunnel;
/// - ClientInit shared (the agent is on the same display), SetPixelFormat to
///   32bpp little-endian BGRX so the framebuffer is a CGImage as-is;
/// - encodings CopyRect, Raw and the DesktopSize pseudo-encoding (the display
///   is reshaped by `project.browserSize`);
/// - incremental FramebufferUpdateRequest after every update;
/// - PointerEvent and KeyEvent (X11 keysyms); Bell, colour maps and server
///   cut text are read and ignored.
@MainActor
final class RFBClient: ObservableObject {
    enum Phase: Equatable { case idle, connecting, live, lost }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var error: String?
    @Published private(set) var size: CGSize = .zero
    @Published private(set) var desktopName = ""

    private(set) var image: CGImage?
    private var sinks: [UUID: (CGImage) -> Void] = [:]
    private var connection: RFBConnection?
    private var generation = 0
    private var buttons: UInt8 = 0

    // MARK: Lifecycle

    func connect(credentials: Credentials, slug: String) {
        disconnect()
        generation += 1
        let gen = generation
        phase = .connecting
        error = nil
        let conn = RFBConnection(request: dockaiWebSocketRequest(credentials, path: "api/ws/browser/\(slug)"))
        conn.onInit = { [weak self] w, h, name in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.size = CGSize(width: w, height: h)
                self.desktopName = name
                self.phase = .live
            }
        }
        conn.onFrame = { [weak self] image, w, h in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if self.size.width != CGFloat(w) || self.size.height != CGFloat(h) { self.size = CGSize(width: w, height: h) }
                self.image = image
                for sink in self.sinks.values { sink(image) }
            }
        }
        conn.onClose = { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.phase = .lost
                self.error = message
                self.connection = nil
            }
        }
        connection = conn
        conn.start()
    }

    func disconnect() {
        generation += 1
        connection?.stop()
        connection = nil
        if phase != .idle { phase = .idle }
    }

    // MARK: Frames

    /// A screen view registers here; it is handed the latest frame at once.
    func addSink(_ sink: @escaping (CGImage) -> Void) -> UUID {
        let id = UUID()
        sinks[id] = sink
        if let image { sink(image) }
        return id
    }

    func removeSink(_ id: UUID) { sinks[id] = nil }

    // MARK: Input

    /// Move the pointer, with `mask` as the buttons held (1 left, 2 middle,
    /// 4 right, 8/16 wheel up/down, 32/64 wheel left/right).
    func pointer(_ p: CGPoint, mask: UInt8) {
        guard phase == .live else { return }
        let px = Double(p.x).rounded(), py = Double(p.y).rounded()
        let x = UInt16(max(0, min(Double(size.width) - 1, px)))
        let y = UInt16(max(0, min(Double(size.height) - 1, py)))
        buttons = mask
        connection?.send([5, mask, UInt8(x >> 8), UInt8(x & 0xff), UInt8(y >> 8), UInt8(y & 0xff)])
    }

    func click(_ p: CGPoint, button: UInt8 = 1) {
        pointer(p, mask: 0)
        pointer(p, mask: button)
        pointer(p, mask: 0)
    }

    /// One wheel notch: a press and release of the wheel "button".
    func wheel(_ p: CGPoint, button: UInt8) {
        pointer(p, mask: button)
        pointer(p, mask: 0)
    }

    func key(_ keysym: UInt32, down: Bool) {
        guard phase == .live else { return }
        connection?.send([4, down ? 1 : 0, 0, 0,
                          UInt8(keysym >> 24), UInt8((keysym >> 16) & 0xff), UInt8((keysym >> 8) & 0xff), UInt8(keysym & 0xff)])
    }

    func tap(_ keysym: UInt32) {
        key(keysym, down: true)
        key(keysym, down: false)
    }

    /// Text typed on the phone's keyboard, as keysyms.
    func type(_ text: String) {
        for ch in text { tap(Keysym.forCharacter(ch)) }
    }

    /// Paste by typing — the clipboard is the phone's, not the remote's.
    /// 8ms apart, as the web does, so a long paste does not flood x11vnc.
    func pasteTyping(_ text: String) async {
        for ch in text.prefix(4096) {
            tap(Keysym.forCharacter(ch))
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }
}

/// X11 keysyms for what a phone keyboard sends.
enum Keysym {
    static let backspace: UInt32 = 0xff08
    static let tab: UInt32 = 0xff09
    static let enter: UInt32 = 0xff0d
    static let escape: UInt32 = 0xff1b
    static let left: UInt32 = 0xff51
    static let up: UInt32 = 0xff52
    static let right: UInt32 = 0xff53
    static let down: UInt32 = 0xff54
    static let delete: UInt32 = 0xffff

    /// noVNC's rule: Latin-1 maps one to one, everything else goes through
    /// the Unicode range.
    static func forCharacter(_ ch: Character) -> UInt32 {
        if ch == "\n" || ch == "\r" || ch == "\r\n" { return enter }
        if ch == "\t" { return tab }
        let u = ch.unicodeScalars.first?.value ?? 0
        return (0x20...0xff).contains(u) ? u : 0x0100_0000 | u
    }
}

/// The protocol engine. It runs on one task of its own, pulling bytes from
/// the WebSocket as it needs them — RFB is a byte stream, and x11vnc's
/// frames do not line up with messages. The framebuffer is touched only by
/// that task; input is written from the main thread straight to the socket.
final class RFBConnection: @unchecked Sendable {
    var onInit: (@Sendable (Int, Int, String) -> Void)?
    var onFrame: (@Sendable (CGImage, Int, Int) -> Void)?
    var onClose: (@Sendable (String) -> Void)?

    private let request: URLRequest
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private let lock = NSLock()
    private var stopped = false

    // Engine-task state.
    private var inbox: [UInt8] = []
    private var head = 0
    private var width = 0
    private var height = 0
    private var pixels: [UInt8] = []

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3600
        return URLSession(configuration: cfg)
    }()

    init(request: URLRequest) { self.request = request }

    func start() {
        let ws = Self.session.webSocketTask(with: request)
        // A raw full frame of a 1280×800 display is 4 MB in one message.
        ws.maximumMessageSize = 64 * 1024 * 1024
        task = ws
        ws.resume()
        loop = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
            } catch {
                self.finish(RFBConnection.describe(error, ws))
            }
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        loop?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
    }

    func send(_ bytes: [UInt8]) {
        task?.send(.data(Data(bytes))) { _ in }
    }

    private func finish(_ message: String) {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        if !wasStopped { onClose?(message) }
    }

    /// The server's close reason says what went wrong ("Browser not
    /// running", "Worker unreachable"); an HTTP refusal of the upgrade shows
    /// as a failed connection with no close frame.
    private static func describe(_ error: Error, _ ws: URLSessionWebSocketTask) -> String {
        if let e = error as? RFBError { return e.message }
        if let r = ws.closeReason, let s = String(data: r, encoding: .utf8), !s.isEmpty { return s }
        if let http = ws.response as? HTTPURLResponse, http.statusCode >= 400 {
            switch http.statusCode {
            case 401: return "Not signed in to this server."
            case 404: return "This project has no worker."
            case 409: return "The project is not running."
            default: return "The browser tunnel was refused (\(http.statusCode))."
            }
        }
        return "The connection to the browser dropped."
    }

    // MARK: Protocol

    private func run() async throws {
        // ProtocolVersion
        let version = String(decoding: try await read(12), as: UTF8.self)
        guard version.hasPrefix("RFB ") else { throw RFBError("Not an RFB server.") }
        let minor = Int(version.dropFirst(8).prefix(3)) ?? 3
        let use = minor >= 8 ? 8 : (minor >= 7 ? 7 : 3)
        send(Array("RFB 003.00\(use)\n".utf8))

        // Security
        if use == 3 {
            let type = try await u32()
            if type == 0 { throw RFBError(try await reason()) }
            guard type == 1 else { throw RFBError("The screen asks for a password (security type \(type)), which this viewer does not support.") }
        } else {
            let count = Int(try await u8())
            if count == 0 { throw RFBError(try await reason()) }
            let types = try await read(count)
            guard types.contains(1) else {
                throw RFBError("The screen asks for a password (security types \(types.map { String($0) }.joined(separator: ", "))), which this viewer does not support.")
            }
            send([1])
            if use == 8 {
                let result = try await u32()
                if result != 0 { throw RFBError(try await reason()) }
            }
        }

        // ClientInit: shared — the agent is on this display too.
        send([1])

        // ServerInit
        width = Int(try await u16())
        height = Int(try await u16())
        _ = try await read(16) // the server's pixel format; ours replaces it
        let nameLength = Int(try await u32())
        let name = String(decoding: try await read(nameLength), as: UTF8.self)
        pixels = [UInt8](repeating: 0, count: width * height * 4)

        // SetPixelFormat: 32bpp, depth 24, little-endian, true colour,
        // R<<16 G<<8 B — BGRX in memory.
        send([0, 0, 0, 0,
              32, 24, 0, 1,
              0, 255, 0, 255, 0, 255,
              16, 8, 0,
              0, 0, 0])
        // SetEncodings: CopyRect, Raw, DesktopSize (-223).
        let encodings: [Int32] = [1, 0, -223]
        var setEnc: [UInt8] = [2, 0, UInt8(encodings.count >> 8), UInt8(encodings.count & 0xff)]
        for e in encodings {
            let v = UInt32(bitPattern: e)
            setEnc += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        }
        send(setEnc)
        onInit?(width, height, name)
        requestUpdate(incremental: false)

        while !Task.isCancelled {
            let type = try await u8()
            switch type {
            case 0: try await framebufferUpdate()
            case 1: // SetColourMapEntries — not used with true colour
                _ = try await read(1)
                _ = try await u16()
                let n = Int(try await u16())
                _ = try await read(n * 6)
            case 2: break // Bell
            case 3: // ServerCutText
                _ = try await read(3)
                let n = Int(try await u32())
                _ = try await read(n)
            default:
                throw RFBError("The screen sent a message this viewer does not understand (\(type)).")
            }
        }
    }

    private func framebufferUpdate() async throws {
        _ = try await read(1) // padding
        let rects = Int(try await u16())
        for _ in 0..<rects {
            let x = Int(try await u16()), y = Int(try await u16())
            let w = Int(try await u16()), h = Int(try await u16())
            let encoding = Int32(bitPattern: try await u32())
            switch encoding {
            case 0: try await raw(x: x, y: y, w: w, h: h)
            case 1:
                let sx = Int(try await u16()), sy = Int(try await u16())
                copyRect(from: (sx, sy), to: (x, y), w: w, h: h)
            case -223:
                width = w
                height = h
                pixels = [UInt8](repeating: 0, count: w * h * 4)
            default:
                throw RFBError("The screen used an encoding this viewer did not ask for (\(encoding)).")
            }
        }
        if let image = makeImage() { onFrame?(image, width, height) }
        requestUpdate(incremental: true)
    }

    private func raw(x: Int, y: Int, w: Int, h: Int) async throws {
        let rowBytes = w * 4
        try await need(rowBytes * h)
        guard x + w <= width, y + h <= height else { head += rowBytes * h; return }
        inbox.withUnsafeBytes { src in
            pixels.withUnsafeMutableBytes { dst in
                for row in 0..<h {
                    let from = src.baseAddress!.advanced(by: head + row * rowBytes)
                    let to = dst.baseAddress!.advanced(by: ((y + row) * width + x) * 4)
                    to.copyMemory(from: from, byteCount: rowBytes)
                }
            }
        }
        head += rowBytes * h
    }

    private func copyRect(from src: (Int, Int), to dst: (Int, Int), w: Int, h: Int) {
        guard src.0 + w <= width, src.1 + h <= height, dst.0 + w <= width, dst.1 + h <= height else { return }
        let rowBytes = w * 4
        // Rows in the order that never reads one already overwritten.
        let rows: [Int] = dst.1 > src.1 ? Array((0..<h).reversed()) : Array(0..<h)
        pixels.withUnsafeMutableBytes { buf in
            for row in rows {
                let from = buf.baseAddress!.advanced(by: ((src.1 + row) * width + src.0) * 4)
                let to = buf.baseAddress!.advanced(by: ((dst.1 + row) * width + dst.0) * 4)
                memmove(to, from, rowBytes)
            }
        }
    }

    private func requestUpdate(incremental: Bool) {
        let w = UInt16(min(width, 65535)), h = UInt16(min(height, 65535))
        send([3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(w >> 8), UInt8(w & 0xff), UInt8(h >> 8), UInt8(h & 0xff)])
    }

    private func makeImage() -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Reading

    /// Pull WebSocket messages until `n` unread bytes are buffered.
    private func need(_ n: Int) async throws {
        while inbox.count - head < n {
            try Task.checkCancellation()
            if head > 0 && (head == inbox.count || head > 8 * 1024 * 1024) {
                inbox.removeSubrange(0..<head)
                head = 0
            }
            guard let ws = task else { throw CancellationError() }
            switch try await ws.receive() {
            case .data(let d): inbox.append(contentsOf: d)
            case .string(let s): inbox.append(contentsOf: Array(s.utf8))
            @unknown default: break
            }
        }
    }

    private func read(_ n: Int) async throws -> [UInt8] {
        try await need(n)
        let out = Array(inbox[head..<head + n])
        head += n
        return out
    }

    private func u8() async throws -> UInt8 { try await read(1)[0] }

    private func u16() async throws -> UInt16 {
        let b = try await read(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    private func u32() async throws -> UInt32 {
        let b = try await read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func reason() async throws -> String {
        let n = Int(try await u32())
        return String(decoding: try await read(n), as: UTF8.self)
    }
}

struct RFBError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
