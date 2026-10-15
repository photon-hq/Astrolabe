extension HomebrewFacts {
    /// Every formula and cask Homebrew has installed, with the version `brew` runs. Read from
    /// the prefix alone: `readdir` and `readlink`, no `brew`, so every minute is cheap.
    ///
    /// Read without the Homebrew lock. It only feeds `@Monitor`s, and a value caught mid-install
    /// just reruns a rollout that checks again under the lock. With the lock, a first boot that
    /// queues every package would also hold up drift detection.
    @FactEntry(schedule: .every(.seconds(60)), read: { try HomebrewReads.packages() })
    public var packages: BrewPackages = BrewPackages()

    /// Whether `name` (short or tap-qualified) is installed as `type`, at `minimum` or above
    /// (any version when `nil`). Tracked through `packages`. What `BrewPackage` monitors: one
    /// `Bool` per package, so installing one package doesn't rerun every other.
    subscript(satisfies name: String, type: Brew.PackageType, minimum: String?) -> Bool {
        BrewInstaller.check(packages, name, type: type, minimum: minimum) == .satisfied
    }
}

/// What Homebrew has installed. Each version is what `brew` runs: for a formula, the `opt`
/// link's target, otherwise (and for every cask) the highest version directory.
public struct BrewPackages: Equatable, Sendable {
    /// Short name → version.
    public var formulae: [String: String]
    /// Token → version.
    public var casks: [String: String]

    public init(formulae: [String: String] = [:], casks: [String: String] = [:]) {
        self.formulae = formulae
        self.casks = casks
    }

    /// The installed version of `name` (short or tap-qualified) as `type`, or `nil` when it
    /// isn't installed.
    public func version(of name: String, type: Brew.PackageType) -> String? {
        let short = BrewName.short(name)
        return switch type {
        case .formula: formulae[short]
        case .cask: casks[short]
        }
    }
}
