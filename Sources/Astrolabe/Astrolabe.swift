import ArgumentParser
import Darwin
import Foundation

/// A declarative macOS configuration. The root component; like SwiftUI's `App`.
///
/// State objects are `@Observable @MainActor` classes the app defines and stores as properties.
/// The engine holds this app value for its whole run, so they are created once. Whoever owns a
/// state object writes it; the engine only reacts.
///
/// ```swift
/// @main
/// struct StagingApp: Astrolabe {
///     let fixture = Fixture()
///
///     var body: some Component {
///         for (name, contents) in fixture.files.sorted(by: { $0.key < $1.key }) {
///             StagingFile(path: "/tmp/astrolabe-staging/\(name)", contents: contents)
///         }
///     }
///
///     static var resourceTypes: [any Resource.Type] { [StagingFile.self] }
/// }
/// ```
@MainActor
public protocol Astrolabe: Component, SendableMetatype {
    init()

    /// Every resource type the app can declare, so records written by an earlier run can be
    /// decoded after a restart even if `body` doesn't declare that type yet. Types seen in a
    /// declaration are registered too. Default: none.
    static var resourceTypes: [any Resource.Type] { get }

    /// How long after launch a record loaded from disk may stay undeclared before it is removed.
    /// Covers the window before writers have filled in state. Default: 2 minutes.
    static var removalGrace: Duration { get }

    /// Telemetry sink for operational events.
    ///
    /// Default: `NoopAstrolabeTelemetry()` — Astrolabe sends no telemetry.
    /// Override with `SignozAstrolabeTelemetry(...)` to opt in.
    static var telemetry: AstrolabeTelemetry { get }
}

extension Astrolabe {
    public static var resourceTypes: [any Resource.Type] { [] }
    public static var removalGrace: Duration { .seconds(120) }
    public static var telemetry: AstrolabeTelemetry { NoopAstrolabeTelemetry() }

    /// Entry point called by the Swift runtime when this type is marked `@main`.
    public static func main() async throws {
        guard getuid() == 0 else {
            throw AstrolabeError.notRunningAsRoot
        }
        await AstrolabeRoot<Self>.main(Array(CommandLine.arguments.dropFirst()))
    }
}

public enum AstrolabeError: Error, Sendable {
    case notRunningAsRoot
    case daemonInstallFailed(String)
}
