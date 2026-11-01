import Foundation
@testable import Astrolabe

/// Stands in for Homebrew on the Mac. Bound through `HomebrewContext`, the way `FakeCLTSystem`
/// is bound through `CommandLineToolsContext`.
///
/// Holds whether the prefix and `brew` are there, who owns the prefix, and every installed
/// formula and cask with its version and owner. Like the real `install.sh`, `runInstallScript`
/// fails unless its user owns the prefix (it would need `sudo`), then puts `brew` down owned by
/// that user and waits while held. Like the real `brew`, `brew` fails unless its user owns the
/// prefix, and lands Homebrew's latest version. Records every call, can fail any step on
/// command, and can hold any async call until released.
final class FakeHomebrewSystem: HomebrewSystem, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case owners
        case createPrefix
        case reown(String)
        case runInstallScript(String)
        case addToPaths
        case brewVersion(String)
        case packages
        /// `brew <arguments>` as the user.
        case brew([String], String)
    }

    /// The calls a test can fail. The async ones can be held too.
    enum Step: Hashable, Sendable {
        case owners, createPrefix, reown, runInstallScript, addToPaths, brewVersion, packages, brew
    }

    /// A formula or cask, by its short name.
    struct Key: Hashable, Sendable {
        let type: Brew.PackageType
        let name: String
    }

    struct FakeError: Error {}

    /// What `install.sh` and `brew` say when they would need `sudo` for the prefix.
    struct InsufficientPermissions: Error {}

    /// What `brew upgrade` and `brew uninstall` say about a package that isn't installed.
    struct NotInstalled: Error {}

    private let lock = NSLock()
    private var _appleSilicon = true
    private var users: [String: uid_t] = ["root": 0, "ops": 501, "bob": 502, "alice": 503]
    private var prefixExists = false
    private var brewPresent = false
    private var prefixOwner = "root"
    private var installed: [Key: (version: String, owner: String)] = [:]
    /// What `brew install` and `brew upgrade` land. `"1.0"` when unset.
    private var latest: [Key: String] = [:]
    private var _brewRuns = true
    private var _inPaths = false
    private var reownTakes = true
    private var brewTakes = true
    private var running = 0
    private var _maxRunning = 0
    private var _calls: [Call] = []
    private var failures: [Step: Int] = [:]
    private var held: Set<Step> = []

    /// A Mac with Homebrew owned by `owner`, or without Homebrew.
    init(owner: String? = nil) {
        if let owner { setInstalled(owner: owner) }
    }

    // MARK: - The Mac

    /// What `owners` reads, without recording a call.
    var ownersOnMac: [String] {
        lock.withLock {
            guard brewPresent else { return [] }
            return Set([prefixOwner] + installed.values.map(\.owner)).sorted()
        }
    }

    var appleSilicon: Bool {
        get { lock.withLock { _appleSilicon } }
        set { lock.withLock { _appleSilicon = newValue } }
    }

    /// Whether `brew --version` succeeds while Homebrew is there.
    var brewRuns: Bool {
        get { lock.withLock { _brewRuns } }
        set { lock.withLock { _brewRuns = newValue } }
    }

    /// Whether `/etc/paths.d/homebrew` is there.
    var inPaths: Bool { lock.withLock { _inPaths } }

    /// What `packages` reads, without recording a call.
    var packagesOnMac: BrewPackages {
        lock.withLock {
            var packages = BrewPackages()
            for (key, package) in installed {
                switch key.type {
                case .formula: packages.formulae[key.name] = package.version
                case .cask: packages.casks[key.name] = package.version
                }
            }
            return packages
        }
    }

    /// The installed version of `name` as `type`, or `nil`.
    func version(_ name: String, type: Brew.PackageType = .formula) -> String? {
        lock.withLock { installed[Key(type: type, name: name)]?.version }
    }

    /// Homebrew installed without Astrolabe, owned by `owner`.
    func setInstalled(owner: String) {
        lock.withLock {
            (prefixExists, brewPresent, prefixOwner) = (true, true, owner)
            installed = installed.mapValues { ($0.version, owner) }
        }
    }

    /// `rm -rf /opt/homebrew`.
    func deleteBrew() {
        lock.withLock {
            (prefixExists, brewPresent, prefixOwner) = (false, false, "root")
            installed = [:]
        }
    }

    /// `rm /opt/homebrew/bin/brew`: the prefix and everything else in it stay.
    func deleteBrewCommand() {
        lock.withLock { brewPresent = false }
    }

    /// `brew install <formula>` run as `owner`: another administrator, say.
    func addFormula(_ formula: String, owner: String) {
        setPackage(formula, version: "1.0", owner: owner)
    }

    /// `name` installed as `type` at `version`, owned by `owner`, without Astrolabe.
    func setPackage(_ name: String, type: Brew.PackageType = .formula, version: String, owner: String) {
        lock.withLock { installed[Key(type: type, name: name)] = (version, owner) }
    }

    /// `brew uninstall <name>` run by hand.
    func uninstallByHand(_ name: String, type: Brew.PackageType = .formula) {
        _ = lock.withLock { installed.removeValue(forKey: Key(type: type, name: name)) }
    }

    /// What `brew install` and `brew upgrade` of `name` land from now on.
    func setLatest(_ name: String, type: Brew.PackageType = .formula, version: String) {
        lock.withLock { latest[Key(type: type, name: name)] = version }
    }

    /// `reown` returns without changing the Mac.
    func reownDoesNotTake() { lock.withLock { reownTakes = false } }

    /// `brew` exits 0 without changing the Mac.
    func brewDoesNotTake() { lock.withLock { brewTakes = false } }

    // MARK: - Inspection

    var calls: [Call] { lock.withLock { _calls } }

    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    /// Every call but the reads: what changed the Mac, or tried to.
    var changes: [Call] {
        calls.filter {
            switch $0 {
            case .owners, .brewVersion, .packages: false
            default: true
            }
        }
    }

    /// Users `install.sh` ran as, in order, including runs that failed or were cancelled.
    var installs: [String] {
        calls.compactMap { if case .runInstallScript(let user) = $0 { user } else { nil } }
    }

    /// The arguments of every `brew`, in order, including ones that failed or were cancelled.
    var brews: [[String]] {
        calls.compactMap { if case .brew(let arguments, _) = $0 { arguments } else { nil } }
    }

    /// The most `brew`s that ever ran at once.
    var maxRunning: Int { lock.withLock { _maxRunning } }

    // MARK: - Control

    /// The next `times` calls of `step` throw `FakeError`.
    func fail(_ step: Step, times: Int = 1) { lock.withLock { failures[step, default: 0] += times } }

    /// Holds every call of `step` until `release(step)`. A held call still ends early with
    /// `CancellationError` when cancelled.
    func hold(_ step: Step) { _ = lock.withLock { held.insert(step) } }
    func release(_ step: Step) { _ = lock.withLock { held.remove(step) } }

    // MARK: - HomebrewSystem

    func isAppleSilicon() -> Bool { appleSilicon }

    func uid(of user: String) -> uid_t? { lock.withLock { users[user] } }

    func owners() throws -> [String] {
        record(.owners)
        try failIfAsked(.owners)
        return ownersOnMac
    }

    func createPrefix() throws {
        record(.createPrefix)
        try failIfAsked(.createPrefix)
        lock.withLock {
            guard !prefixExists else { return }
            (prefixExists, prefixOwner) = (true, "root")
        }
    }

    func reown(_ user: String) async throws {
        record(.reown(user))
        try await wait(.reown)
        try failIfAsked(.reown)
        lock.withLock {
            guard reownTakes, prefixExists else { return }
            prefixOwner = user
            installed = installed.mapValues { ($0.version, user) }
        }
    }

    func runInstallScript(as user: String) async throws {
        record(.runInstallScript(user))
        try failIfAsked(.runInstallScript)
        try lock.withLock {
            guard prefixExists, prefixOwner == user else { throw InsufficientPermissions() }
            brewPresent = true
        }
        try await wait(.runInstallScript)
    }

    func addToPaths() throws {
        record(.addToPaths)
        try failIfAsked(.addToPaths)
        lock.withLock { _inPaths = true }
    }

    func brewVersion(as user: String) async throws -> String? {
        record(.brewVersion(user))
        try await wait(.brewVersion)
        try failIfAsked(.brewVersion)
        return lock.withLock { brewPresent && _brewRuns ? "Homebrew 5.0.0" : nil }
    }

    func packages() throws -> BrewPackages {
        record(.packages)
        try failIfAsked(.packages)
        return packagesOnMac
    }

    /// Understands `install`, `upgrade` and `uninstall`, each with `--formula` or `--cask`.
    func brew(_ arguments: [String], as user: String) async throws {
        record(.brew(arguments, user))
        lock.withLock {
            running += 1
            _maxRunning = max(_maxRunning, running)
        }
        defer { lock.withLock { running -= 1 } }
        // A real suspension, so two `brew`s without the lock would overlap.
        await realSleep(.milliseconds(5))
        try await wait(.brew)
        try failIfAsked(.brew)

        try lock.withLock {
            guard brewPresent, prefixOwner == user else { throw InsufficientPermissions() }
            guard brewTakes, arguments.count == 3, let verb = arguments.first, let name = arguments.last else { return }
            let key = Key(type: arguments[1] == "--cask" ? .cask : .formula, name: BrewName.short(name))
            let landed = (version: latest[key] ?? "1.0", owner: user)
            switch verb {
            case "install":
                installed[key] = landed
            case "upgrade":
                guard installed[key] != nil else { throw NotInstalled() }
                installed[key] = landed
            case "uninstall":
                guard installed.removeValue(forKey: key) != nil else { throw NotInstalled() }
            default:
                break
            }
        }
    }

    // MARK: - Private

    private func record(_ call: Call) {
        lock.withLock { _calls.append(call) }
    }

    private func wait(_ step: Step) async throws {
        while lock.withLock({ held.contains(step) }) {
            try Task.checkCancellation()
            await realSleep(.milliseconds(1))
        }
        try Task.checkCancellation()
    }

    private func failIfAsked(_ step: Step) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard let remaining = failures[step], remaining > 0 else { return false }
            failures[step] = remaining - 1
            return true
        }
        if shouldFail { throw FakeError() }
    }
}

/// Runs `body` with a fresh `HomebrewContext` over `fake`: what one launch of the daemon shares.
/// Tasks created inside inherit it. Bind a `CommandLineToolsContext` around it too (`withCLT`):
/// `ensure` reads CLT through it.
@MainActor @discardableResult
func withHomebrew<T>(
    _ fake: FakeHomebrewSystem,
    _ body: (HomebrewContext) async throws -> T
) async throws -> T {
    let context = HomebrewContext(system: fake)
    return try await HomebrewContext.$current.withValue(context) {
        try await body(context)
    }
}
