import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fakes

private enum LoopStep: Sendable { case healthy, drifted, throwing }

/// A leaf whose `loop()` plays back a script, then reports healthy.
private struct ScriptedLoopNode: ReconcilableNode {
    struct LoopBoom: Error {}

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [LoopStep]
        init(_ steps: [LoopStep]) { self.steps = steps }
        func next() -> LoopStep { lock.withLock { steps.isEmpty ? .healthy : steps.removeFirst() } }
    }

    let script: Script
    let displayName = "ScriptedLoop"

    func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome {
        switch script.next() {
        case .healthy: return .healthy
        case .drifted: return .drifted(reason: "scripted drift")
        case .throwing: throw LoopBoom()
        }
    }
}

/// Stands in for `Task.sleep`: records each requested duration and returns at once,
/// so the loop runs without waiting real time. The `limit`-th sleep parks until
/// the loop is cancelled, freezing the recording for the test to read.
private final class SleepRecorder: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var durations: [Duration] = []
    private let reachedLimit: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init(limit: Int) {
        self.limit = limit
        (reachedLimit, signal) = AsyncStream<Void>.makeStream()
    }

    func sleep(_ duration: Duration) async throws {
        let count = lock.withLock {
            durations.append(duration)
            return durations.count
        }
        guard count >= limit else { return }
        signal.finish()
        try await Task.sleep(for: .seconds(3600))  // until `stop` cancels the loop
    }

    /// Waits for `limit` sleeps, then returns them in order.
    func recorded() async -> [Duration] {
        for await _ in reachedLimit {}
        return lock.withLock { durations }
    }
}

private final class DriftLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(reason: String?, consecutive: Int)] = []
    var entries: [(reason: String?, consecutive: Int)] { lock.withLock { _entries } }
    func append(_ reason: String?, _ consecutive: Int) { lock.withLock { _entries.append((reason, consecutive)) } }
}

/// Runs one identity's drift loop over `steps` until it has requested `sleeps`
/// sleeps (the initial settle delay first). `onDrift` records its arguments and,
/// standing in for the remediation's `onComplete`, clears the busy latch so the
/// next check runs.
private func runLoop(
    _ steps: [LoopStep],
    tickInterval: Duration,
    sleeps: Int,
    retryPolicy: RetryPolicy = .exponential(),
    randomUnit: Double = 0.5
) async -> (sleeps: [Duration], drifts: [(reason: String?, consecutive: Int)]) {
    let recorder = SleepRecorder(limit: sleeps)
    let supervisor = LoopSupervisor(sleep: { try await recorder.sleep($0) }, random: { randomUnit })
    let drifts = DriftLog()
    let identity = NodeIdentity([.named("scripted-loop")])
    let node = TreeNode(identity: identity, kind: .leaf(ScriptedLoopNode(script: .init(steps))))

    await supervisor.refresh(
        treeNode: node,
        tickInterval: tickInterval,
        retryPolicy: retryPolicy,
        payloadStore: PayloadStore(),
        callbacksProvider: { nil },
        onDrift: { _, reason, consecutive, generation in
            drifts.append(reason, consecutive)
            await supervisor.clearBusy(identity, generation: generation)
        }
    )
    let recorded = await recorder.recorded()
    await supervisor.stop(identity: identity)
    return (recorded, drifts.entries)
}

// MARK: - Backoff

@Test(.timeLimit(.minutes(1)))
func repeatedDriftDoublesTheIntervalUpToTheCap() async {
    let run = await runLoop(Array(repeating: .drifted, count: 8), tickInterval: .seconds(15), sleeps: 9)

    // Settle delay, then 1×, 2×, 4×, … after each drift, capped at 15 min.
    #expect(run.sleeps == [15, 15, 30, 60, 120, 240, 480, 900, 900].map { Duration.seconds($0) })
    #expect(run.drifts.map(\.consecutive) == Array(1...8))
}

@Test(.timeLimit(.minutes(1)))
func healthyOutcomeResetsTheBackoff() async {
    let run = await runLoop(
        [.drifted, .drifted, .throwing, .healthy, .drifted],
        tickInterval: .seconds(15),
        sleeps: 6
    )

    #expect(run.sleeps == [15, 15, 30, 60, 15, 15].map { Duration.seconds($0) })
    // A thrown `loop` counts as a drift; `.healthy` starts the count over.
    #expect(run.drifts.map(\.consecutive) == [1, 2, 3, 1])
    #expect(run.drifts.map(\.reason)[2]?.hasPrefix("loop threw") == true)
}

