import Foundation
import Testing
@testable import Astrolabe

// MARK: - Collected output

@Test func processRunnerCapturesStandardOutput() async throws {
    let result = try await ProcessRunner.capture("/bin/echo", arguments: ["hello"])
    #expect(result.isSuccess)
    #expect(result.exitCode == 0)
    #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(result.standardError.isEmpty)
}

@Test func processRunnerSeparatesStandardErrorFromStandardOutput() async throws {
    let result = try await ProcessRunner.capture(
        "/bin/sh",
        arguments: ["-c", "echo to-stdout; echo to-stderr 1>&2"]
    )
    #expect(result.isSuccess)
    #expect(result.standardOutput.contains("to-stdout"))
    #expect(!result.standardOutput.contains("to-stderr"))
    #expect(result.standardError.contains("to-stderr"))
    // `combined` is what the parsers that relied on the old shared pipe read.
    #expect(result.combined.contains("to-stdout"))
    #expect(result.combined.contains("to-stderr"))
}

@Test func processRunnerCaptureDoesNotThrowOnNonZeroExit() async throws {
    let result = try await ProcessRunner.capture("/usr/bin/false")
    #expect(!result.isSuccess)
    #expect(result.exitCode == 1)
}

@Test func processRunnerRunThrowsProcessFailedOnNonZeroExit() async throws {
    do {
        _ = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "echo nope 1>&2; exit 3"])
        Issue.record("expected a non-zero exit to throw")
    } catch let error as ReconcileError {
        guard case .processFailed(let path, let arguments, let output) = error else {
            Issue.record("expected .processFailed, got \(error)")
            return
        }
        #expect(path == "/bin/sh")
        #expect(arguments.contains("-c"))
        // stderr must reach the error payload — `isTransientLaunchctlError` matches on it.
        #expect(output.contains("nope"))
    }
}

// MARK: - The deadlock this migration removes

/// The old idiom waited on the process and only *then* drained the pipe, so any child
/// writing past the ~64 KB pipe buffer blocked forever. Several MB must now complete.
@Test func processRunnerHandlesOutputLargerThanThePipeBuffer() async throws {
    let byteCount = 4 * 1024 * 1024
    let result = try await ProcessRunner.capture(
        "/bin/dd",
        arguments: ["if=/dev/zero", "bs=1048576", "count=4"],
        timeout: .seconds(60),
        limit: byteCount * 2
    )
    #expect(result.isSuccess)
    // /dev/zero gives NUL bytes; decoded as UTF-8 they stay one scalar each.
    #expect(result.standardOutput.utf8.count == byteCount)
    // dd reports its transfer summary on stderr, which must not be lost.
    #expect(result.standardError.contains("bytes"))
}

@Test func processRunnerStreamsLinesAsTheyArrive() async throws {
    let collected = LockedBox<[String]>([])
    let result = try await ProcessRunner.stream(
        "/bin/sh",
        arguments: ["-c", "echo one; echo two 1>&2; echo three"],
        timeout: .seconds(60)
    ) { line in
        collected.mutate { $0.append(line) }
    }

    #expect(result.isSuccess)
    #expect(Set(collected.value) == ["one", "two", "three"])
    #expect(result.standardOutput.contains("one"))
    #expect(result.standardOutput.contains("three"))
    #expect(result.standardError.contains("two"))
}

/// A child that outruns the collection limit must fail loudly rather than truncate silently.
@Test func processRunnerCaptureRejectsOutputBeyondItsLimit() async throws {
    await #expect(throws: (any Error).self) {
        try await ProcessRunner.capture(
            "/bin/dd",
            arguments: ["if=/dev/zero", "bs=1048576", "count=4"],
            timeout: .seconds(60),
            limit: 4096
        )
    }
}

// MARK: - Timeout and cancellation

