import AppKit
import CoreGraphics

// print() must land immediately — this often runs detached from a terminal.
setbuf(stdout, nil)

// A dead pipe (e.g. a torn-down Simulator) would otherwise kill us with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

// Bezels off → the captured window is just the device screen, nothing to crop.
if run("/usr/bin/defaults", ["write", "com.apple.iphonesimulator",
                             "ShowDeviceBezels", "-bool", "false"]) == nil {
    print("[App] Warning: could not disable simulator bezels")
}

if CommandLine.arguments.contains("--selftest") {
    SelfCheck.run()
}

// ScreenCaptureKit needs the AppKit subsystem alive.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--selftest") == false {
    requireScreenRecording()
    CLI.run(Array(CommandLine.arguments.dropFirst()))
}

// MARK: - Support

@discardableResult
private func run(_ executable: String, _ args: [String]) -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return nil
    }
}

/// Screen Recording is the one permission we cannot work around: without it
/// ScreenCaptureKit cannot see Simulator windows at all.
private func requireScreenRecording() {
    guard !CGRequestScreenCaptureAccess() else { return }
    let bar = String(repeating: "═", count: 72)
    print("")
    print(bar)
    print("[FATAL] Screen Recording permission MISSING (required)")
    print(bar)
    print("ScreenCaptureKit cannot see Simulator windows without it.")
    print("")
    print("Fix:")
    print("  1. System Settings → Privacy & Security → Screen Recording")
    print("  2. Enable the toggle for the app that launched this (Terminal, iTerm, …)")
    print("  3. Quit that app completely (⌘Q) and reopen it")
    print("  4. Run the command again")
    print(bar)
    print("")
    exit(2)
}

