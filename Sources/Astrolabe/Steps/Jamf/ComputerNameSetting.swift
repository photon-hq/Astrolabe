import Foundation

/// Sets the computer name in Jamf and runs a recon to update inventory.
///
/// Requires Jamf to be installed at `/usr/local/bin/jamf`.
///
/// ```swift
/// Jamf(.computerName("dev-mac"))
/// ```
///
/// - Note: This sets `ComputerName`, which `Sys(.hostname(_:))` also owns (with
///   strict, all-three-facet matching). Declaring both for the same Mac means
///   two independent loops drive `ComputerName` — avoid, or expect them to take
///   turns. Reconciling ownership is tracked as a separate follow-up.
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
        // `.combined` preserves the old shared-pipe behavior: the jamf binary is not
        // consistent about which stream it names the computer on.
        let current = try await ProcessRunner.run(Self.jamfPath, arguments: ["getComputerName"]).combined
        return current.contains(name)
    }

    public func apply() async throws {
        guard FileManager.default.fileExists(atPath: Self.jamfPath) else { return }
        try await ProcessRunner.run(Self.jamfPath, arguments: ["setComputerName", "-name", name])
        // A recon walks the whole inventory: slow and chatty, so stream it.
        try await ProcessRunner.stream(Self.jamfPath, arguments: ["recon"])
    }
}

extension JamfSetting where Self == ComputerNameSetting {
    /// Sets the Jamf computer name and runs a recon.
    public static func computerName(_ name: String) -> ComputerNameSetting {
        ComputerNameSetting(name)
    }
}
