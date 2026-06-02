import Foundation

/// Sets the Mac's hostname (ComputerName, HostName, and LocalHostName).
///
/// ```swift
/// Sys(.hostname("dev-mac"))
/// ```
public struct HostnameSetting: SystemSetting {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public func check() async throws -> Bool {
        // Read the live system value the same way apply() writes it. Using
        // ProcessInfo.processInfo.hostName here would read a value cached at
        // process startup, so it would never observe a successful apply() and
        // the reconciler would remediate forever.
        let result = try await capture("/usr/sbin/scutil", ["--get", "HostName"])
        // `scutil --get HostName` exits non-zero ("HostName: not set") when the
        // key is unset; treat that as drifted so apply() runs.
        guard result.status == 0 else { return false }
        let current = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return current == name
    }

    public func apply() async throws {
        try await run("/usr/sbin/scutil", ["--set", "ComputerName", name])
        try await run("/usr/sbin/scutil", ["--set", "HostName", name])
        try await run("/usr/sbin/scutil", ["--set", "LocalHostName", name])
    }

    private func run(_ path: String, _ arguments: [String]) async throws {
        let result = try await capture(path, arguments)
        guard result.status == 0 else {
            throw ReconcileError.processFailed(path: path, arguments: arguments, output: result.output)
        }
    }

    private func capture(_ path: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}

extension SystemSetting where Self == HostnameSetting {
    /// Sets the Mac's hostname.
    public static func hostname(_ name: String) -> HostnameSetting {
        HostnameSetting(name)
    }
}
