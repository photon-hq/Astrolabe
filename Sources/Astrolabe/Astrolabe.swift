import Darwin
import Foundation

/// A declarative macOS configuration.
///
/// The entry point protocol. Like SwiftUI's `App`. Conform and annotate with `@main`:
///
/// ```swift
/// @main
/// struct MySetup: Astrolabe {
///     init() {
///         Self.pollInterval = .seconds(10)
///     }
///
///     func onStart() async throws {
///         // Async setup: fetch config, authenticate, etc.
///     }
///
///     var body: some Setup {
///         Pkg(.catalog(.homebrew))
///         Brew("wget")
///     }
/// }
/// ```
public protocol Astrolabe: Setup {
    init()

    /// Called after persistence loads, before the first tick. Use for async setup.
    func onStart() async throws

    /// Called when the process is terminating (SIGTERM/SIGINT). Keep it fast.
    func onExit()
}

/// Global configuration. Set in `init()`, read by the engine.
/// Safe because init() runs before any concurrent access.
nonisolated(unsafe) private var _pollInterval: Duration = .seconds(5)
nonisolated(unsafe) private var _daemonMode: Bool = true

private let daemonLabel = "codes.photon.astrolabe"
private let daemonPlistPath = "/Library/LaunchDaemons/codes.photon.astrolabe.plist"

extension Astrolabe {
    /// How often the engine polls state providers for changes. Default: 5 seconds.
    /// Set this in `init()`.
    public static var pollInterval: Duration {
        get { _pollInterval }
        set { _pollInterval = newValue }
    }

    /// Whether to run as a persistent LaunchDaemon managed by launchd. Default: true.
    ///
    /// When `true`, the first `sudo` invocation installs the daemon and exits.
    /// launchd manages the process from then on (auto-start on boot, restart on crash).
    ///
    /// When `false`, the engine runs inline in the current process. Any previously
    /// installed daemon is removed.
    ///
    /// Set this in `init()`.
    public static var daemonMode: Bool {
        get { _daemonMode }
        set { _daemonMode = newValue }
    }

    /// Resets the specified persistent stores. Call from `onStart()` or `init()`.
    ///
    /// ```swift
    /// Self.reset(.payloads, .identities)
    /// Self.reset(.all)
    /// ```
    public static func reset(_ stores: Persistence.Store...) {
        let combined = stores.reduce(into: Persistence.Store()) { $0.formUnion($1) }
        Persistence.reset(combined)
    }

    public func onStart() async throws {}
    public func onExit() {}

    /// Entry point called by the Swift runtime when this type is marked `@main`.
    public static func main() async throws {
        guard getuid() == 0 else {
            throw AstrolabeError.notRunningAsRoot
        }

        // Construct first so init() can set daemonMode, pollInterval, etc.
        let configuration = Self()

        if Self.daemonMode {
            if isLaunchdChild {
                print("[Astrolabe] Running as daemon.")
            } else {
                try await installOrUpdateDaemon()
                return
            }
        } else {
            await removeDaemon()
        }

        let engine = LifecycleEngine(
            configuration: configuration,
            providers: [EnrollmentProvider()],
            pollInterval: Self.pollInterval
        )
        try await engine.run()
    }

    // MARK: - Daemon Lifecycle

    /// True when the process was started by launchd (parent PID is 1).
    private static var isLaunchdChild: Bool { getppid() == 1 }

    /// Installs or updates the LaunchDaemon plist and bootstraps it via launchd.
    /// The calling process should exit after this returns — launchd manages the daemon.
    private static func installOrUpdateDaemon() async throws {
        guard let executablePath = Bundle.main.executablePath else {
            throw AstrolabeError.daemonInstallFailed("Could not resolve executable path.")
        }

        // Check if already installed with the correct binary path.
        if let existingPath = daemonBinaryPath() {
            if existingPath == executablePath {
                if LaunchctlHelper.isDaemonLoaded(label: daemonLabel) {
                    print("[Astrolabe] Daemon already running.")
                    return
                }
                // Plist exists, path matches, but not loaded — re-bootstrap.
            } else {
                print("[Astrolabe] Binary path changed (\(existingPath) → \(executablePath)), updating daemon...")
            }
        } else {
            print("[Astrolabe] Installing LaunchDaemon...")
        }

        // Write (or overwrite) the plist.
        let plist: [String: Any] = [
            "Label": daemonLabel,
            "ProgramArguments": [executablePath],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": "/var/log/\(daemonLabel).log",
            "StandardErrorPath": "/var/log/\(daemonLabel).log",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        FileManager.default.createFile(atPath: daemonPlistPath, contents: data)

        // bootout (ignore errors) → enable → bootstrap
        try await LaunchctlHelper.activateDaemon(label: daemonLabel, plistPath: daemonPlistPath)

        print("[Astrolabe] Daemon started. Exiting — launchd will manage the process.")
    }

    /// Removes the LaunchDaemon if one is installed. No-op otherwise.
    private static func removeDaemon() async {
        guard FileManager.default.fileExists(atPath: daemonPlistPath) else { return }
        await LaunchctlHelper.deactivateDaemon(label: daemonLabel)
        try? FileManager.default.removeItem(atPath: daemonPlistPath)
        print("[Astrolabe] LaunchDaemon removed.")
    }

    /// Reads the existing plist and returns the binary path from ProgramArguments[0].
    private static func daemonBinaryPath() -> String? {
        guard let data = FileManager.default.contents(atPath: daemonPlistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let path = args.first
        else { return nil }
        return path
    }
}

public enum AstrolabeError: Error, Sendable {
    case notRunningAsRoot
    case daemonInstallFailed(String)
}
