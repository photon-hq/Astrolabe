import Semaphore
import Synchronization

/// The Mac Command Line Tools acts on, plus the state the facts and the resource share.
///
/// Task-local, so tests bind their own: the engine's run task, its fact loops and its operations
/// all inherit it.
final class CommandLineToolsContext: Sendable {
    @TaskLocal static var current = CommandLineToolsContext(system: SoftwareUpdateCLT())

    let system: any CommandLineToolsSystem
    /// Serializes everything CLT does: both facts' reads and the whole of a rollout's install.
    /// Homebrew's rollout waits on it too, through `CommandLineToolsReads.installed()`.
    let lock = AsyncSemaphore(value: 1)
    /// An install holds the lock and has started changing the Mac. `ensure` then waits for it
    /// rather than trusting a receipt that can show before all of CLT's files are there.
    let installing = Mutex(false)
    /// `latestAvailable`'s last catalog check. In memory: each launch starts over.
    let catalog = Mutex(CatalogCheck())

    init(system: any CommandLineToolsSystem) {
        self.system = system
    }
}

/// Installs Command Line Tools through `softwareupdate`, headlessly.
enum CLTInstaller {
    /// Makes sure CLT is installed at `minimum` or newer; with `nil`, installs the newest Apple
    /// offers if CLT is missing.
    ///
    /// Checks the Mac first, without the lock: when CLT is already there, it never waits on a
    /// catalog listing. Everything that changes the Mac happens under the lock.
    static func ensure(minimum: CLTVersion?) async throws {
        let context = CommandLineToolsContext.current
        let system = context.system
        // The flag is read after the version: a version read before an install started is whole.
        if satisfies(try await system.installedVersion(), minimum), !context.installing.withLock({ $0 }) {
            try await system.ensureSelected()
            return
        }
        try await locked(context) {
            if !satisfies(try await system.installedVersion(), minimum) {
                context.installing.withLock { $0 = true }
                defer { context.installing.withLock { $0 = false } }
                try await system.forgetStaleReceipts()
                let picked = try await withTrigger(context) {
                    let offered = try await system.list()
                    guard let product = offered
                        .filter({ product in minimum.map { product.version >= $0 } ?? true })
                        .max(by: { $0.version < $1.version })
                    else { throw CLTError.notOffered(minimum: minimum, offered: offered.map(\.version)) }
                    try Task.checkCancellation()
                    try await system.install(product)
                    return product
                }
                let expected = minimum ?? picked.version
                let installed = try await system.installedVersion()
                guard satisfies(installed, expected) else {
                    throw CLTError.didNotTake(expected: expected, installed: installed)
                }
            }
            try await system.ensureSelected()
        }
    }

    /// Runs `body` holding the context's lock. Waiting is cancellable.
    static func locked<T>(_ context: CommandLineToolsContext, _ body: () async throws -> T) async throws -> T {
        try await context.lock.waitUnlessCancelled()
        defer { context.lock.signal() }
        return try await body()
    }

    /// Runs `body` with the trigger file in place. `softwareupdate` lists and installs CLT only
    /// while it exists, and a leftover file shows CLT in System Settings. Call while `locked`.
    static func withTrigger<T>(_ context: CommandLineToolsContext, _ body: () async throws -> T) async throws -> T {
        try context.system.placeTrigger()
        defer { context.system.removeTrigger() }
        return try await body()
    }

    /// `installed` is there, and at `minimum` or newer when there is one.
    static func satisfies(_ installed: CLTVersion?, _ minimum: CLTVersion?) -> Bool {
        guard let installed else { return false }
        return minimum.map { installed >= $0 } ?? true
    }
}

enum CLTError: Error, Sendable, CustomStringConvertible {
    /// The catalog offers no CLT at `minimum` or newer. Often: offline, or an MDM deferral.
    case notOffered(minimum: CLTVersion?, offered: [CLTVersion])
    /// `softwareupdate` succeeded but the receipt or `usr/bin/git` doesn't show it.
    case didNotTake(expected: CLTVersion, installed: CLTVersion?)
    /// `pkgutil --pkg-info` succeeded without a version line Astrolabe can read.
    case unreadableReceipt(output: String)

    var description: String {
        switch self {
        case .notOffered(let minimum, let offered):
            "softwareupdate offers no Command Line Tools\(minimum.map { " at \($0) or newer" } ?? "")"
                + (offered.isEmpty ? "" : " (offered: \(offered.map(\.description).joined(separator: ", ")))")
        case .didNotTake(let expected, let installed):
            "softwareupdate installed Command Line Tools, but the Mac shows \(installed?.description ?? "none"), not \(expected) or newer"
        case .unreadableReceipt(let output):
            "can't read the Command Line Tools receipt: \(output)"
        }
    }
}
