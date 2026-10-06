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
    sleeps: Int
) async -> (sleeps: [Duration], drifts: [(reason: String?, consecutive: Int)]) {
    let recorder = SleepRecorder(limit: sleeps)
    let supervisor = LoopSupervisor(sleep: { try await recorder.sleep($0) })
    let drifts = DriftLog()
    let identity = NodeIdentity([.named("scripted-loop")])
    let node = TreeNode(identity: identity, kind: .leaf(ScriptedLoopNode(script: .init(steps))))

    await supervisor.refresh(
        treeNode: node,
        tickInterval: tickInterval,
        payloadStore: PayloadStore(),
        callbacksProvider: { nil },
        onDrift: { _, reason, consecutive in
            drifts.append(reason, consecutive)
            await supervisor.clearBusy(identity)
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
    let cap = LoopSupervisor.maxDriftBackoff
    #expect(LoopSupervisor.driftBackoff(tickInterval: .seconds(15), consecutiveDrifts: 0) == .seconds(15))
    #expect(LoopSupervisor.driftBackoff(tickInterval: .seconds(15), consecutiveDrifts: .max) == cap)
    #expect(LoopSupervisor.driftBackoff(tickInterval: .nanoseconds(1), consecutiveDrifts: .max) == cap)
    #expect(LoopSupervisor.driftBackoff(tickInterval: .seconds(899), consecutiveDrifts: 2) == cap)
}
