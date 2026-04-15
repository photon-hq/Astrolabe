import Foundation

/// Sets the computer name in Jamf and runs a recon to update inventory.
///
/// Requires Jamf to be installed at `/usr/local/bin/jamf`.
///
/// ```swift
/// Jamf(.computerName("dev-mac"))
/// ```
public struct ComputerNameSetting: JamfSetting {
    static let jamfPath = "/usr/local/bin/jamf"

    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public func check() async throws -> Bool {
        guard FileManager.default.fileExists(atPath: Self.jamfPath) else {
            return true // Jamf not installed — nothing to do
        }
        let current = try await output(Self.jamfPath, ["getComputerName"])
        return current.contains(name)
    }

    public func apply() async throws {
        guard FileManager.default.fileExists(atPath: Self.jamfPath) else { return }
        try await run(Self.jamfPath, ["setComputerName", "-name", name])
        try await run(Self.jamfPath, ["recon"])
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
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ReconcileError.processFailed(path: path, arguments: arguments, output: out)
        }
    }

    private func output(_ path: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ReconcileError.processFailed(path: path, arguments: arguments, output: out)
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

extension JamfSetting where Self == ComputerNameSetting {
    /// Sets the Jamf computer name and runs a recon.
    public static func computerName(_ name: String) -> ComputerNameSetting {
        ComputerNameSetting(name)
    }
}
