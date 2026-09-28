import Foundation

/// Wires the fleet to the socket. One viewer per device, keyed by device key.
final class StreamingApp {
    private let fleet = Fleet()
    private let httpServer: HTTPServer
    /// Every browser looking at a device. Frames are broadcast, so a second tab
    /// — or someone else's browser — never kicks the first one off. Last-one-
    /// wins made two viewers fight in a reconnect loop.
    private var viewers: [String: [WebSocketConnection]] = [:]
    private let viewersLock = NSLock()

    init(port: UInt16) {
        httpServer = HTTPServer(port: port)
        print("[App] Port: \(port) (override with --port or PORT env var)")
    }

    /// Forwarded from the HTTP listener becoming ready.
    var onReady: (() -> Void)? {
        get { httpServer.onReady }
        set { httpServer.onReady = newValue }
    }

    func start() {
        httpServer.onViewerConnected = { [weak self] ws, key, screen in
            self?.viewerJoined(ws, key: key, screen: screen)
        }
        httpServer.onViewerDisconnected = { [weak self] ws, key, _ in
            self?.viewerLeft(ws, key: key)
        }
        httpServer.devicesJSON = { [weak self] in
            guard let self,
                  let data = try? JSONSerialization.data(
                    withJSONObject: await self.fleet.devicesJSON(), options: []
                  ) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        do {
            try httpServer.start()
        } catch {
            print("")
            print("[FATAL] HTTP server failed to start: \(error)")
            print("[FATAL] Most likely: port already bound. Check with:")
            print("[FATAL]   lsof -i :\(ProcessInfo.processInfo.environment["PORT"] ?? "3738") -P -n")
            print("[FATAL] Or set PORT=<other> when launching.")
            exit(3)
        }

        fleet.start()
    }

    // MARK: - Viewers

    private func viewerJoined(_ ws: WebSocketConnection, key: String, screen: Int) {
        viewersLock.lock()
        let isFirstViewer = viewers[key]?.isEmpty ?? true
        viewers[key, default: []].append(ws)
        viewersLock.unlock()

        Task { [weak self] in
            guard let self,
                  let capture = await self.fleet.capture(device: key, screen: screen) else {
                // Device is known to the dashboard but not capturable yet — the
                // fleet wires it up within a poll and the client reconnects.
                print("[App] no capture for \(key) screen \(screen); viewer will reconnect")
                ws.close()
                return
            }
            ws.onText = { [weak capture] text in
                // The only control message a view-only stream needs.
                if text.contains("request-keyframe") { capture?.requestKeyframe() }
            }
            if isFirstViewer {
                capture.onSendJSON = { [weak self] json in self?.sendJSON(json, to: key) }
                capture.onSendBinaryFrame = { [weak self] isKey, pts, annexB in
                    self?.sendFrame(isKey: isKey, pts: pts, annexB: annexB, to: key)
                }
            }
            capture.viewerJoined()
            print("[App] viewer → \(capture.label) [\(key)]")
        }
    }

    private func viewerLeft(_ ws: WebSocketConnection, key: String) {
        viewersLock.lock()
        viewers[key]?.removeAll { $0 === ws }
        let empty = viewers[key]?.isEmpty ?? true
        if empty { viewers.removeValue(forKey: key) }
        viewersLock.unlock()
        guard empty else { return }

        print("[App] last viewer left \(key)")
        Task { [weak self] in
            guard let self, let capture = await self.fleet.cachedCapture(device: key, screen: 0) else { return }
            capture.onSendJSON = nil
            capture.onSendBinaryFrame = nil
            capture.viewerLeft()
        }
    }

    // MARK: - Socket writes

    private func sendJSON(_ json: [String: Any], to key: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        for viewer in viewersFor(key) { viewer.sendText(text) }
    }

    private func sendFrame(isKey: Bool, pts: Int64, annexB: Data, to key: String) {
        // [1 byte key flag][8 bytes pts µs BE][Annex-B]
        var payload = Data(count: 9)
        payload[0] = isKey ? 0x01 : 0x00
        let pts = UInt64(bitPattern: pts).bigEndian
        withUnsafeBytes(of: pts) { raw in
            for i in 0..<8 { payload[1 + i] = raw[i] }
        }
        payload.append(annexB)
        for viewer in viewersFor(key) { viewer.sendBinary(payload) }
    }

    private func viewersFor(_ key: String) -> [WebSocketConnection] {
        viewersLock.lock()
        defer { viewersLock.unlock() }
        return viewers[key] ?? []
    }
}
