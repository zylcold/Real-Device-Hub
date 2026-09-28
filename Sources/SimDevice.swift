import Foundation
import ScreenCaptureKit

/// One device on the dashboard.
///
/// A device maps to *one* tile no matter how many screens it has. iPhone Duo
/// reports two `Display class: 0` framebuffers and Simulator opens a window per
/// screen; the tile shows one of them at a time and the viewer flips between
/// them.
struct SimDevice {
    /// Stable identity for the wire protocol: the udid, or `win:<windowID>` for
    /// a Simulator window with no booted device behind it.
    let key: String
    let udid: String?
    let name: String
    /// "iOS 27.0", or nil when we only have a window.
    let runtime: String?
    /// One entry per screen, ordered the way `simctl io enumerate` lists the
    /// device's framebuffers — so index 0 is the device's primary screen, not
    /// whichever window happened to be created first.
    var windows: [SimWindow] = []
    /// Every built-in screen, in `Display class: 0`, from `simctl io enumerate`.
    /// A single-screen device has one; iPhone Duo has two.
    var displays: [CGSize] = []
    /// Height of the chrome band Simulator adds to the top of a device window.
    /// Calibrated per poll from devices that have exactly one screen, then used
    /// to tell a multi-screen device's screens apart — see `calibrateChrome`.
    var windowChrome: CGFloat?

    var isBound: Bool { !windows.isEmpty }
    var windowCount: Int { windows.count }

    /// Changes when any of the device's windows is recreated (moved, reopened,
    /// or the set of screens changed) — the signal to drop and rebuild captures.
    var windowSignature: String? {
        windows.isEmpty ? nil : windows.map { String($0.id) }.joined(separator: ",")
    }

    /// Simulator's own chrome — the tiny helper window it opens per device
    /// (66x20pt, titled just "Window"). Encoding those is pure waste and they
    /// crowd the grid.
    static let minimumWindowEdge: CGFloat = 200

    /// The device screen's rect inside its Simulator window, in window-local
    /// points, ready for `SCStreamConfiguration.sourceRect`.
    ///
    /// Simulator sizes a device window to exactly `display.width * scale` wide
    /// and adds a fixed chrome band on top and bottom — no left or right chrome.
    /// So the content height follows from the display's own aspect ratio and we
    /// do not need Accessibility to find it:
    ///
    ///     scale        = window.width / display.width
    ///     contentHigh  = display.height * scale
    ///
    /// One display gives an unambiguous answer. Several do not — every one of a
    /// multi-screen device's displays yields a plausible content height — so we
    /// pick the one whose leftover chrome matches the calibrated band. Returns
    /// nil when nothing fits, which means "capture the whole window".
    func contentRect(forWindow window: SimWindow) -> CGRect? {
        let windowSize = window.size
        guard windowSize.width > 0, windowSize.height > 0 else { return nil }

        func contentHeight(for display: CGSize) -> CGFloat {
            windowSize.width * display.height / display.width
        }
        func fits(_ display: CGSize) -> Bool {
            let height = contentHeight(for: display)
            return height > 0 && height <= windowSize.height
        }

        if displays.count > 1, let chrome = windowChrome {
            // The right screen leaves exactly the calibrated band. Anything more
            // than a few points off is a different window, not a rounding error.
            let match = displays
                .filter(fits)
                .min { abs(windowSize.height - contentHeight(for: $0) - chrome)
                     < abs(windowSize.height - contentHeight(for: $1) - chrome) }
            guard let match, abs(windowSize.height - contentHeight(for: match) - chrome) < 8 else {
                return nil
            }
            let height = contentHeight(for: match)
            return CGRect(x: 0, y: windowSize.height - height, width: windowSize.width, height: height)
        }

        guard let best = displays.filter(fits).map(contentHeight).max() else { return nil }
        return CGRect(x: 0, y: windowSize.height - best, width: windowSize.width, height: best)
    }

