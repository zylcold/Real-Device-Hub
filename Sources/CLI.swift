import AppKit
import Foundation

/// Real Device Hub command line.
///
/// `serve` runs in the foreground and owns the process lifetime, so closing the
/// terminal stops the service. `start` detaches it and records where to find it
/// in `~/.real-device-hub.state`; `stop` shuts that one down.
enum CLI {

    static let defaultPort: UInt16 = 3738

    static var stateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".real-device-hub.state")
    }

    static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".real-device-hub.log")
    }

    static let usage = """
    Real Device Hub — a live view of every booted iOS Simulator in your browser.

    USAGE
      real-device-hub <command> [options]

    COMMANDS
      serve        Run in the foreground. Opens the dashboard on startup.
      start        Run in the background, then open the dashboard.
      stop         Stop a service started with `start`.
      status       Report whether the service is running, and its URL.
      list         List booted simulators.
      help         Show this text.

    OPTIONS
      -p, --port <n>   Port to listen on (default \(defaultPort), or $PORT).
          --no-open    Do not open the browser.
      -h, --help       Show this text.

    macOS needs Screen Recording permission for the app that launches the
    service; it prompts the first time.

    EXAMPLES
      real-device-hub                     # foreground, opens the browser
      real-device-hub start               # background, opens the browser
      real-device-hub serve --port 9000   # a different port
    """

    // MARK: - Dispatch

    static func run(_ arguments: [String]) -> Never {
        var options = Options()
        var command = "serve"

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-p", "--port":
                guard index + 1 < arguments.count, let value = UInt16(arguments[index + 1]) else {
                    fail("--port needs a number")
                }
                options.port = value
                index += 2
                continue
            case "--no-open":
                options.noOpen = true
            case "-h", "--help":
                options.help = true
            default:
                if !argument.hasPrefix("-") && command == "serve" && !options.sawCommand {
                    command = argument
                    options.sawCommand = true
                } else {
                    fail("Unknown argument: \(argument)")
                }
            }
            index += 1
        }

        if options.help { print(usage); exit(0) }

        switch command {
        case "serve": serve(options)
        case "start": start(options)
        case "stop": stop()
        case "status": status()
        case "list": list()
        case "help": print(usage); exit(0)
        case "version": print("Real Device Hub 1.0.0"); exit(0)
        default: fail("Unknown command: \(command)")
        }
    }

    // MARK: - Commands

    private static func serve(_ options: Options) -> Never {
        if let running = Running.instance,
           running.pid != ProcessInfo.processInfo.processIdentifier {
            fail("Already running (pid \(running.pid)) at \(running.url). "
                 + "Run `real-device-hub stop` first, or pass --port \(running.port + 1).")
        }
        guard !isPortBusy(options.port) else {
            let owners = DeviceEnumerator.shell("lsof", "-i", ":\(options.port)", "-P", "-n") ?? ""
            fail("Port \(options.port) is already in use.\n" + owners)
        }

        let app = StreamingApp(port: options.port)
        app.onReady = { [weak app] in
            let url = "http://localhost:\(options.port)"
            print("")
            print("  Dashboard: \(url)")
            if !options.noOpen { openInBrowser(URL(string: url)!) }
            print("  Ctrl-C stops the service.")
            print("")
            _ = app
        }

        // Record ourselves so `status` and `stop` can find us, and so a clean
        // shutdown removes the file.
        writeState(Running(pid: ProcessInfo.processInfo.processIdentifier, port: options.port))
        installShutdownHandlers()

        app.start()
        RunLoop.main.run()   // never returns
        exit(0)
    }

    private static func start(_ options: Options) -> Never {
        if let running = Running.instance {
            print("Already running (pid \(running.pid)) at \(running.url)")
            if !options.noOpen { openInBrowser(URL(string: running.url)!) }
            exit(0)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            self.executablePath, "serve", "--port", String(options.port)
        ] + (options.noOpen ? ["--no-open"] : [])
        process.standardOutput = logHandle()
        process.standardError = logHandle()

        do {
            try process.run()
        } catch {
            fail("Could not start the service: \(error)")
        }

        // The child writes the state file once it is serving; wait for it so
        // `start` prints a URL that actually works.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if Running.instance?.pid == process.processIdentifier {
                print("Started (pid \(process.processIdentifier)) at \(Running.instance!.url)")
                print("Log: \(logFile.path)")
                if !options.noOpen { openInBrowser(URL(string: Running.instance!.url)!) }
                exit(0)
            }
            usleep(100_000)
        }
        fail("Started, but it never reported ready. See \(logFile.path)")
    }

    private static func stop() -> Never {
        guard let running = Running.instance else {
            print("Not running.")
            exit(0)
        }
        guard kill(running.pid, SIGTERM) == 0 else {
            fail("Could not signal pid \(running.pid)")
        }
        // Give it a moment to unwind its captures, then insist.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, FileManager.default.fileExists(atPath: stateFile.path) {
            usleep(100_000)
        }
        if FileManager.default.fileExists(atPath: stateFile.path) {
            kill(running.pid, SIGKILL)
            try? FileManager.default.removeItem(at: stateFile)
        }
        print("Stopped (pid \(running.pid)).")
        exit(0)
    }

    private static func status() -> Never {
        guard let running = Running.instance else {
            print("Not running. Start it with `real-device-hub start`.")
            exit(1)
        }
        let devices = DeviceEnumerator.bootedDevices()
        print("Running (pid \(running.pid)) at \(running.url)")
        print("\(devices.count) booted simulator\(devices.count == 1 ? "" : "s")")
        for device in devices {
            let screens = device.displays.count > 1 ? "  [\(device.displays.count) screens]" : ""
            print("  \(device.name)  \(device.runtime ?? "-")  \(device.udid ?? "-")\(screens)")
        }
        exit(0)
    }

    private static func list() -> Never {
        let devices = DeviceEnumerator.bootedDevices()
        guard !devices.isEmpty else {
            print("No booted simulators.")
            exit(0)
        }
        for device in devices {
            let screens = device.displays.count
            let note = screens > 1 ? "  [\(screens) screens]" : ""
            print("\(device.name)\t\(device.runtime ?? "-")\t\(device.udid ?? "-")\(note)")
        }
        exit(0)
    }

    // MARK: - Helpers

    private static var executablePath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    private static func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// True when something else already holds the port. A `NWListener` cannot
    /// answer this — it binds asynchronously, so `try` never throws and the
    /// failure shows up in a state handler instead. A plain `bind()` can.
    private static func isPortBusy(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Any other failure (EACCES on a privileged port, for instance) is not
        // a conflict — let the real listener report it with its own message.
        return bound != 0 && errno == EADDRINUSE
    }

    private static func logHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logFile)
        handle?.seekToEndOfFile()
        return handle
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
        exit(64)
    }

    private static var shutdownSources: [DispatchSourceSignal] = []

    /// Ctrl-C, `stop`, or a closed terminal must all unwind the same way: drop
    /// the state file so `status` does not report a dead pid.
    private static func installShutdownHandlers() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                try? FileManager.default.removeItem(at: stateFile)
                print("\n[Hub] Stopped.")
                exit(0)
            }
            signal(number, SIG_IGN)
            source.resume()
            shutdownSources.append(source)   // keep alive for the process lifetime
        }
    }

    private static func writeState(_ running: Running) {
        let body = "pid=\(running.pid)\nport=\(running.port)\n"
        try? body.write(to: stateFile, atomically: true, encoding: .utf8)
    }
}

/// What `serve` recorded about the running process.
struct Running {
    let pid: Int32
    let port: UInt16

    var url: String { "http://localhost:\(port)" }

    /// The running service, if the state file is present and the pid is alive.
    static var instance: Running? {
        guard let text = try? String(contentsOf: CLI.stateFile, encoding: .utf8) else { return nil }
        var pid: Int32?
        var port: UInt16?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0] == "pid" { pid = Int32(parts[1]) }
            if parts[0] == "port" { port = UInt16(parts[1]) }
        }
        guard let pid, let port, kill(pid, 0) == 0 else { return nil }
        return Running(pid: pid, port: port)
    }
}

struct Options {
    var port: UInt16 = ProcessInfo.processInfo.environment["PORT"].flatMap { UInt16($0) } ?? CLI.defaultPort
    var noOpen = false
    var help = false
    /// `serve` is the default command, so a leading bare word is only read as
    /// a command once.
    var sawCommand = false
}
