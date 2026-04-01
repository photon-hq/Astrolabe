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
        let current = ProcessInfo.processInfo.hostName
        // hostName may include ".local" suffix
        return current == name || current == "\(name).local"
    }

    public func apply() async throws {
        try await run("/usr/sbin/scutil", ["--set", "ComputerName", name])
        try await run("/usr/sbin/scutil", ["--set", "HostName", name])
        try await run("/usr/sbin/scutil", ["--set", "LocalHostName", name])
    }

    private func run(_ path: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ReconcileError.processFailed(path: path, arguments: arguments, output: output)
        }
    }
}

extension SystemSetting where Self == HostnameSetting {
    /// Sets the Mac's hostname.
    public static func hostname(_ name: String) -> HostnameSetting {
        HostnameSetting(name)
    }
}
