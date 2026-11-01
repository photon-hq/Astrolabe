/// Keeps a Homebrew formula or cask installed, and at or above a minimum version.
///
/// ```swift
/// var body: some Component {
///     CommandLineTools()
///     Homebrew(owner: "ops")
///     Brew("wget")
///     Brew("firefox", type: .cask)
///     Brew("tailscale", version: .atLeast("1.102.0"))
/// }
/// ```
///
/// Waits until Homebrew is on the Mac. Declare `Homebrew(owner:)` so it gets installed and kept
/// owned by one account; without it, `Brew` runs as whoever owns an existing Homebrew. Every
/// `brew` runs as that owner, one at a time. A hand-run `brew uninstall` is undone within a
/// minute. Dropping it from `body` uninstalls it. Changing `version` or tap-qualifying `name`
/// never does. Use canonical names (`python@3.13`, not the alias `python3`).
public struct Brew: Component {
    public enum PackageType: String, Sendable, Hashable, Codable {
        case formula
        case cask
    }

    /// Which installed versions satisfy this declaration. Not part of the id: changing it
    /// upgrades in place and never uninstalls.
    public enum Version: Sendable, Hashable {
        /// Any installed version. Never upgrades. The default.
        case installed
        /// `brew upgrade` while the installed version is below this. Homebrew installs its
        /// latest release, not this version itself.
        case atLeast(String)
    }

    let name: String
    let type: PackageType
    let version: Version
    @Fact(\.homebrew.isInstalled) private var homebrewInstalled

    public init(_ name: String, type: PackageType = .formula, version: Version = .installed) {
        self.name = name
        self.type = type
        self.version = version
    }

    public var body: some Component {
        // Gated on `isInstalled`, never on one owner: mixed owners would hide every package,
        // and a hidden package is uninstalled. `isInstalled` goes false only when `bin/brew` is
        // gone, and then the Cellar usually is too, so `remove` finds nothing to remove.
        if homebrewInstalled {
            BrewPackage(name: name, type: type, minimum: version.minimum)
        }
    }
}

extension Brew.Version {
    /// `.atLeast`'s floor, or `nil` for `.installed`.
    var minimum: String? {
        switch self {
        case .installed: nil
        case .atLeast(let minimum): minimum
        }
    }
}

/// Keeps one formula or cask installed and at `minimum` or above. Declared by `Brew`.
@Resource
struct BrewPackage {
    static let kind = "astrolabe.brew"
    /// As declared, maybe tap-qualified (`cloudflare/cloudflare/cloudflared`). `brew install` gets it.
    let name: String
    let type: Brew.PackageType
    /// `.atLeast`'s floor, or `nil` for any installed version.
    let minimum: String?
    /// Installed and at or above `minimum`. A hand-run `brew uninstall` or a downgrade (false)
    /// reruns `rollout`. An upgrade made outside Astrolabe changes nothing.
    @Monitor var satisfied: Bool?

    init(name: String, type: Brew.PackageType, minimum: String?) {
        self.name = name
        self.type = type
        self.minimum = minimum
        _satisfied = Monitor(\.homebrew[satisfies: name, type, minimum])
    }

    /// The short name: tap-qualifying a name rolls out the same id rather than installing one
    /// keg and uninstalling the same keg, with no order between the two.
    var id: String { "brew:\(type.rawValue):\(BrewName.short(name))" }

    static func compute(_ package: Self) -> String {
        Hash.of(kind, package.name, package.type.rawValue, package.minimum)
    }

    @concurrent static func rollout(_ package: Self) async throws {
        try await BrewInstaller.ensure(package.name, type: package.type, minimum: package.minimum)
    }

    /// Uninstalls, as v1 did. Uses only what the id is built from. Not there: a no-op.
    @concurrent static func remove(_ package: Self) async throws {
        try await BrewInstaller.uninstall(package.name, type: package.type)
    }

    /// Failures are mostly network, Homebrew missing or mid re-own (fixed within a minute), or
    /// a floor Homebrew doesn't offer yet.
    static var retryPolicy: RetryPolicy { .retry(Backoff(initial: .seconds(60), max: .seconds(3600))) }

    /// Mostly waiting for the lock: on first boot every package queues behind the others.
    /// Each `brew` command is capped by `ProcessRunner.Timeout.install` (1 h) on its own.
    static var timeout: Duration { .seconds(4 * 3600) }
}