/// Checks the rules that can break silently, without needing a live window
/// server or a running server. `./real-device-hub selftest`
private enum SelfCheck {
    static func run() -> Never {
        var failures = 0
        func check(_ label: String, _ got: String, _ want: String) {
            if got == want { print("ok   \(label)") }
            else { print("FAIL \(label): got \(got), want \(want)"); failures += 1 }
        }

        func window(_ id: UInt32, _ title: String?, _ w: CGFloat = 402, _ h: CGFloat = 926) -> SimWindow {
            SimWindow(id: id, title: title, size: CGSize(width: w, height: h), object: nil)
        }
        func device(_ name: String, _ udid: String, _ runtime: String? = "iOS 27.0",
                    _ displays: [CGSize] = []) -> SimDevice {
            SimDevice(key: udid, udid: udid, name: name, runtime: runtime, displays: displays)
        }
        // iPhone Duo as seen on this machine: two Display class 0 framebuffers.
        let duo = device("iPhone Duo", "D", "iOS 27.1",
                         [CGSize(width: 1398, height: 2034), CGSize(width: 2007, height: 2853)])
        func rect(_ device: SimDevice, _ w: SimWindow) -> String {
            guard let r = device.contentRect(forWindow: w) else { return "nil" }
            return "\(Int(r.width))x\(Int(r.height))@\(Int(r.minY))"
        }

        print("── runtime labels")
        check("iOS-26-4", DeviceEnumerator.prettyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-26-4"), "iOS 26.4")
        check("xrOS-2-0", DeviceEnumerator.prettyRuntime("com.apple.CoreSimulator.SimRuntime.xrOS-2-0"), "xrOS 2.0")
        check("already bare", DeviceEnumerator.prettyRuntime("iOS-27-0"), "iOS 27.0")

        print("── window to device pairing")
        let distinct = DeviceEnumerator.pair(
            devices: [device("iPhone 17", "A"), device("iPhone Duo", "B")],
            windows: [window(7, "iPhone Duo"), window(3, "iPhone 17")])
        check("paired by title, not by order",
              distinct.map(\.key).joined(separator: ","), "A,B")
        check("window ids land on the right device",
              distinct.map { $0.windows.first.map { String($0.id) } ?? "nil" }.joined(separator: ","),
              "3,7")

        let duplicate = DeviceEnumerator.pair(
            devices: [device("iPhone 17", "A", "iOS 26.4"), device("iPhone 17", "B", "iOS 27.0")],
            windows: [window(1, "iPhone 17"), window(2, "iPhone 17")])
        check("two booted devices sharing a name both survive", "\(duplicate.count)", "2")
        check("both windows get claimed",
              duplicate.map { $0.windows.first.map { String($0.id) } ?? "nil" }.joined(separator: ","),
              "1,2")

        let chrome = DeviceEnumerator.pair(
            devices: [device("iPhone 17", "A")],
            windows: [window(1, "iPhone 17"), window(2, "Window", 66, 20), window(3, "Window", 66, 20)])
        check("Simulator's tiny helper windows are dropped",
              chrome.map(\.key).joined(separator: ","), "A")

        let orphan = DeviceEnumerator.pair(
            devices: [device("iPhone 17", "A")],
            windows: [window(1, "iPhone 17"), window(9, "iPhone 15")])
        check("a window with no booted device is still shown",
              orphan.map(\.key).joined(separator: ","), "A,win:9")

        let untitled = DeviceEnumerator.pair(
            devices: [], windows: [window(4, "iPad Pro"), window(5, nil)])
        check("windows with no devices at all",
              untitled.map(\.key).joined(separator: ","), "win:4,win:5")
        check("untitled window gets a placeholder name", untitled[1].name, "Simulator window")

        let nowindow = DeviceEnumerator.pair(devices: [device("iPhone 17", "A")], windows: [])
        check("booted device with no window is still listed",
              nowindow.first.map { String($0.isBound) } ?? "missing", "false")

        print("── one tile per device, multiple screens")
        // The three booted devices as they look on this machine. iPhone Duo
        // reports two Display class 0 framebuffers and Simulator opens a window
        // per screen, so it is the only multi-screen device.
        let real = DeviceEnumerator.pair(
            devices: [
                device("iPhone 17 Pro Max", "P", "iOS 26.4", [CGSize(width: 1320, height: 2868)]),
                device("iPhone 17", "A", "iOS 27.0", [CGSize(width: 1206, height: 2622)]),
                duo,
            ],
            windows: [
                window(24, "iPhone 17 Pro Max", 440, 1008),
                window(25, "iPhone 17", 402, 926),
                window(20, "iPhone Duo", 466, 730),
                window(10, "iPhone Duo", 669, 1003),
            ])
        check("four windows, three tiles", "\(real.count)", "3")
        check("the Duo is one tile with two screens",
              real.map { "\($0.key):\($0.windowCount)" }.joined(separator: " "), "P:1 A:1 D:2")
        check("screen 0 is the first framebuffer, not the first window",
              real[2].windows.map { String($0.id) }.joined(separator: ","), "20,10")
        check("its window signature covers both screens",
              real[2].windowSignature ?? "nil", "20,10")
        check("chrome is calibrated from the single-screen devices",
              String(format: "%.0f", real[0].windowChrome ?? -1), "52")

        print("── cropping the window chrome")
        check("iPhone 17: 402x926 window, 1206x2622 screen",
              rect(real[1], real[1].windows[0]), "402x874@52")
        check("Duo screen 0: 466x730 window, 1398x2034 screen",
              rect(real[2], real[2].windows[0]), "466x678@52")
        check("Duo screen 1: 669x1003 window, 2007x2853 screen",
              rect(real[2], real[2].windows[1]), "669x951@52")
        check("no display geometry means capture the whole window",
              rect(device("iPhone 17", "A", nil, []), window(1, "iPhone 17", 402, 926)), "nil")
        check("a window too small for its screen is not cropped",
              rect(real[2], window(1, "iPhone Duo", 466, 400)), "nil")

        print("── screen matching")
        check("466x730 window is framebuffer 0", String(real[2].displayIndex(of: real[2].windows[0]) ?? -1), "0")
        check("669x1003 window is framebuffer 1", String(real[2].displayIndex(of: real[2].windows[1]) ?? -1), "1")
        check("a window matching nothing has no index",
              String(real[2].displayIndex(of: window(1, "iPhone Duo", 500, 500)) ?? -1), "-1")

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
