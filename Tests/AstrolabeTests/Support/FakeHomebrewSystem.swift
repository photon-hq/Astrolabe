import Foundation
@testable import Astrolabe

/// Stands in for Homebrew on the Mac. Bound through `HomebrewContext`, the way `FakeCLTSystem`
/// is bound through `CommandLineToolsContext`.
///
/// Holds whether the prefix and `brew` are there, and who owns the prefix and each `Cellar`
/// entry. Like the real `install.sh`, `runInstallScript` fails unless its user owns the prefix
/// (it would need `sudo`), then puts `brew` down owned by that user and waits while held. Records
/// every call, can fail any step on command, and can hold any async call until released.
final class FakeHomebrewSystem: HomebrewSystem, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case owners
        case createPrefix
        case reown(String)
        case runInstallScript(String)
        case addToPaths
        case brewVersion(String)
    }

    /// The calls a test can fail. The async ones can be held too.
    enum Step: Hashable, Sendable {
        case owners, createPrefix, reown, runInstallScript, addToPaths, brewVersion
    }

    struct FakeError: Error {}

    /// What `install.sh` says when it would need `sudo` for the prefix.
    struct InsufficientPermissions: Error {}

    private let lock = NSLock()
    private var _appleSilicon = true
    private var users: [String: uid_t] = ["root": 0, "ops": 501, "bob": 502, "alice": 503]
    private var prefixExists = false
    private var brewPresent = false
    private var prefixOwner = "root"
    private var cellar: [String: String] = [:]
    private var _brewRuns = true
    private var _inPaths = false
    private var reownTakes = true
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
            return Set([prefixOwner] + cellar.values).sorted()
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

    /// Homebrew installed without Astrolabe, owned by `owner`.
    func setInstalled(owner: String) {
        lock.withLock {
            (prefixExists, brewPresent, prefixOwner) = (true, true, owner)
            cellar = cellar.mapValues { _ in owner }
        }
    }

    /// `rm -rf /opt/homebrew`.
    func deleteBrew() {
        lock.withLock {
            (prefixExists, brewPresent, prefixOwner) = (false, false, "root")
            cellar = [:]
        }
    }

    /// `rm /opt/homebrew/bin/brew`: the prefix and everything else in it stay.
    func deleteBrewCommand() {
        lock.withLock { brewPresent = false }
    }

    /// `brew install <formula>` run as `owner`: another administrator, say.
    func addFormula(_ formula: String, owner: String) {
        lock.withLock { cellar[formula] = owner }
    }

    /// `reown` returns without changing the Mac.
    func reownDoesNotTake() { lock.withLock { reownTakes = false } }

    // MARK: - Inspection

    var calls: [Call] { lock.withLock { _calls } }

    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    /// Every call but the reads: what changed the Mac, or tried to.
    var changes: [Call] {
        calls.filter {
            switch $0 {
            case .owners, .brewVersion: false
            default: true
            }
        }
    }

    /// Users `install.sh` ran as, in order, including runs that failed or were cancelled.
    var installs: [String] {
        calls.compactMap { if case .runInstallScript(let user) = $0 { user } else { nil } }
    }

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
            cellar = cellar.mapValues { _ in user }
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
