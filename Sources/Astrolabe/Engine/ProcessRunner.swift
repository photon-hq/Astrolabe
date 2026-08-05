import Foundation
import Subprocess
import System

/// Shared process execution, backed by [swift-subprocess](https://github.com/swiftlang/swift-subprocess).
///
/// This is the only place in Astrolabe that imports `Subprocess`, and the only place that
/// spawns a child process. Everything else goes through `run`, `capture`, `stream`, or
/// `resolve`.
///
/// Three things it guarantees that hand-rolled `Foundation.Process` code did not:
///
/// - **Both streams drain concurrently with the child.** The old idiom waited on the process
///   and *then* read the pipe, which deadlocks permanently once a child writes more than the
///   ~64 KB pipe buffer. That failure mode is gone by construction.
/// - **Every spawn is bounded and cancellable.** A timeout, or cancellation of the enclosing
///   task, escalates SIGTERM → SIGKILL across the child's whole process group, so nothing is
///   orphaned.
/// - **stdout and stderr stay separate**, with `Result.combined` for the parsers that need
///   the old merged view.
///
/// > Note: `ProcessRunner` is internal. Consumer packages that need to shell out should
/// > depend on swift-subprocess directly.
enum ProcessRunner {

    // MARK: - Result

    /// The outcome of a child process: how it ended, and what it wrote.
    struct Result: Sendable {
        let path: String
        let arguments: [String]
        let terminationStatus: TerminationStatus
        let standardOutput: String
        let standardError: String

        var isSuccess: Bool { terminationStatus.isSuccess }

        /// The POSIX shell's view of the exit status: `.exited(c)` → `c`,
        /// `.signaled(s)` → `128 + s`.
        var exitCode: Int32 {
            switch terminationStatus {
            case .exited(let code): code
            case .signaled(let signal): 128 + signal
            }
        }

        /// Standard output followed by standard error.
        ///
        /// - Important: This is a *concatenation*, not the true interleaving the old
        ///   shared-`Pipe` produced. Every current consumer either substring-matches the whole
        ///   text or parses it line-wise, so cross-stream ordering does not matter to them —
        ///   but a parser that depends on real interleaving must not use this.
        var combined: String {
            switch (standardOutput.isEmpty, standardError.isEmpty) {
            case (true, _): standardError
            case (_, true): standardOutput
            default: standardOutput.hasSuffix("\n")
                ? standardOutput + standardError
                : standardOutput + "\n" + standardError
            }
        }

        /// The error to throw when a non-zero exit is a failure.
        var failure: ReconcileError {
            .processFailed(path: path, arguments: arguments, output: combined)
        }
    }

    // MARK: - Timeouts

    /// How long a child gets before it is torn down.
    ///
    /// swift-subprocess has no timeout parameter; these feed the `withTimeout` race below.
    /// Pass `nil` for a genuinely unbounded wait — `osascript` presenting a dialog blocks on
    /// a human, so bounding it would be a bug.
    enum Timeout {
        /// Reads that should return immediately: `launchctl print`, `brew list`, `scutil --get`.
        static let probe: Duration = .seconds(30)
        /// Writes to system state: `launchctl bootstrap`, `scutil --set`, `pkgutil --forget`.
        static let mutation: Duration = .seconds(120)
        /// Package installs, which legitimately take a long time.
        static let install: Duration = .seconds(3600)
    }

