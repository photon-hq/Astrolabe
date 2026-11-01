import Foundation
@testable import Astrolabe

/// Stands in for Command Line Tools on the Mac. Bound through `CommandLineToolsContext`, so the
/// engine's fact loops and operations reach it the way `FakeResource` reaches `FakeMachine`.
///
/// Holds the receipt, whether `usr/bin/git` is there, and Apple's catalog. Like softwareupdate,
/// `list` offers only CLT newer than the receipt, and only while the trigger file is in place.
/// `install` writes the receipt first, then waits while held: a read that sees the new version
/// then sees a half-finished install. Records every call, can fail `installedVersion`, `list`
/// and `install` on command, and can hold any async call until released.
final class FakeCLTSystem: CommandLineToolsSystem, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case installedVersion
        case forgetStaleReceipts
        case placeTrigger
        case removeTrigger
        case list
        case install(CLTVersion)
        case ensureSelected
    }

    /// The async calls a test can hold or fail.
    enum Step: Hashable, Sendable {
        case installedVersion, list, install, ensureSelected
    }

    struct FakeError: Error {}

    private let lock = NSLock()
    private var receipt: CLTVersion?
    private var hasGit: Bool
    private var _catalog: [CLTVersion]
    private var _triggerPlaced = false
    private var _calls: [Call] = []
    private var failures: [Step: Int] = [:]
    private var held: Set<Step> = []
    private var installTakes = true

    /// A Mac with `installed` on it (receipt and files), and Apple offering `catalog`.
    init(installed: CLTVersion? = nil, catalog: [CLTVersion] = []) {
        receipt = installed
        hasGit = installed != nil
        _catalog = catalog
    }

    // MARK: - The Mac

    /// What `installedVersion` reports: the receipt, when the files are there too.
    var installed: CLTVersion? { lock.withLock { hasGit ? receipt : nil } }

    /// CLT installed or updated without Astrolabe.
    func setInstalled(_ version: CLTVersion) { lock.withLock { (receipt, hasGit) = (version, true) } }

    /// `rm -rf /Library/Developer/CommandLineTools`: the receipt stays behind.
    func deleteFiles() { lock.withLock { hasGit = false } }

    /// What Apple offers this macOS, betas aside.
    var catalog: [CLTVersion] {
        get { lock.withLock { _catalog } }
        set { lock.withLock { _catalog = newValue } }
    }

    var triggerPlaced: Bool { lock.withLock { _triggerPlaced } }

    // MARK: - Inspection

    var calls: [Call] { lock.withLock { _calls } }

    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    /// Versions passed to `install`, in order, including ones that failed or were cancelled.
    var installs: [CLTVersion] {
        calls.compactMap { if case .install(let version) = $0 { version } else { nil } }
    }

    // MARK: - Control

    /// The next `times` calls of `step` throw `FakeError`.
    func fail(_ step: Step, times: Int = 1) { lock.withLock { failures[step, default: 0] += times } }

    /// Holds every call of `step` until `release(step)`. A held call still ends early with
    /// `CancellationError` when cancelled.
    func hold(_ step: Step) { _ = lock.withLock { held.insert(step) } }
    func release(_ step: Step) { _ = lock.withLock { held.remove(step) } }

    /// `install` returns without changing the Mac.
    func installDoesNotTake() { lock.withLock { installTakes = false } }

    // MARK: - CommandLineToolsSystem

    func installedVersion() async throws -> CLTVersion? {
        record(.installedVersion)
        try await wait(.installedVersion)
        try failIfAsked(.installedVersion)
        return installed
    }

    func forgetStaleReceipts() async throws {
        record(.forgetStaleReceipts)
        lock.withLock {
            if !hasGit { receipt = nil }
        }
    }

    func placeTrigger() throws {
        record(.placeTrigger)
        lock.withLock { _triggerPlaced = true }
    }

    func removeTrigger() {
        record(.removeTrigger)
        lock.withLock { _triggerPlaced = false }
    }

    func list() async throws -> [CLTProduct] {
        record(.list)
        try await wait(.list)
        try failIfAsked(.list)
        return lock.withLock {
            guard _triggerPlaced else { return [] }
            return _catalog
                .filter { version in receipt.map { version > $0 } ?? true }
                .map { CLTProduct(label: "Command Line Tools for Xcode \($0.major).\($0.minor)-\($0)", version: $0) }
        }
    }

    func install(_ product: CLTProduct) async throws {
        record(.install(product.version))
        try failIfAsked(.install)
        lock.withLock {
            if installTakes { (receipt, hasGit) = (product.version, true) }
        }
        try await wait(.install)
    }

    func ensureSelected() async throws {
        record(.ensureSelected)
        try await wait(.ensureSelected)
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

/// Runs `body` with a fresh `CommandLineToolsContext` over `fake`: what one launch of the daemon
/// shares. Tasks created inside inherit it.
@MainActor @discardableResult
func withCLT<T>(
    _ fake: FakeCLTSystem,
    _ body: (CommandLineToolsContext) async throws -> T
) async throws -> T {
    let context = CommandLineToolsContext(system: fake)
    return try await CommandLineToolsContext.$current.withValue(context) {
        try await body(context)
    }
}
