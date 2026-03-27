import Foundation

/// Installs a package via Jamf Pro policy.
///
/// ```swift
/// Package(.jamf(name: "Google Chrome"))
/// Package(.jamf(id: 1265))
/// Package(.jamf(trigger: "installChrome"))
/// ```
public struct JamfPackage: PackageProvider {
    public enum Identifier: Sendable {
        case name(String)
        case id(Int)
        case trigger(String)
    }

    public let identifier: Identifier

    public init(identifier: Identifier) {
        self.identifier = identifier
    }

    public func install() async throws {
        // TODO: Implement
        // Runs: jamf policy -event <trigger> / -id <id>
        // For name: look up package via Jamf API, then trigger its policy
        print("[Astrolabe] Installing from Jamf (\(identifier))...")
    }
}

extension PackageProvider where Self == JamfPackage {
    /// A package managed by Jamf Pro, identified by display name.
    public static func jamf(name: String) -> JamfPackage {
        JamfPackage(identifier: .name(name))
    }

    /// A package managed by Jamf Pro, identified by package ID.
    public static func jamf(id: Int) -> JamfPackage {
        JamfPackage(identifier: .id(id))
    }

    /// A package managed by Jamf Pro, triggered by a custom policy event.
    public static func jamf(trigger: String) -> JamfPackage {
        JamfPackage(identifier: .trigger(trigger))
    }
}
