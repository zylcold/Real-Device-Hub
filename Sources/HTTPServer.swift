import Foundation
import Network
import CryptoKit

/// Minimal HTTP + WebSocket server on a single port.
///
/// Routes:
///   GET /                 the dashboard
///   GET /vendor/…         vendored front-end assets
///   GET /api/devices      JSON list of live devices
///   GET /ws?udid=<key>    one video stream for that device
///
/// One viewer per device — a second connection to the same key replaces the
/// first.
final class HTTPServer {
    var onViewerConnected: ((WebSocketConnection, _ deviceKey: String, _ screen: Int) -> Void)?
    var onViewerDisconnected: ((WebSocketConnection, _ deviceKey: String, _ screen: Int) -> Void)?
    /// JSON body for `/api/devices`, or nil to 503.
    var devicesJSON: (() async -> String?)?
    /// Fired once the listener is accepting connections.
    var onReady: (() -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "com.realddevicehub.httpserver")
    private var listener: NWListener?
    private var browserRoot: URL?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        browserRoot = Browser.root
        if browserRoot == nil {
            print("[HTTP] Could not find the browser/ directory. Tried:")
            for path in Browser.candidates { print("[HTTP]   \(path)") }
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[HTTP] Listening on http://localhost:\(self?.port ?? 0)")
                self?.onReady?()
            case .failed(let err): print("[HTTP] Listener failed: \(err)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak conn] state in
            if case .failed = state { conn?.cancel() }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// Read until we have a full HTTP request header block (`\r\n\r\n`).
    /// Bounded at 16 KB to fend off malformed clients.
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil {
                conn.cancel()
                return
            }
            guard let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            var buf = buffer
            buf.append(data)
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerEnd = range.upperBound
                let headers = buf.prefix(upTo: headerEnd)
                self.dispatch(conn, headers: Data(headers))
                return
            }
            if buf.count > 16_384 {
                self.respond(conn, status: 431, body: "Request Header Fields Too Large")
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func dispatch(_ conn: NWConnection, headers raw: Data) {
        guard let text = String(data: raw, encoding: .utf8) else {
            conn.cancel()
            return
        }
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        let isWS = (headers["upgrade"]?.lowercased() == "websocket")
            && (headers["connection"]?.lowercased().contains("upgrade") == true)

        let (route, query) = split(path)

        if isWS && route == "/ws" {
            guard let deviceKey = query["udid"], !deviceKey.isEmpty else {
                respond(conn, status: 400, body: "Missing ?udid=")
                return
            }
            guard let key = headers["sec-websocket-key"] else {
                respond(conn, status: 400, body: "Missing Sec-WebSocket-Key")
                return
            }
            let screen = Int(query["screen"] ?? "") ?? 0
            upgradeToWebSocket(conn, key: key, deviceKey: deviceKey, screen: screen)
            return
        }

        if method == "GET" && route == "/api/devices" {
            guard let provider = devicesJSON else {
                respond(conn, status: 503, body: "devices unavailable")
                return
            }
            Task {
                guard let json = await provider() else {
                    respond(conn, status: 503, body: "devices unavailable")
                    return
                }
                respond(conn, status: 200, body: json, contentType: "application/json; charset=utf-8")
            }
            return
        }

        if method == "GET" && (route == "/" || route == "/index.html") {
            serveFile(conn, at: "index.html", contentType: "text/html; charset=utf-8")
            return
        }

        if method == "GET" && route.hasPrefix("/vendor/") {
            serveFile(conn, at: String(route.dropFirst()), contentType: contentType(for: route))
            return
        }

        respond(conn, status: 404, body: "Not Found")
    }

    /// "/ws?udid=ABC" -> ("/ws", ["udid": "ABC"])
    private func split(_ target: String) -> (String, [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        let route = String(target[target.startIndex..<mark])
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            query[String(name)] = value.removingPercentEncoding ?? value
        }
        return (route, query)
    }

    // MARK: - WebSocket upgrade

    private func upgradeToWebSocket(_ conn: NWConnection, key: String, deviceKey: String, screen: Int) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let hash = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(hash).base64EncodedString()

        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """

        conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if let err = err {
                print("[HTTP] handshake send failed: \(err)")
                conn.cancel()
                return
            }
            let ws = WebSocketConnection(connection: conn)
            ws.onClose = { [weak self, weak ws] in
                if let ws = ws { self?.onViewerDisconnected?(ws, deviceKey, screen) }
            }
            self.onViewerConnected?(ws, deviceKey, screen)
            ws.start()
        })
    }

    // MARK: - Static files

    private func serveFile(_ conn: NWConnection, at relative: String, contentType: String) {
        guard let root = browserRoot,
              let data = Browser.read(relative, under: root) else {
            respond(conn, status: 404, body: "Not Found")
            return
        }
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(data.count)\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(data)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func contentType(for path: String) -> String {
        if path.hasSuffix(".js") || path.hasSuffix(".mjs") { return "text/javascript; charset=utf-8" }
        if path.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if path.hasSuffix(".map") || path.hasSuffix(".json") { return "application/json" }
        if path.hasSuffix(".svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }

    private func respond(_ conn: NWConnection, status: Int, body: String, contentType: String = "text/plain; charset=utf-8") {
        let reason = HTTPServer.reasonPhrase(status)
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(bodyData)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default:  return "Status"
        }
    }
}

/// Locates the `browser/` directory shipped next to the binary or in the source
/// tree, and reads files out of it.
enum Browser {
    static let candidates: [String] = [
        // Running from the source tree (`swift run`, `.build/…/RealDeviceHub`).
        "browser",
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("../../../browser").standardized.path,
        // Installed layout: bin/real-device-hub + share/real-device-hub/browser
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("../share/real-device-hub/browser").standardized.path
    ]

    static let root: URL? = {
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) {
                return url.standardizedFileURL
            }
        }
        return nil
    }()

    /// Read a file under the browser root. Rejects anything that escapes it.
    static func read(_ relative: String, under root: URL) -> Data? {
        let target = root.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return try? Data(contentsOf: target)
    }
}
