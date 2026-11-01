import ArgumentParser
import Darwin
import Foundation

/// A declarative macOS configuration. The root component; like SwiftUI's `App`.
///
/// `body` reads facts about the Mac with `@Fact`, in the app or in any component. The engine
/// reads each fact from the Mac on its own schedule and runs a pass when one that `body` read
/// changes; nothing in the app writes state.
///
/// ```swift
/// @main
/// struct StagingApp: Astrolabe {
///     @Fact(\.stagingFiles) var files
///
///     var body: some Component {
///         for (name, contents) in files.sorted(by: { $0.key < $1.key }) {
///             StagingFile(path: "/tmp/astrolabe-staging/\(name)", contents: contents)
///         }
///     }
/// }
/// ```
///
/// Resource types aren't listed: `@Resource` records each one in the binary, and the engine
/// finds them all at launch.
@MainActor
public protocol Astrolabe: Component, SendableMetatype {
    init()

    /// Telemetry sink for operational events.
    ///
    /// Default: `NoopAstrolabeTelemetry()` — Astrolabe sends no telemetry.
    /// Override with `SignozAstrolabeTelemetry(...)` to opt in.
    static var telemetry: AstrolabeTelemetry { get }
}

extension Astrolabe {
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
