/// Declares that a Homebrew package should be installed.
///
/// ```swift
/// Brew("wget")
/// Brew("firefox", type: .cask)
/// Brew("tailscale", version: .atLeast("1.102.0"))
/// Brew("htop", version: .latest())
/// ```
public struct Brew: Setup {
    public typealias Body = Never

    public enum PackageType: Sendable, Equatable {
        case formula
        case cask
    }

    /// Which installed versions satisfy this declaration.
    ///
    /// Not part of the node identity: changing the policy re-checks the existing node in
    /// place. A new identity would unmount, and so uninstall, the package.
    public enum Version: Sendable, Equatable {
        /// Any installed version. Never upgrades. The default.
        case installed
        /// Runs `brew upgrade` while the installed version is below `minimum`.
        /// Homebrew installs its latest release, not `minimum` itself.
        case atLeast(String)
        /// Auto-update: runs `brew upgrade` once per `checkEvery`. When the package is
        /// current that does nothing. The last-check time lives in memory, so a daemon
        /// start also counts as a check being due.
        ///
        /// Upgrading a running service's binary doesn't restart the service; the caller
        /// owns that (see the docs' level-triggered restart example).
        case latest(checkEvery: Duration = .hours(24))
    }

    public let name: String
    public let type: PackageType
    public let version: Version

    public init(_ name: String, type: PackageType = .formula, version: Version = .installed) {
        self.name = name
        self.type = type
        self.version = version
    }
}

extension Brew: Installable {}

extension Brew: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let flag = type == .cask ? "cask" : "formula"
        // Name and type only; see `Version`.
        let identity = NodeIdentity([.named("brew:\(flag):\(name)")])
        return TreeNode(identity: identity, kind: .leaf(BrewInfo(name: name, type: type, version: version)))
    }
}
