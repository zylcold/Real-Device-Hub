import Foundation
import ScreenCaptureKit

/// Identifies one capture: a device, and which of its screens.
struct CaptureKey: Hashable {
    let device: String
    let screen: Int

    var id: String { "\(device)#\(screen)" }
}

/// Owns the captures and keeps them in sync with what is on screen. Captures are
/// created lazily — only the screens someone is actually watching get an
/// `SCStream` and an encoder.
actor Fleet {
    private var captures: [CaptureKey: DeviceCapture] = [:]
    /// Window signature per device, so a window that is recreated (moved,
    /// reopened, or the set of screens changed) drops its captures.
    private var signatures: [String: String] = [:]
    /// Devices already reported as having no window, so the poll stays quiet.
    private var reportedUnbound: Set<String> = []

    /// Devices as of the last poll, in display order.
    private(set) var devices: [SimDevice] = []

    /// simctl + shareable content are a subprocess and a framework call; two
    /// seconds is fast enough to feel live and cheap enough to leave running.
    private static let pollInterval: UInt64 = 2_000_000_000

    nonisolated func start() {
        Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: Fleet.pollInterval)
            }
        }
    }

    private func poll() async {
        let found = await DeviceEnumerator.discover()
        devices = found

        let liveKeys = Set(found.map(\.key))
        let newSignatures = Dictionary(
            found.compactMap { d in d.windowSignature.map { (d.key, $0) } },
            uniquingKeysWith: { a, _ in a }
        )

        for (key, capture) in captures
        where !liveKeys.contains(key.device)
            || newSignatures[key.device].map({ $0 != signatures[key.device] }) == true {
            print("[Fleet] stopping \(capture.label) [\(key.id)]")
            captures.removeValue(forKey: key)
            Task { await capture.stop() }
        }
        for key in signatures.keys where !liveKeys.contains(key) {
            signatures.removeValue(forKey: key)
            reportedUnbound.remove(key)
        }

        for device in found where !device.isBound {
            // Log once, not on every poll.
            if reportedUnbound.insert(device.key).inserted {
                print("[Devices] \(device.name) is booted but has no Simulator window open")
            }
        }
        reportedUnbound = reportedUnbound.filter { liveKeys.contains($0) }

        signatures = newSignatures
    }

    /// Payload for `GET /api/devices`. Carries every screen's encoded size so the
    /// page can give the tile the real aspect ratio before any video arrives.
    func devicesJSON() -> [[String: Any]] {
        devices.map { d in
            var sizes: [[String: Any]] = []
            for screen in 0..<d.windowCount where captures[CaptureKey(device: d.key, screen: screen)] != nil {
                let size = captures[CaptureKey(device: d.key, screen: screen)]!.outputSize
                if size.height > 0 {
                    sizes.append(["width": Int(size.width), "height": Int(size.height)])
                }
            }
            return [
                "key": d.key,
                "udid": d.udid as Any,
                "name": d.name,
                "runtime": d.runtime as Any,
                "streaming": d.isBound,
                "screens": d.windowCount,
                // `sizes[0]` is the tile's aspect. Only filled in for screens
                // already being captured, so the page falls back to 9:19.5.
                "sizes": sizes
            ]
        }
    }

    /// The capture for a device screen, starting it on first use.
    func capture(device key: String, screen: Int) async -> DeviceCapture? {
        let captureKey = CaptureKey(device: key, screen: screen)
        if let existing = captures[captureKey] { return existing }
        guard let device = devices.first(where: { $0.key == key }),
              device.isBound, screen < device.windowCount else { return nil }

        let capture = DeviceCapture(device: device, screen: screen)
        captures[captureKey] = capture
        do {
            try await capture.start()
        } catch {
            print("[Fleet] \(capture.label) failed to start: \(error)")
            captures.removeValue(forKey: captureKey)
            return nil
        }
        return capture
    }

    func cachedCapture(device key: String, screen: Int) -> DeviceCapture? {
        captures[CaptureKey(device: key, screen: screen)]
    }
}
