import Foundation
import Semaphore
import SystemConfiguration
import os

/// Brew-specific utilities. Owns the brew semaphore for serialization.
enum BrewHelper {

    /// Serializes all brew operations (brew uses internal locks that conflict under parallelism).
    private static let semaphore = AsyncSemaphore(value: 1)

    /// When each `.latest` package last finished a successful `brew upgrade`, keyed by
    /// `checkKey`. Kept in memory on purpose: a daemon start re-checks once.
    private static let lastUpgradeCheck = OSAllocatedUnfairLock<[String: ContinuousClock.Instant]>(initialState: [:])

    /// Test seam, using the same `@TaskLocal` pattern as `EnvironmentValues.current`. Tests
    /// assert the exact brew argv without spawning brew; production uses `execute`. Only the
    /// upgrade paths consult it.
    @TaskLocal static var commandOverride: (@Sendable (_ arguments: [String], _ user: String?) async throws -> Void)?

    static var path: String {
        #if arch(arm64)
        "/opt/homebrew/bin/brew"
        #else
        "/usr/local/bin/brew"
        #endif
    }

    static var prefix: String {
        #if arch(arm64)
        "/opt/homebrew"
        #else
        "/usr/local/Homebrew"
        #endif
    }

    /// Resolves the user who should run brew commands.
    /// Primary: owner of the Homebrew prefix directory.
    /// Fallback: the current console user (for bootstrap before Homebrew exists).
    static func brewUser() -> String? {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: prefix),
           let uid = attrs[.ownerAccountID] as? NSNumber {
            let uidValue = uid.uint32Value
            if uidValue != 0, let pw = getpwuid(uidValue) {
                return String(cString: pw.pointee.pw_name)
            }
        }
        // Fallback: console user (prefix may not exist yet during bootstrap)
        var uid: uid_t = 0
        guard let username = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String,
              uid != 0,
              username != "loginwindow"
        else { return nil }
        return username
    }

    /// Extracts the short formula/cask name from a potentially tap-qualified name.
    /// e.g. `cloudflare/cloudflare/cloudflared` → `cloudflared`, `wget` → `wget`
    static func shortName(_ name: String) -> String {
        let components = name.split(separator: "/")
        // Tap-qualified names have 3 components: user/tap/formula
        if components.count == 3 {
            return String(components[2])
        }
        return name
    }

    /// Resolves the credentials and environment brew should run under.
    ///
    /// Replaces the old `/usr/bin/sudo -u <user> brew …` prefix. `sudo` was doing three
    /// things — dropping credentials, installing the user's supplementary groups, and
    /// resetting `HOME`/`USER`/`LOGNAME`/`SHELL` — and `UserContext` reproduces all three
    /// explicitly. `HOME` matters most here: Homebrew derives its cache path from it, so
    /// inheriting the daemon's `/var/root` would put downloads in the wrong place.
    ///
    /// Returns `nil` when brew should run as the current user (root, in the daemon).
    static func userContext(_ user: String?) -> UserContext? {
        user.flatMap { UserContext(username: $0)?.prependingPath("\(prefix)/bin") }
    }

    /// Checks whether a brew package is installed, by reading the Cellar/Caskroom.
    ///
    /// `brew list <name>` answers this question by consulting exactly these directories, but
    /// pays a Ruby interpreter startup (~0.4s warm) to do it. That is affordable once during
    /// `mount`; on the drift loop it was the daemon's most-spawned subprocess, since every
    /// `Brew` leaf re-checks on its own `loopInterval` — 15s by default.
    ///
    /// Reading the directories directly also drops three hazards the subprocess carried. It
    /// cannot time out, which matters because a timed-out `brew list` read as "not installed"
    /// and cost a full reinstall. It cannot contend with a concurrent `brew install` on
    /// Homebrew's lockfile, which the drift-loop call did — it ran outside the semaphore. And
    /// it needs no credential drop: the prefix is world-readable, so the root daemon reads it
    /// without `userContext`.
    ///
    /// The predicate matches Homebrew's own — installed means *at least one non-empty version
    /// directory*. Existence alone is not enough: an interrupted uninstall leaves an empty
    /// `Cellar/<name>` behind, and `brew list --formula <name>` exits non-zero for one. (Bulk
    /// `brew list --formula` does print such leftovers, so the per-package query this replaces
    /// was the stricter of brew's two answers, and this keeps that stricter reading.)
    ///
    /// - Parameter prefix: The Homebrew prefix to read. Injectable for tests only.
    static func isInstalled(
        _ name: String,
        type: Brew.PackageType,
        prefix: String = BrewHelper.prefix
    ) -> Bool {
        !kegs(name, type: type, prefix: prefix).isEmpty
    }

    /// The version brew treats as current, read from the filesystem only, like `isInstalled`.
    ///
    /// For a formula that is the `opt/<name>` link target: with two kegs side by side (an
    /// upgrade that hasn't been cleaned up), the link is what brew runs. Otherwise, and
    /// always for casks, which have no `opt` link, it is the highest version directory.
    /// Unparseable directory names (`HEAD-…`, a cask's `latest`) are returned only when
    /// nothing parses, so the caller can report them.
    static func installedVersion(
        _ name: String,
        type: Brew.PackageType,
        prefix: String = BrewHelper.prefix
    ) -> String? {
        let kegs = kegs(name, type: type, prefix: prefix)
        if type == .formula,
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(prefix)/opt/\(shortName(name))"),
           let linked = target.split(separator: "/").last.map(String.init),
           kegs.contains(linked) {
            return linked
        }
        let parsed = kegs.compactMap { keg in BrewVersion(keg).map { (keg, $0) } }
        if let highest = parsed.max(by: { $0.1 < $1.1 }) { return highest.0 }
        return kegs.sorted().first
    }

    /// Where an installed package stands against its declared `Brew.Version`.
    enum VersionCheck: Equatable {
        case notInstalled
        case satisfied
        case below(installed: String, minimum: String)
        /// An unparseable version on either side.
        case uncomparable(installed: String?, minimum: String)
        /// `.latest`: the interval has elapsed, or this process never checked.
        case updateDue
    }

    /// A pure decision, shared by `loop` (cheap) and `upgradeIfBelow` (under the lock). Reads
    /// the filesystem and the in-memory check times; never spawns.
    static func check(
        _ name: String,
        type: Brew.PackageType,
        version: Brew.Version,
        prefix: String = BrewHelper.prefix,
        now: ContinuousClock.Instant = .now
    ) -> VersionCheck {
        guard isInstalled(name, type: type, prefix: prefix) else { return .notInstalled }
        switch version {
        case .installed:
            return .satisfied
        case .atLeast(let minimum):
            let installed = installedVersion(name, type: type, prefix: prefix)
            guard let installed, let current = BrewVersion(installed), let floor = BrewVersion(minimum) else {
                return .uncomparable(installed: installed, minimum: minimum)
            }
            return current < floor ? .below(installed: installed, minimum: minimum) : .satisfied
        case .latest(let interval):
            return isUpdateDue(name, type: type, every: interval, now: now) ? .updateDue : .satisfied
        }
    }

    /// The non-empty version directories under `Cellar/<name>` or `Caskroom/<name>`.
    private static func kegs(_ name: String, type: Brew.PackageType, prefix: String) -> [String] {
        // Cellar and Caskroom key on the bare token — a tap-qualified name has no directory.
        let root = "\(prefix)/\(type == .cask ? "Caskroom" : "Cellar")/\(shortName(name))"
        let fileManager = FileManager.default
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return versions.filter { version in
            // A cask's `.metadata` holds its install receipts and outlives an uninstall —
            // bookkeeping, not an installed version.
            guard version != ".metadata" else { return false }
            // Non-empty *and* a directory: `contentsOfDirectory` throws on a plain file, so a
            // stray `.DS_Store` at this level cannot read as a version.
            let contents = try? fileManager.contentsOfDirectory(atPath: "\(root)/\(version)")
            return contents?.isEmpty == false
        }
    }

    /// Runs a brew command as the console user, serialized via semaphore.
    static func run(_ arguments: [String], user: String?) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }
        try await execute(arguments, user: user)
    }

    /// Checks and installs atomically under the brew semaphore.
    ///
    /// The check no longer needs the semaphore on its own — it reads the Cellar/Caskroom
    /// rather than shelling out — but holding it across check-then-install still does: it
    /// stops two mounts of the same package from both observing "absent" and racing two
    /// `brew install`s onto Homebrew's lockfile.
    static func installIfNeeded(_ name: String, type: Brew.PackageType, user: String?) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }

        if isInstalled(name, type: type) {
            print("[Astrolabe] \(name) already installed, skipping.")
            return
        }

        var args = ["install"]
        if type == .cask { args.append("--cask") }
        args.append(name)

        let kind = type == .cask ? "cask" : "formula"
        let userDesc = user.map { "as \($0)" } ?? "as root"
        print("[Astrolabe] Installing \(kind) \(name) \(userDesc)...")

        try await execute(args, user: user)
        // A fresh install is already Homebrew's latest, so a `.latest` package needn't
        // run `brew upgrade` straight after it.
        recordUpgradeCheck(name, type: type, at: .now)
        print("[Astrolabe] Installed \(name).")
    }

    /// Holds the brew semaphore across check-then-upgrade, like `installIfNeeded`.
    ///
    /// Throws when Homebrew's latest is still below the floor, so a typo'd or unreleased
    /// minimum shows up as `astrolabe.mount.failed`, not a silent no-op.
    static func upgradeIfBelow(
        _ name: String,
        type: Brew.PackageType,
        version: Brew.Version,
        user: String?,
        prefix: String = BrewHelper.prefix
    ) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }

        switch check(name, type: type, version: version, prefix: prefix) {
        case .notInstalled, .satisfied, .updateDue:
            return
        case .uncomparable(let installed, let minimum):
            throw BrewError.uncomparableVersion(name: name, installed: installed, minimum: minimum)
        case .below(let installed, let minimum):
            print("[Astrolabe] Upgrading \(name) \(installed) (below \(minimum))...")
            try await runBrew(upgradeArguments(name, type: type), user: user)
            let upgraded = installedVersion(name, type: type, prefix: prefix)
            guard check(name, type: type, version: version, prefix: prefix) == .satisfied else {
                throw BrewError.minimumUnavailable(name: name, installed: upgraded, minimum: minimum)
            }
            print("[Astrolabe] Upgraded \(name) \(installed) → \(upgraded ?? "?").")
        }
    }

    /// Auto-update: runs `brew upgrade` when a check is due, under the lock.
    ///
    /// The check time is recorded only on success, so a network failure throws, backs off,
    /// and retries instead of waiting another full interval.
    static func upgradeIfDue(
        _ name: String,
        type: Brew.PackageType,
        every interval: Duration,
        user: String?,
        prefix: String = BrewHelper.prefix,
        now: ContinuousClock.Instant = .now
    ) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }

        guard isUpdateDue(name, type: type, every: interval, now: now) else { return }
        let before = installedVersion(name, type: type, prefix: prefix)
        try await runBrew(upgradeArguments(name, type: type), user: user)
        recordUpgradeCheck(name, type: type, at: now)
        let after = installedVersion(name, type: type, prefix: prefix)
        print(before == after
            ? "[Astrolabe] \(name) is current (\(after ?? "?"))."
            : "[Astrolabe] Upgraded \(name) \(before ?? "?") → \(after ?? "?").")
    }

    /// Uninstalls a brew package, serialized via semaphore.
    static func uninstall(_ name: String, cask: Bool) async throws {
        guard isInstalled(name, type: cask ? .cask : .formula) else { return }
        var args = ["uninstall"]
        if cask { args.append("--cask") }
        args.append(name)
        try await run(args, user: brewUser())
    }

    // MARK: - Private

    private static func upgradeArguments(_ name: String, type: Brew.PackageType) -> [String] {
        ["upgrade"] + (type == .cask ? ["--cask"] : []) + [name]
    }

    /// Formula and cask namespaces are separate, so the key carries the type.
    private static func checkKey(_ name: String, type: Brew.PackageType) -> String {
        "\(type == .cask ? "cask" : "formula"):\(name)"
    }

    private static func isUpdateDue(
        _ name: String,
        type: Brew.PackageType,
        every interval: Duration,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard let last = lastUpgradeCheck.withLock({ $0[checkKey(name, type: type)] }) else { return true }
        return last.duration(to: now) >= interval
    }

    private static func recordUpgradeCheck(_ name: String, type: Brew.PackageType, at instant: ContinuousClock.Instant) {
        lastUpgradeCheck.withLock { $0[checkKey(name, type: type)] = instant }
    }

    /// `execute`, unless a test has set `commandOverride`.
    private static func runBrew(_ arguments: [String], user: String?) async throws {
        if let commandOverride {
            try await commandOverride(arguments, user)
        } else {
            try await execute(arguments, user: user)
        }
    }

    /// Runs brew with output streamed rather than collected.
    ///
    /// `brew install` is verbose and slow enough that buffering it would risk
    /// `outputLimitExceeded` and leave a multi-minute install silent; streaming echoes
    /// progress and keeps only a bounded tail for the error message.
    private static func execute(_ arguments: [String], user: String?) async throws {
        try await ProcessRunner.stream(
            path,
            arguments: arguments,
            as: userContext(user)
        ) { line in
            print("[Astrolabe] brew: \(line)")
        }
    }
}

/// Errors raised by a `Brew` version policy. The description reaches telemetry as
/// `astrolabe.error.message`.
public enum BrewError: Error, Sendable, CustomStringConvertible {
    /// The installed version or the declared minimum doesn't parse as a Homebrew version.
    case uncomparableVersion(name: String, installed: String?, minimum: String)
    /// `brew upgrade` succeeded but Homebrew's latest is still below the minimum.
    case minimumUnavailable(name: String, installed: String?, minimum: String)

    public var description: String {
        switch self {
        case .uncomparableVersion(let name, let installed, let minimum):
            return "brew \(name): installed version \(installed ?? "unknown") cannot be compared to minimum \(minimum)"
        case .minimumUnavailable(let name, let installed, let minimum):
            return "brew \(name): Homebrew's latest (\(installed ?? "unknown")) is below minimum \(minimum)"
        }
    }
}