    /// On cancellation or timeout: SIGTERM the whole process group, then SIGKILL.
    ///
    /// Targeting the group matters because the things Astrolabe runs spawn children of their
    /// own — `brew` shells out constantly, and `installer` runs package scripts.
    ///
    /// - Important: This is only correct alongside `processGroupID = 0` below. A
    ///   group-targeted signal is `kill(-pid, …)`, which addresses the group whose ID equals
    ///   the child's PID. Without an explicit group the child inherits *ours*, so that group
    ///   does not exist and the teardown silently signals nothing — the child then runs to
    ///   completion and the timeout never actually bites. Worse, as swift-subprocess's own
    ///   docs warn, an inherited group means the targeted group is the caller's: a `brew
    ///   install` timeout could deliver SIGTERM to the Astrolabe daemon itself.
    private static let teardown: [TeardownStep] = [
        .send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .seconds(5))
    ]

    /// Default cap on collected output. Chatty children should use `stream` instead of
    /// raising this — see `stream(_:arguments:)`.
    static let defaultLimit = 256 * 1024

    // MARK: - Running

    /// Runs a process and throws `ReconcileError.processFailed` if it exits non-zero.
    @discardableResult
    static func run(
        _ path: String,
        arguments: [String] = [],
        as user: UserContext? = nil,
        timeout: Duration? = Timeout.mutation,
        limit: Int = defaultLimit
    ) async throws -> Result {
        let result = try await capture(
            path, arguments: arguments, as: user, timeout: timeout, limit: limit
        )
        guard result.isSuccess else { throw result.failure }
        return result
    }

    /// Runs a process and returns its outcome without judging it.
    ///
    /// Use this for probes that branch on the exit status — `launchctl print`, `brew list`,
    /// `xcode-select -p`. Still throws if the process could not be spawned or timed out.
    static func capture(
        _ path: String,
        arguments: [String] = [],
        as user: UserContext? = nil,
        timeout: Duration? = Timeout.probe,
        limit: Int = defaultLimit
    ) async throws -> Result {
        let options = platformOptions(for: user)
        let env = user?.environment() ?? .inherit

        return try await withTimeout(timeout, path: path, arguments: arguments) {
            let outcome = try await Subprocess.run(
                .path(FilePath(path)),
                arguments: Arguments(arguments),
                environment: env,
                platformOptions: options,
                output: .string(limit: limit),
                error: .string(limit: limit)
            )
            // A cancelled run comes back as a normal result whose child was signalled by the
            // teardown. Report that as cancellation rather than as a process failure —
            // `GitHubPackage.install` and friends branch on `CancellationError`.
            try Task.checkCancellation()
            return Result(
                path: path,
                arguments: arguments,
                terminationStatus: outcome.terminationStatus,
                standardOutput: outcome.standardOutput,
                standardError: outcome.standardError
            )
        }
    }

    /// Runs a process, streaming both streams as they arrive and keeping a bounded tail.
    ///
    /// This is the right call for anything chatty — `brew install`, `installer -pkg`,
    /// `softwareupdate -i --verbose`. Collecting those with `capture` would trade the old
    /// pipe-buffer deadlock for a `SubprocessError.outputLimitExceeded`; streaming has
    /// neither failure mode, and `onLine` lets a ten-minute install report progress instead
    /// of going silent.
    ///
    /// Throws `ReconcileError.processFailed` on a non-zero exit, with the tail as the output.
    @discardableResult
    static func stream(
        _ path: String,
        arguments: [String] = [],
        as user: UserContext? = nil,
        timeout: Duration? = Timeout.install,
        tailLines: Int = 200,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let options = platformOptions(for: user)
        let env = user?.environment() ?? .inherit
        let tail = TailBuffer(limit: tailLines)

        let result = try await withTimeout(
            timeout, path: path, arguments: arguments,
            partialOutput: { tail.snapshot().joined(separator: "\n") }
        ) {
            let outcome = try await Subprocess.run(
                .path(FilePath(path)),
                arguments: Arguments(arguments),
                environment: env,
                platformOptions: options,
                input: .none,
                output: .sequence,
                error: .sequence
            ) { execution in
                // Both streams must be drained concurrently: a child blocked writing to a
                // pipe nobody is reading is exactly the deadlock this migration removes.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await drain(execution.standardOutput, into: tail, isError: false, onLine: onLine)
                    }
                    group.addTask {
                        await drain(execution.standardError, into: tail, isError: true, onLine: onLine)
                    }
                }
            }

            try Task.checkCancellation()
            return Result(
                path: path,
                arguments: arguments,
                terminationStatus: outcome.terminationStatus,
                standardOutput: tail.snapshot(.standardOutput).joined(separator: "\n"),
                standardError: tail.snapshot(.standardError).joined(separator: "\n")
            )
        }

        guard result.isSuccess else { throw result.failure }
        return result
    }

    /// Returns the absolute path of `name` on `PATH`, or `nil` if it is not there.
    ///
    /// This walks `PATH` on the filesystem — no `/usr/bin/which` process is spawned.
    static func resolve(_ name: String) async -> String? {
        do {
            return try await Executable.name(name).resolveExecutablePath(in: .inherit).string
        } catch {
            return nil
        }
    }

    /// Returns `true` if a command is found in `$PATH`.
    static func commandExists(_ name: String) async -> Bool {
        await resolve(name) != nil
    }

    // MARK: - Private

    private static func platformOptions(for user: UserContext?) -> PlatformOptions {
        var options = user?.platformOptions ?? PlatformOptions()
        // `posix_spawnattr_setpgroup(attr, 0)`: the child becomes the leader of a new process
        // group whose ID is its own PID. That makes the group-targeted teardown above address
        // exactly this child and its descendants — never ours. Load-bearing; see `teardown`.
        options.processGroupID = 0
        options.teardownSequence = teardown
        return options
    }

    private static func drain(
        _ stream: SubprocessOutputSequence,
        into tail: TailBuffer,
        isError: Bool,
        onLine: (@Sendable (String) -> Void)?
    ) async {
        do {
            for try await line in stream.strings() {
                tail.append(line, isError: isError)
                onLine?(line)
            }
        } catch {
            // A read failure must not fail the run outright — the exit status is the
            // authority on whether the command worked.
            //
            // `strings()` throws if a single line exceeds its 128 KB buffering policy, and
            // the sequence is single-pass, so this stream stops being drained. A child that
            // then filled the pipe would stall — but only until the timeout tears it down,
            // rather than hanging forever as the old drain-after-wait code did. The children
            // Astrolabe runs all emit line or carriage-return breaks (`strings()` splits on
            // both), so this is a bounded fallback, not an expected path.
            tail.append("[astrolabe] output stream ended early: \(error)", isError: isError)
        }
    }

    /// Races `operation` against a sleep, tearing the child down if the sleep wins.
    ///
    /// A timeout surfaces as `ReconcileError.processFailed` rather than a new error case, so
    /// every existing consumer — telemetry attributes, `isTransientLaunchctlError`, the
    /// reconcile error path — keeps working unchanged.
    private static func withTimeout(
        _ timeout: Duration?,
        path: String,
        arguments: [String],
        partialOutput: (@Sendable () -> String)? = nil,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard let timeout else { return try await operation() }

        do {
            return try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw TimedOut()
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch is TimedOut {
            // Leaving the group above cancelled the child, which ran the teardown sequence.
            var output = "[astrolabe] timed out after \(timeout)"
            if let partial = partialOutput?(), !partial.isEmpty {
                output += "\n" + partial
            }
            throw ReconcileError.processFailed(path: path, arguments: arguments, output: output)
        }
    }

    private struct TimedOut: Error {}

    /// A fixed-size ring of the most recent output lines, safe for two concurrent drainers.
    private final class TailBuffer: @unchecked Sendable {
        enum Stream { case standardOutput, standardError }

        private let lock = NSLock()
        private let limit: Int
        private var out: [String] = []
        private var err: [String] = []

        init(limit: Int) { self.limit = max(1, limit) }

        func append(_ line: String, isError: Bool) {
            lock.withLock {
                if isError {
                    err.append(line)
                    if err.count > limit { err.removeFirst(err.count - limit) }
                } else {
                    out.append(line)
                    if out.count > limit { out.removeFirst(out.count - limit) }
                }
            }
        }

        func snapshot(_ stream: Stream) -> [String] {
            lock.withLock { stream == .standardOutput ? out : err }
        }

        /// Both streams, for the partial-output-on-timeout path.
        func snapshot() -> [String] {
            lock.withLock { out + err }
        }
    }
}
