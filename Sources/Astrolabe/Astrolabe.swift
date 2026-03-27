import Darwin
import Foundation

/// A declarative macOS configuration.
///
/// Conform to this protocol and annotate your struct with `@main`
/// to create a configuration entry point:
///
/// ```swift
/// @main
/// struct MySetup: Astrolabe {
///     var body: some Setup {
///         EnrollmentComplete {
///             DevTools()
///         }
///         UserLogin {
///             PackageInstaller(.gitHub("owner/repo"))
///         }
///     }
/// }
/// ```
public protocol Astrolabe: Setup {
    associatedtype Body: Setup

    @SetupBuilder var body: Body { get }

    init()
}

extension Astrolabe {
    /// Executes this configuration's body. Enables nesting one Astrolabe inside another.
    public func execute() async throws {
        try await body.execute()
    }

    /// Entry point called by the Swift runtime when this type is marked `@main`.
    public static func main() async throws {
        guard getuid() == 0 else {
            throw AstrolabeError.notRunningAsRoot
        }
        installDaemon()
        let configuration = Self()
        try await configuration.execute()
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