@Test func processRunnerTimesOutAndReportsTheDuration() async throws {
    let start = ContinuousClock.now
    do {
        _ = try await ProcessRunner.capture(
            "/bin/sleep", arguments: ["30"], timeout: .milliseconds(500)
        )
        Issue.record("expected the timeout to throw")
    } catch let error as ReconcileError {
        guard case .processFailed(let path, _, let output) = error else {
            Issue.record("expected .processFailed, got \(error)")
            return
        }
        #expect(path == "/bin/sleep")
        #expect(output.contains("timed out"))
    }
    // Must return promptly rather than waiting out the child's full 30 seconds.
    #expect(start.duration(to: .now) < .seconds(10))
}

@Test func processRunnerCancellationTearsTheChildDown() async throws {
    let task = Task {
        try await ProcessRunner.capture("/bin/sleep", arguments: ["30"], timeout: nil)
    }
    // Give the spawn a moment to actually happen before cancelling it.
    try await Task.sleep(for: .milliseconds(200))

    let start = ContinuousClock.now
    task.cancel()
    let result = await task.result
    #expect(start.duration(to: .now) < .seconds(10))

    guard case .failure(let error) = result else {
        Issue.record("expected cancellation to surface as a failure")
        return
    }
    #expect(error is CancellationError, "expected CancellationError, got \(error)")
}

// MARK: - PATH resolution

@Test func processRunnerResolvesExecutablesOnPath() async {
    let resolved = await ProcessRunner.resolve("ls")
    #expect(resolved?.hasPrefix("/") == true)
    #expect(resolved?.hasSuffix("/ls") == true)
    #expect(await ProcessRunner.commandExists("ls"))
}

@Test func processRunnerDoesNotResolveMissingExecutables() async {
    #expect(await ProcessRunner.resolve("astrolabe-definitely-not-a-real-binary") == nil)
    #expect(await ProcessRunner.commandExists("astrolabe-definitely-not-a-real-binary") == false)
}

// MARK: - Exit status mapping

@Test func processRunnerMapsSignalTerminationToShellConvention() async throws {
    // 128 + SIGKILL(9) — the exit code a POSIX shell reports for a killed child.
    let result = try await ProcessRunner.capture("/bin/sh", arguments: ["-c", "kill -9 $$"])
    #expect(!result.isSuccess)
    #expect(result.exitCode == 128 + 9)
}

// MARK: - User context

@Test func userContextResolvesRootWithSupplementaryGroups() throws {
    let root = try #require(UserContext(username: "root"))
    #expect(root.uid == 0)
    #expect(root.name == "root")
    #expect(!root.home.isEmpty)
    // `initgroups` equivalence: root is always in wheel(0), and the list is never empty —
    // an empty list would make Subprocess skip `setgroups` and leak the parent's groups.
    #expect(!root.supplementaryGroups.isEmpty)
    #expect(root.supplementaryGroups.contains(0))
}

@Test func userContextReturnsNilForUnknownUser() {
    #expect(UserContext(username: "astrolabe-definitely-not-a-real-user") == nil)
}

@Test func userContextPrependsPathWithoutDuplicating() {
    guard let root = UserContext(username: "root") else {
        Issue.record("root must exist")
        return
    }
    #expect(root.pathPrefix == nil)
    #expect(root.prependingPath("/opt/homebrew/bin").pathPrefix == "/opt/homebrew/bin")
}

// MARK: - System probe

@Test func systemProbeServesSeedUntilRefreshed() async {
    let probe = SystemProbe(initialValue: true) { false }
    #expect(probe.current)          // seed, no spawn, never blocks
    await probe.refresh()
    #expect(!probe.current)
}

@Test func systemProbeCollapsesConcurrentRefreshes() async throws {
    let calls = LockedBox<Int>(0)
    let probe = SystemProbe(initialValue: false) {
        calls.mutate { $0 += 1 }
        try? await Task.sleep(for: .milliseconds(300))
        return true
    }

    // Without collapsing, the poll loop would stack one subprocess per tick.
    for _ in 0..<10 { probe.refreshInBackground() }
    try await Task.sleep(for: .milliseconds(600))

    #expect(calls.value == 1)
    #expect(probe.current)
}

// MARK: - Helpers

/// Minimal thread-safe box for observing values written from concurrent callbacks.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { self.stored = value }

    var value: Value { lock.withLock { stored } }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&stored) }
    }
}
