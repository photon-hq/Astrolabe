import Darwin
import Foundation

/// A declarative macOS configuration.
///
/// The entry point protocol. Like SwiftUI's `App`. Conform and annotate with `@main`:
///
/// ```swift
/// @main
/// struct MySetup: Astrolabe {
///     @State var showWelcome = true
///     @Environment(\.isEnrolled) var isEnrolled
///
///     var body: some Setup {
///         Pkg(.catalog(.homebrew))
///         Pkg("wget")
///
///         if isEnrolled {
///             Pkg("git-lfs")
///         }
///     }
/// }
/// ```
public protocol Astrolabe: Setup {
    init()

    /// How often the registry polls for state changes. Default: 5 seconds.
    var pollInterval: Duration { get }
}

extension Astrolabe {
    public var pollInterval: Duration { .seconds(5) }

    /// Entry point called by the Swift runtime when this type is marked `@main`.
    public static func main() async throws {
        guard getuid() == 0 else {
            throw AstrolabeError.notRunningAsRoot
        }
        installDaemon()

        let engine = LifecycleEngine(
            configuration: Self(),
            providers: [EnrollmentProvider(), ConsoleUserProvider()],
            pollInterval: Self().pollInterval
        )
        try await engine.run()
    }

    private static func installDaemon() {
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
