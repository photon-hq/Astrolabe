import ArgumentParser
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
///
///     // Optional: custom CLI subcommands.
///     static var commands: [any AsyncParsableCommand.Type] { [Status.self] }
/// }
/// ```
public protocol Astrolabe: Setup {
    init()

    /// Called after persistence loads, before the first tick. Use for async setup.
    func onStart() async throws

    /// Called when the process is terminating (SIGTERM/SIGINT). Keep it fast.
    func onExit()

    /// Custom CLI subcommands. Default: none.
    ///
    /// When a user invokes one of these by name (`sudo mysetup <command>`), Astrolabe
    /// dispatches directly into the command's `run()` — it does not construct `Self`,
    /// start the engine, or touch the daemon.
    static var commands: [any AsyncParsableCommand.Type] { get }
}

/// Global configuration. Set in `init()`, read by the engine.
/// Safe because init() runs before any concurrent access.
nonisolated(unsafe) private var _pollInterval: Duration = .seconds(5)
nonisolated(unsafe) private var _daemonMode: Bool = true

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

    public static var commands: [any AsyncParsableCommand.Type] { [] }

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

        var args = Array(CommandLine.arguments.dropFirst())

        // Backwards-compat: rewrite legacy `--force-install-daemon` top-level flag.
        if let idx = args.firstIndex(of: "--force-install-daemon") {
            FileHandle.standardError.write(Data(
                "[Astrolabe] --force-install-daemon is deprecated; use `install-daemon --force`.\n".utf8
            ))
            args.remove(at: idx)
            args.insert(contentsOf: ["install-daemon", "--force"], at: 0)
        }

        await AstrolabeRoot<Self>.main(args)
    }
}

public enum AstrolabeError: Error, Sendable {
    case notRunningAsRoot
    case daemonInstallFailed(String)
}
