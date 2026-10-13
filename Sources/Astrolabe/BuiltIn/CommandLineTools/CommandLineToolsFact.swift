extension Facts {
    /// Facts about the Xcode Command Line Tools. Reads nothing by itself.
    public var commandLineTools: CommandLineToolsFacts { CommandLineToolsFacts(facts: self) }
}

/// What's installed, and the latest Command Line Tools available to this Mac.
///
/// Both read under the same lock as `CommandLineTools`' rollout, so neither ever reports a
/// half-finished install. Each waits out an install in progress, so the timeout outlasts the
/// longest lock hold: a listing plus an install.
public struct CommandLineToolsFacts: FactNamespace {
    public let facts: Facts

    /// The installed CLT version, or `nil` when it isn't installed (no receipt, or `usr/bin/git`
    /// missing).
    ///
    /// Hash it into a resource that must redo work after a CLT update. Never gate a declaration
    /// on it: a reinstall flips it, and anything behind the `if` would be removed.
    @FactEntry(schedule: .every(.seconds(15 * 60)), timeout: .seconds(80 * 60), read: {
        try await CommandLineToolsReads.installed()
    })
    public var installed: CLTVersion?

    /// The latest CLT available to this Mac: the newest non-beta CLT Apple's catalog offers it,
    /// or the installed version when that's newer. `softwareupdate` stops listing CLT once it's
    /// current, so "available" has to count what's installed. `nil` when neither is known yet.
    ///
    /// Checks the catalog at most every 6 hours, and never on the first read after launch, so
    /// reading it never makes the app's first pass wait on Apple.
    @FactEntry(schedule: .every(.seconds(15 * 60)), timeout: .seconds(80 * 60), read: {
        try await CommandLineToolsReads.latestAvailable()
    })
    public var latestAvailable: CLTVersion?
}

/// The reads behind `CommandLineToolsFacts`, on the task-local context.
enum CommandLineToolsReads {
    static func installed() async throws -> CLTVersion? {
        let context = CommandLineToolsContext.current
        return try await CLTInstaller.locked(context) { try await context.system.installedVersion() }
    }

    /// `max(installed, newest offered)`, read together under the lock. Neither half alone is
    /// stable across an install: the listing empties once CLT is current, and the installed
    /// version moves. Their maximum is the same before an install and after it.
    static func latestAvailable() async throws -> CLTVersion? {
        let context = CommandLineToolsContext.current
        return try await CLTInstaller.locked(context) {
            let installed = try await context.system.installedVersion()
            if context.catalog.withLock({ $0.begin(at: .now) }) {
                let products = try await CLTInstaller.withTrigger(context) { try await context.system.list() }
                context.catalog.withLock { $0.checked(products, at: .now) }
            }
            return [installed, context.catalog.withLock { $0.latestOffered }].compactMap { $0 }.max()
        }
    }
}

/// When `latestAvailable` checks Apple's catalog. Pure, so it's tested without a clock.
struct CatalogCheck {
    static let interval: Duration = .seconds(6 * 3600)

    private var started = false
    private var checkedAt: ContinuousClock.Instant?
    /// The newest CLT the last check listed, or `nil` when it listed none.
    private(set) var latestOffered: CLTVersion?

    /// Whether this read checks the catalog. The first read since launch never does, so the
    /// app's first pass never waits on Apple. A check that failed is due again.
    mutating func begin(at now: ContinuousClock.Instant) -> Bool {
        guard started else {
            started = true
            return false
        }
        return checkedAt.map { now - $0 >= Self.interval } ?? true
    }

    mutating func checked(_ products: [CLTProduct], at now: ContinuousClock.Instant) {
        checkedAt = now
        latestOffered = products.map(\.version).max()
    }
}