@Test(.timeLimit(.minutes(1)))
func tickIntervalAboveTheCapIsNotShrunk() async {
    let run = await runLoop(Array(repeating: .drifted, count: 3), tickInterval: .seconds(3600), sleeps: 4)

    #expect(run.sleeps == Array(repeating: .seconds(3600), count: 4))
    #expect(run.drifts.map(\.consecutive) == [1, 2, 3])
}

@Test func driftBackoffDoesNotOverflowForLargeCounts() {
    let cap = Duration.seconds(900)
    let policy = RetryPolicy.exponential()
    #expect(policy.delay(tickInterval: .seconds(15), consecutiveDrifts: 0, random: { 0 }) == .seconds(15))
    #expect(policy.delay(tickInterval: .seconds(15), consecutiveDrifts: .max, random: { 0 }) == cap)
    #expect(policy.delay(tickInterval: .nanoseconds(1), consecutiveDrifts: .max, random: { 0 }) == cap)
    #expect(policy.delay(tickInterval: .seconds(899), consecutiveDrifts: 2, random: { 0 }) == cap)
}

@Test(.timeLimit(.minutes(1)))
func constantPolicyKeepsRetryingAtTheLoopInterval() async {
    let run = await runLoop(
        Array(repeating: .drifted, count: 4), tickInterval: .seconds(15), sleeps: 5,
        retryPolicy: .constant
    )

    #expect(run.sleeps == Array(repeating: .seconds(15), count: 5))
    #expect(run.drifts.map(\.consecutive) == [1, 2, 3, 4])
}

@Test(.timeLimit(.minutes(1)))
func exponentialPolicyUsesTheConfiguredCap() async {
    let run = await runLoop(
        Array(repeating: .drifted, count: 4), tickInterval: .seconds(15), sleeps: 5,
        retryPolicy: .exponential(maxDelay: .seconds(45))
    )

    #expect(run.sleeps == [15, 15, 30, 45, 45].map { Duration.seconds($0) })
}

@Test(.timeLimit(.minutes(1)))
func exponentialPolicyUsesInjectedJitter() async {
    let run = await runLoop(
        Array(repeating: .drifted, count: 4), tickInterval: .seconds(15), sleeps: 5,
        retryPolicy: .exponential(maxDelay: .seconds(120), jitter: .equal)
    )

    #expect(run.sleeps == [15.0, 15, 22.5, 45, 90].map { Duration.seconds($0) })
}

@Test(.timeLimit(.minutes(1)))
func refreshChangesPolicyWithoutResettingDriftHistory() async {
    let recorder = SleepRecorder(limit: 5)
    let supervisor = LoopSupervisor(sleep: { try await recorder.sleep($0) })
    let drifts = DriftLog()
    let identity = NodeIdentity([.named("policy-refresh")])
    let node = TreeNode(identity: identity, kind: .leaf(ScriptedLoopNode(script: .init(Array(repeating: .drifted, count: 4)))))

    await supervisor.refresh(
        treeNode: node,
        tickInterval: .seconds(15),
        payloadStore: PayloadStore(),
        callbacksProvider: { nil },
        onDrift: { _, reason, consecutive, generation in
            drifts.append(reason, consecutive)
            if consecutive == 2 {
                await supervisor.refresh(
                    treeNode: node,
                    tickInterval: .seconds(20),
                    retryPolicy: .constant,
                    payloadStore: PayloadStore(),
                    callbacksProvider: { nil },
                    onDrift: { _, _, _, _ in }
                )
            }
            await supervisor.clearBusy(identity, generation: generation)
        }
    )

    let sleeps = await recorder.recorded()
    await supervisor.stop(identity: identity)?.value
    #expect(sleeps == [15, 15, 20, 20, 20].map { Duration.seconds($0) })
    #expect(drifts.entries.map(\.consecutive) == [1, 2, 3, 4])
}

private actor SteppedSleep {
    nonisolated let requests: AsyncStream<Duration>
    private let signal: AsyncStream<Duration>.Continuation
    private var waiting: CheckedContinuation<Void, Never>?

    init() {
        (requests, signal) = AsyncStream<Duration>.makeStream()
    }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            waiting = continuation
            signal.yield(duration)
        }
    }

    func advance() {
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }
}

