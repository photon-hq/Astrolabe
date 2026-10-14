import Semaphore
import Synchronization

/// The Mac Homebrew acts on, plus the state its fact and its resource share.
///
/// Task-local, so tests bind their own: the engine's run task, its fact loops and its operations
/// all inherit it.
final class HomebrewContext: Sendable {
    @TaskLocal static var current = HomebrewContext(system: InstallScriptHomebrew())

    let system: any HomebrewSystem
    /// Serializes the `owners` fact's reads and the whole of a rollout's install or re-own, so a
    /// read never sees an install half done. `Brew` (ENG-3738) takes it too, through `ensure`,
    /// so two rollouts never install at once.
    let lock = AsyncSemaphore(value: 1)
    /// A rollout holds the lock and has started changing the Mac. `ensure` then waits for it
    /// rather than trusting owners that can look right before the install is done.
    let installing = Mutex(false)

    init(system: any HomebrewSystem) {
        self.system = system
    }
}

/// Installs Homebrew with its own `install.sh`, headlessly, and keeps it owned by one account.
enum HomebrewInstaller {
    /// Makes sure Homebrew is installed at `/opt/homebrew`, owned by `owner` alone, and that
    /// `brew` runs as `owner`.
    ///
    /// Missing: gives `owner` the prefix, then runs `install.sh` as `owner`. Owned by anyone else,
    /// or by several accounts: `chown`s the prefix back to `owner`, with nothing downloaded.
    /// Never installs Command Line Tools: the app declares `CommandLineTools()`.
    ///
    /// Checks the Mac first, without the lock: when Homebrew is healthy, it changes nothing and
    /// never waits. Everything that changes the Mac happens under the lock.
    static func ensure(owner: String) async throws {
        let context = HomebrewContext.current
        let system = context.system
        guard system.isAppleSilicon() else { throw HomebrewError.unsupportedArchitecture }
        guard let uid = system.uid(of: owner) else { throw HomebrewError.unknownOwner(owner) }
        guard uid != 0 else { throw HomebrewError.ownerIsRoot(owner) }

        // The flag is read after the check: a check made before an install started saw it whole.
        if try await isHealthy(owner: owner, system), !context.installing.withLock({ $0 }) { return }

        // A locked read: it waits out a CLT install or update in progress rather than running
        // `install.sh` against a half-replaced `git`. It releases the CLT lock before the
        // Homebrew lock is taken, so the two never nest.
        guard try await CommandLineToolsReads.installed() != nil else {
            throw HomebrewError.commandLineToolsMissing
        }

        try await locked(context) {
            if try await isHealthy(owner: owner, system) { return }  // another rollout just did it
            context.installing.withLock { $0 = true }
            defer { context.installing.withLock { $0 = false } }

            let found = try system.owners()
            if found.isEmpty {
                // Missing. `install.sh` refuses root, and as `owner` it needs `sudo` only to make
                // the prefix in root's `/opt`. So root makes it and gives it to `owner`, along
                // with anything a broken install left in it, and the script needs no `sudo`.
                try system.createPrefix()
                try await system.reown(owner)
                try Task.checkCancellation()
                try await system.runInstallScript(as: owner)
                try system.addToPaths()
            } else {
                // Owned by someone else, or by several: give it all back. A right owner whose
                // `brew` fails gets it too, for a wrong owner deeper in. Nothing is downloaded.
                let why = found == [owner] ? "brew --version fails as \(owner)" : "Homebrew is owned by \(found.joined(separator: ", "))"
                print("[Astrolabe] \(why); re-owning \(InstallScriptHomebrew.prefix) for \(owner)")
                try await system.reown(owner)
            }

            let owners = try system.owners()
            guard owners == [owner] else { throw HomebrewError.didNotTake(expected: owner, owners: owners) }
            guard try await system.brewVersion(as: owner) != nil else {
                throw HomebrewError.brewDoesNotRun(owner: owner)
            }
        }
    }

    /// `owner` alone owns Homebrew, and `brew --version` runs as `owner`.
    static func isHealthy(owner: String, _ system: any HomebrewSystem) async throws -> Bool {
        guard try system.owners() == [owner] else { return false }
        return try await system.brewVersion(as: owner) != nil
    }

    /// Runs `body` holding the context's lock. Waiting is cancellable.
    static func locked<T>(_ context: HomebrewContext, _ body: () async throws -> T) async throws -> T {
        try await context.lock.waitUnlessCancelled()
        defer { context.lock.signal() }
        return try await body()
    }
}

enum HomebrewError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Homebrew supports only Apple silicon on macOS.
    case unsupportedArchitecture
    /// `owner` names no account on this Mac.
    case unknownOwner(String)
    /// `owner` is root (uid 0), which Homebrew refuses.
    case ownerIsRoot(String)
    /// CLT isn't installed. The app declares `CommandLineTools()`; Homebrew never installs it.
    case commandLineToolsMissing
    /// Fetching `install.sh` ended with an HTTP status other than 200, or an empty script.
    case installScriptUnavailable(status: Int)
    /// The install or re-own finished, but Homebrew isn't owned by `expected` alone.
    case didNotTake(expected: String, owners: [String])
    /// `owner` owns Homebrew, but `brew --version` fails as `owner`.
    case brewDoesNotRun(owner: String)

    var description: String {
        switch self {
        case .unsupportedArchitecture:
            "Homebrew installs only on Apple silicon"
        case .unknownOwner(let owner):
            "no user named \(owner) on this Mac to own Homebrew"
        case .ownerIsRoot(let owner):
            "Homebrew refuses root as its owner (\(owner) is uid 0)"
        case .commandLineToolsMissing:
            "Command Line Tools aren't installed: declare CommandLineTools()"
        case .installScriptUnavailable(let status):
            "fetching Homebrew's install.sh returned HTTP \(status) or an empty script"
        case .didNotTake(let expected, let owners):
            "Homebrew should be owned by \(expected) alone, but is owned by \(owners.isEmpty ? "nobody (not installed)" : owners.joined(separator: ", "))"
        case .brewDoesNotRun(let owner):
            "brew --version fails as \(owner)"
        }
    }
}