    /// Index into `displays` that `window` is showing, if we can tell.
    func displayIndex(of window: SimWindow) -> Int? {
        let rect = contentRect(forWindow: window)
        guard let rect, rect.height > 0 else { return nil }
        let shown = rect.width / rect.height
        var best: (index: Int, delta: CGFloat)?
        for (i, display) in displays.enumerated() where display.height > 0 {
            let delta = abs(display.width / display.height - shown)
            if best == nil || delta < best!.delta { best = (i, delta) }
        }
        // 1% is a hair off; beyond that we are guessing.
        guard let best, best.delta < 0.01 else { return nil }
        return best.index
    }
}

/// A Simulator window as far as pairing is concerned. `object` is nil in tests,
/// which is why id and size are separate fields.
struct SimWindow {
    let id: UInt32
    let title: String?
    let size: CGSize
    let object: SCWindow?
}

enum DeviceEnumerator {

    /// Booted simulators from `simctl`, in runtime-then-name order — the
    /// tie-break order for same-name devices.
    static func bootedDevices() -> [SimDevice] {
        guard let out = shell("xcrun", "simctl", "list", "devices", "booted", "-j") else { return [] }
        guard let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }

        var devices: [SimDevice] = []
        // JSONSerialization hands back an unordered dictionary, so sort by
        // runtime or tiles jump around the grid between polls.
        for runtimeID in byRuntime.keys.sorted() {
            let runtime = prettyRuntime(runtimeID)
            let list = (byRuntime[runtimeID] ?? []).sorted {
                ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
            }
            for d in list {
                guard d["state"] as? String == "Booted",
                      let udid = d["udid"] as? String,
                      let name = d["name"] as? String else { continue }
                devices.append(SimDevice(key: udid, udid: udid, name: name, runtime: runtime))
            }
        }
        for i in devices.indices {
            devices[i].displays = displays(of: devices[i].udid)
        }
        return devices
    }

    /// Built-in screens for a device. Cached per udid — a device's framebuffer
    /// geometry does not change, and this would otherwise be a `simctl`
    /// subprocess per device per poll.
    private static var displayCache: [String: [CGSize]] = [:]
    private static let displayCacheLock = NSLock()

    static func displays(of udid: String?) -> [CGSize] {
        guard let udid else { return [] }
        displayCacheLock.lock()
        if let cached = displayCache[udid] {
            displayCacheLock.unlock()
            return cached
        }
        displayCacheLock.unlock()

        let found = enumerateDisplays(udid: udid)
        displayCacheLock.lock()
        displayCache[udid] = found
        displayCacheLock.unlock()
        return found
    }

    private static func enumerateDisplays(udid: String) -> [CGSize] {
        guard let out = shell("xcrun", "simctl", "io", udid, "enumerate") else { return [] }
        var displays: [CGSize] = []
        for block in out.components(separatedBy: "Port:") {
            // Class 1 ports are the 720x480 / 7680x4320 aux framebuffers, not
            // the device's own screen.
            guard block.contains("com.apple.framebuffer.display"),
                  block.contains("Display class: 0"),
                  let width = integer("Default width", in: block),
                  let height = integer("Default height", in: block),
                  width > 0, height > 0 else { continue }
            displays.append(CGSize(width: width, height: height))
        }
        return displays
    }

    private static func integer(_ label: String, in block: String) -> Int? {
        for line in block.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == label { return Int(parts[1]) }
        }
        return nil
    }

    /// Simulator windows, sorted by windowID so the pairing is deterministic
    /// across polls.
    static func simulatorWindows() async -> [SimWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return [] }
        return content.windows
            .filter { $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator" }
            .sorted { $0.windowID < $1.windowID }
            .map { SimWindow(id: $0.windowID, title: $0.title,
                             size: CGSize(width: $0.frame.width, height: $0.frame.height),
                             object: $0) }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-4" -> "iOS 26.4"
    static func prettyRuntime(_ runtimeID: String) -> String {
        let bare = runtimeID.replacingOccurrences(
            of: "com.apple.CoreSimulator.SimRuntime.", with: ""
        )
        let parts = bare.split(separator: "-")
        guard parts.count > 1 else { return bare }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }

    /// Pair booted simulators with the windows that display them.
    static func discover() async -> [SimDevice] {
        pair(devices: bootedDevices(), windows: await simulatorWindows())
    }

    /// ScreenCaptureKit exposes no udid, only the window title, which is the
    /// device name. Two booted devices sharing a name across runtimes are
    /// therefore ambiguous; they get paired in simctl order and we log it.
    ///
    /// Every window matching a device becomes one of that device's screens,
    /// ordered by the framebuffer the window is showing — `displays[0]` first.
    ///
    /// Split out from `discover` so the rules are testable without a live
    /// window server — see `--selftest`.
    static func pair(devices: [SimDevice], windows: [SimWindow]) -> [SimDevice] {
        var devices = devices

        // name -> indices of unpaired devices sharing that name, in simctl order
        var pool: [String: [Int]] = [:]
        for (i, d) in devices.enumerated() {
            pool[d.name, default: []].append(i)
        }

        var ambiguous = 0
        // Every window we can account for, by device index or as an orphan.
        var placed: Set<UInt32> = []
        // Device indices that already own a window, by device name. A second
        // window with the same name is another screen of the same device —
        // unless there is still an unpaired device of that name waiting.
        var owning: [String: [Int]] = [:]

        for window in windows {
            guard window.size.width >= SimDevice.minimumWindowEdge,
                  window.size.height >= SimDevice.minimumWindowEdge else { continue }
            placed.insert(window.id)

            if var candidates = pool[window.title ?? ""], !candidates.isEmpty {
                if candidates.count > 1 { ambiguous += 1 }
                let index = candidates.removeFirst()
                pool[window.title ?? ""] = candidates
                devices[index].windows.append(window)
                owning[window.title ?? "", default: []].append(index)
            } else if let owner = owning[window.title ?? ""]?.first {
                devices[owner].windows.append(window)
            } else {
                // A window whose device is shut down — show it anyway, it is
                // still on screen and still capturable.
                let sibling = devices.first { $0.name == window.title }
                devices.append(SimDevice(
                    key: "win:\(window.id)",
                    udid: nil,
                    name: (window.title?.isEmpty ?? true) ? "Simulator window" : window.title!,
                    runtime: sibling?.runtime,
                    windows: [window],
                    displays: sibling?.displays ?? []
                ))
            }
        }

        let chrome = calibrateChrome(devices: devices)
        for i in devices.indices {
            devices[i].windowChrome = chrome
            devices[i].windows = orderScreens(devices[i].windows, of: devices[i])
            if devices[i].windows.count > 1 {
                print("[Devices] \(devices[i].name): \(devices[i].windows.count) screens, " +
                      "showing screen 0 by default")
            }
        }

        if ambiguous > 0 {
            print("[Devices] WARNING: \(ambiguous) window(s) matched a name shared by several " +
                  "booted simulators. Paired in simctl order — labels may be swapped.")
        }

        return devices
    }

    /// Simulator adds the same chrome band to every device window, so we can
    /// measure it on any device that has exactly one screen and reuse it to
    /// tell the screens of a multi-screen device apart. The mode, not the mean:
    /// the true value repeats, anything else is a mis-paired window.
    static func calibrateChrome(devices: [SimDevice]) -> CGFloat? {
        var samples: [Int: [CGFloat]] = [:]
        for device in devices where device.displays.count == 1 && !device.windows.isEmpty {
            guard let rect = device.contentRect(forWindow: device.windows[0]) else { continue }
            let chrome = device.windows[0].size.height - rect.height
            guard chrome > 0, chrome < 200 else { continue }
            samples[Int(chrome.rounded()), default: []].append(chrome)
        }
        // The true chrome repeats across every single-screen device; anything
        // else is a window that got mis-paired.
        guard let best = samples.values.max(by: { $0.count < $1.count }), best.count > 0 else {
            return nil
        }
        return best.reduce(0, +) / CGFloat(best.count)
    }

    /// Sort a device's windows into framebuffer order. A window we cannot
    /// match to a display goes last; ties keep windowID order, which is stable
    /// across polls.
    private static func orderScreens(_ windows: [SimWindow], of device: SimDevice) -> [SimWindow] {
        guard windows.count > 1 else { return windows }
        return windows.sorted { a, b in
            switch (device.displayIndex(of: a), device.displayIndex(of: b)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
    }

    @discardableResult
    static func shell(_ command: String, _ args: String...) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [command] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            print("[Devices] shell \(command) failed: \(error)")
            return nil
        }
    }
}