private actor SuspendedLoop {
    nonisolated let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var waiting: CheckedContinuation<Void, Never>?

    init() {
        (started, signal) = AsyncStream<Void>.makeStream()
    }

    func run() async -> LoopOutcome {
        await withCheckedContinuation { continuation in
            waiting = continuation
            signal.finish()
        }
        return .drifted(reason: "stale")
    }

    func finish() {
        waiting?.resume()
        waiting = nil
    }
}

private struct SuspendedLoopNode: ReconcilableNode {
    let gate: SuspendedLoop
    let displayName = "SuspendedLoop"

    func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome {
        await gate.run()
    }
}

@Test(.timeLimit(.minutes(1)))
func replacedLoopCannotRecordALateDrift() async {
    let sleep = SteppedSleep()
    var requests = sleep.requests.makeAsyncIterator()
    let gate = SuspendedLoop()
    let supervisor = LoopSupervisor(sleep: { await sleep.sleep($0) })
    let drifts = DriftLog()
    let identity = NodeIdentity([.named("replaced-loop")])

    await supervisor.refresh(
        treeNode: TreeNode(identity: identity, kind: .leaf(SuspendedLoopNode(gate: gate))),
        tickInterval: .seconds(15),
        payloadStore: PayloadStore(),
        callbacksProvider: { nil },
        onDrift: { _, reason, consecutive, generation in
            drifts.append(reason, consecutive)
            await supervisor.clearBusy(identity, generation: generation)
        }
    )
    #expect(await requests.next() == .seconds(15))
    await sleep.advance()
    for await _ in gate.started {}
    let oldTask = await supervisor.stop(identity: identity)

    await supervisor.refresh(
        treeNode: TreeNode(identity: identity, kind: .leaf(ScriptedLoopNode(script: .init([.drifted])))),
        tickInterval: .seconds(15),
        payloadStore: PayloadStore(),
        callbacksProvider: { nil },
        onDrift: { _, reason, consecutive, generation in
            drifts.append(reason, consecutive)
            await supervisor.clearBusy(identity, generation: generation)
        }
    )
    #expect(await requests.next() == .seconds(15))
    await gate.finish()
    await oldTask?.value
    #expect(drifts.entries.isEmpty)

    await sleep.advance()
    #expect(await requests.next() == .seconds(15))
    #expect(drifts.entries.map(\.consecutive) == [1])
    let newTask = await supervisor.stop(identity: identity)
    await sleep.advance()
    await newTask?.value
}

@Test(.timeLimit(.minutes(1)))
func oldRemediationCannotClearAReplacementLoopsBusyState() async throws {
    let sleep = SteppedSleep()
    var requests = sleep.requests.makeAsyncIterator()
    let supervisor = LoopSupervisor(sleep: { await sleep.sleep($0) })
    let (generations, signal) = AsyncStream<UUID>.makeStream()
    var recordedGenerations = generations.makeAsyncIterator()
    let identity = NodeIdentity([.named("replaced-remediation")])
    let node = TreeNode(identity: identity, kind: .leaf(ScriptedLoopNode(script: .init([.drifted, .drifted, .drifted]))))

    await supervisor.refresh(
        treeNode: node, tickInterval: .seconds(15), payloadStore: PayloadStore(),
        callbacksProvider: { nil }, onDrift: { _, _, _, generation in signal.yield(generation) }
    )
    #expect(await requests.next() == .seconds(15))
    await sleep.advance()
    #expect(await requests.next() == .seconds(15))
    let oldGeneration = try #require(await recordedGenerations.next())
    let oldTask = await supervisor.stop(identity: identity)
    await sleep.advance()
    await oldTask?.value

    await supervisor.refresh(
        treeNode: node, tickInterval: .seconds(15), payloadStore: PayloadStore(),
        callbacksProvider: { nil }, onDrift: { _, _, _, generation in signal.yield(generation) }
    )
    #expect(await requests.next() == .seconds(15))
    await sleep.advance()
    #expect(await requests.next() == .seconds(15))
    let newGeneration = try #require(await recordedGenerations.next())
    #expect(newGeneration != oldGeneration)

    await supervisor.clearBusy(identity, generation: oldGeneration)
    await sleep.advance()
    #expect(await requests.next() == .seconds(15))

    await supervisor.clearBusy(identity, generation: newGeneration)
    await sleep.advance()
    #expect(await requests.next() == .seconds(30))
    #expect(await recordedGenerations.next() == newGeneration)
    let newTask = await supervisor.stop(identity: identity)
    await sleep.advance()
    await newTask?.value
    signal.finish()
}
