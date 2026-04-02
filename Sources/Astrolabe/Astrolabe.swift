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
nonisolated(unsafe) private var _installDaemon: Bool = true

extension Astrolabe {
    /// How often the engine polls state providers for changes. Default: 5 seconds.
    /// Set this in `init()`.
    public static var pollInterval: Duration {
        get { _pollInterval }
        set { _pollInterval = newValue }
    }

    /// Whether to install a LaunchDaemon so the process auto-starts on boot. Default: true.
    /// Set this in `init()`.
    public static var installDaemon: Bool {
        get { _installDaemon }
        set { _installDaemon = newValue }
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
        if Self.installDaemon {
            installLaunchDaemon()
        }

        let engine = LifecycleEngine(
            configuration: Self(),
            providers: [EnrollmentProvider()],
            pollInterval: Self.pollInterval
        )
        try await engine.run()
    }

    private static func installLaunchDaemon() {
        let label = "codes.photon.astrolabe"
        let plistPath = "/Library/LaunchDaemons/\(label).plist"

        guard !FileManager.default.fileExists(atPath: plistPath) else { return }

        guard let executablePath = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "KeepAlive": true,
            "RunAtLoad": true,
        ]

        let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        FileManager.default.createFile(atPath: plistPath, contents: data)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "system", plistPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        print("[Astrolabe] LaunchDaemon installed at \(plistPath).")
    }
}

public enum AstrolabeError: Error, Sendable {
    case notRunningAsRoot
}
