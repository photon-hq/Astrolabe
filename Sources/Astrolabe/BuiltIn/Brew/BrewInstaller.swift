/// Formula and cask names as Homebrew's directories key them.
enum BrewName {
    /// `cloudflare/cloudflare/cloudflared` → `cloudflared`; `wget` → `wget`. Cellar, Caskroom
    /// and ids key on this. Shortening twice changes nothing.
    static func short(_ name: String) -> String {
        let components = name.split(separator: "/")
        // A tap-qualified name is user/tap/name.
        return components.count == 3 ? String(components[2]) : name
    }
}

extension Brew.PackageType {
    /// `--formula` or `--cask`. Every `brew` names the type, so a formula and a cask with one
    /// name are never ambiguous.
    var flag: String { "--\(rawValue)" }
}

/// Where an installed package stands against its declared minimum.
enum BrewCheck: Equatable {
    case notInstalled
    case satisfied
    case below(installed: String, minimum: String)
    /// An unparseable version on either side: a `HEAD-…` keg, a cask's `latest`, a `v1.2` floor.
    case uncomparable(installed: String, minimum: String)
}

/// Installs, upgrades and uninstalls formulae and casks, as Homebrew's one owner.
enum BrewInstaller {
    /// Pure: where `name` (short or tap-qualified; shortened here) stands in `packages` against
    /// `minimum`. Shared by the monitor subscript, rollout's no-lock check, its locked check,
    /// and its verify.
    static func check(_ packages: BrewPackages, _ name: String, type: Brew.PackageType, minimum: String?) -> BrewCheck {
        guard let installed = packages.version(of: name, type: type) else { return .notInstalled }
        guard let minimum else { return .satisfied }
        guard let current = BrewVersion(installed), let floor = BrewVersion(minimum) else {
            return .uncomparable(installed: installed, minimum: minimum)
        }
        return current < floor ? .below(installed: installed, minimum: minimum) : .satisfied
    }

    /// Makes sure `name` is installed as `type`, at `minimum` or above: `brew install` when it's
    /// missing, `brew upgrade` when it's below. Never upgrades a version it can't compare.
    ///
    /// Checks the Mac first, without the lock: a satisfied package never waits on another's
    /// install. Every `brew` runs under `HomebrewContext.lock`, as the one owner.
    static func ensure(_ name: String, type: Brew.PackageType, minimum: String?) async throws {
        let context = HomebrewContext.current
        let system = context.system
        guard try needsBrew(check(try system.packages(), name, type: type, minimum: minimum), name) else { return }

        try await HomebrewInstaller.locked(context) {
            try Task.checkCancellation()
            let found = check(try system.packages(), name, type: type, minimum: minimum)
            guard try needsBrew(found, name) else { return }  // another rollout just did it
            let owner = try owner(system)
            let verb = found == .notInstalled ? "install" : "upgrade"
            // The declared name: a tap-qualified one taps it.
            try await system.brew([verb, type.flag, name], as: owner)

            switch check(try system.packages(), name, type: type, minimum: minimum) {
            case .satisfied:
                return
            case .notInstalled:
                throw BrewError.didNotInstall(name: name)
            case .below(let installed, let minimum):
                throw BrewError.minimumUnavailable(name: name, installed: installed, minimum: minimum)
            case .uncomparable(let installed, let minimum):
                throw BrewError.uncomparableVersion(name: name, installed: installed, minimum: minimum)
            }
        }
    }

    /// Uninstalls `name` as `type`, if it's installed. Only the short name and the type: what an
    /// id is built from, and all a removal can rely on.
    static func uninstall(_ name: String, type: Brew.PackageType) async throws {
        let context = HomebrewContext.current
        let system = context.system
        let short = BrewName.short(name)
        guard try system.packages().version(of: short, type: type) != nil else { return }

        try await HomebrewInstaller.locked(context) {
            // Declared again while waiting: the engine cancelled this, and nothing is uninstalled.
            try Task.checkCancellation()
            guard try system.packages().version(of: short, type: type) != nil else { return }
            let owner = try owner(system)
            try await system.brew(["uninstall", type.flag, short], as: owner)
            guard try system.packages().version(of: short, type: type) == nil else {
                throw BrewError.didNotUninstall(name: short)
            }
        }
    }

    // MARK: - Private

    /// Whether `found` needs a `brew`. An uncomparable version throws: it never upgrades.
    private static func needsBrew(_ found: BrewCheck, _ name: String) throws -> Bool {
        switch found {
        case .satisfied:
            false
        case .notInstalled, .below:
            true
        case .uncomparable(let installed, let minimum):
            throw BrewError.uncomparableVersion(name: name, installed: installed, minimum: minimum)
        }
    }

    /// Call under the lock: the one account that owns Homebrew, from `system.owners()`. `[]`
    /// throws `homebrewMissing`. Several owners, a uid with no account (`#501`), or root throw
    /// `homebrewNotReady`.
    ///
    /// Never `HomebrewReads.owners()`: it takes the same lock, and would wait on itself.
    private static func owner(_ system: any HomebrewSystem) throws -> String {
        let owners = try system.owners()
        guard !owners.isEmpty else { throw BrewError.homebrewMissing }
        guard owners.count == 1, let owner = owners.first, let uid = system.uid(of: owner), uid != 0 else {
            throw BrewError.homebrewNotReady(owners: owners)
        }
        return owner
    }
}

enum BrewError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `brew` isn't at the prefix. The app declares `Homebrew(owner:)`; `Brew` never installs it.
    case homebrewMissing
    /// Homebrew is owned by several accounts, by root, or by a uid with no account. `Homebrew`
    /// re-owns it within a minute, and the retry runs as the one owner.
    case homebrewNotReady(owners: [String])
    /// `brew install` succeeded, but the package isn't in the Cellar or Caskroom: often an alias.
    case didNotInstall(name: String)
    /// `brew uninstall` succeeded, but the package is still there.
    case didNotUninstall(name: String)
    /// The installed version or the declared minimum doesn't parse as a Homebrew version.
    case uncomparableVersion(name: String, installed: String, minimum: String)
    /// `brew upgrade` succeeded, but Homebrew's latest is still below the minimum.
    case minimumUnavailable(name: String, installed: String, minimum: String)

    var description: String {
        switch self {
        case .homebrewMissing:
            "Homebrew isn't installed: declare Homebrew(owner:)"
        case .homebrewNotReady(let owners):
            "Homebrew is owned by \(owners.joined(separator: ", ")): waiting for one owner that isn't root"
        case .didNotInstall(let name):
            "brew install \(name) finished, but \(BrewName.short(name)) isn't installed (an alias? use the canonical name)"
        case .didNotUninstall(let name):
            "brew uninstall \(name) finished, but \(name) is still installed"
        case .uncomparableVersion(let name, let installed, let minimum):
            "brew \(name): installed version \(installed) can't be compared to minimum \(minimum)"
        case .minimumUnavailable(let name, let installed, let minimum):
            "brew \(name): Homebrew's latest (\(installed)) is below minimum \(minimum)"
        }
    }
}
