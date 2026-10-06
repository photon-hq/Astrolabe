import Foundation

/// Owns the per-identity background tasks that periodically call `node.loop(...)`
/// to detect drift between the declared state and reality.
///
/// Domain-agnostic — speaks only the `ReconcilableNode` protocol. Scheduling and
/// cancellation live here; the *check itself* lives in each node's `loop` method.
///
/// **Drift backoff.** The loop is the retry: a `.drifted` outcome (or a thrown
/// `loop`) re-enqueues `mount()`, and nothing else ever re-attempts work. A node
/// whose mount can't succeed — e.g. every `Brew` on a host where brew can't spawn
/// (ENG-3374) — would otherwise re-mount at its full cadence forever: 5,760
/// attempts a day on a 15s loop. So each identity counts its consecutive drifts,
/// `n`, and waits `tickInterval × 2^(n−1)` before its next check, capped at
/// `maxDriftBackoff` (~100 attempts a day) and never below `tickInterval`; one
/// `.healthy` outcome resets it. This stays within the constitution — the loop is
/// still the only retry, through the same pipeline, and it never gives up; it
/// just slows down for a node that keeps failing.
actor LoopSupervisor {
    /// Ceiling on the backoff for a repeatedly drifting identity. Only limits the
    /// growth — a `tickInterval` already above it is used as-is.
    static let maxDriftBackoff: Duration = .seconds(15 * 60)

    private struct Entry {
        let task: Task<Void, Never>
        var treeNode: TreeNode
        var tickInterval: Duration
        var remediationInFlight: Bool
        /// Consecutive `.drifted` outcomes; a `.healthy` one resets it.
        var consecutiveDrifts: Int
    }

    private var entries: [NodeIdentity: Entry] = [:]
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameter sleep: Waits out the interval between checks. Injectable so
    ///   tests can observe the requested intervals without waiting real time.
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Starts a drift loop for `treeNode.identity`, or refreshes the stored
    /// `TreeNode` if a loop is already running. Idempotent — safe to call on
    /// every tick. The freshest `TreeNode` is what `onDrift` receives and what
    /// the periodic `loop(_:)` call dispatches to (via `.kind`'s leaf).
    ///
    /// `callbacksProvider` is invoked freshly on every drift check because
    /// `ModifierStore` is rebuilt each tick — a captured snapshot would go stale.
    ///
    /// `onDrift` receives the drift reason and the identity's consecutive-drift
    /// count (1 on the first drift since the last `.healthy` check).
    func refresh(
        treeNode: TreeNode,
        tickInterval: Duration,
        payloadStore: PayloadStore,
        callbacksProvider: @escaping @Sendable () -> ModifierStore.Callbacks?,
        onDrift: @escaping @Sendable (TreeNode, String?, Int) async -> Void
    ) {
        let identity = treeNode.identity
        if var existing = entries[identity] {
            existing.treeNode = treeNode
            existing.tickInterval = tickInterval
            entries[identity] = existing
            return
        }
        guard case .leaf = treeNode.kind else { return }

        let sleep = self.sleep
        let task = Task { [weak self] in
            // Initial delay — let the system settle after mount completes
            // before the first verification.
            guard let initialInterval = await self?.currentInterval(identity: identity) else { return }
            try? await sleep(initialInterval)

            while !Task.isCancelled {
                guard let snapshot = await self?.snapshot(identity: identity) else { return }
                if !snapshot.busy, case .leaf(let reconcilable) = snapshot.treeNode.kind {
                    let context = ReconcileContext(
                        payloadStore: payloadStore,
                        callbacks: callbacksProvider()
                    )
                    let outcome: LoopOutcome
                    do {
                        outcome = try await reconcilable.loop(identity: identity, context: context)
                    } catch {
                        outcome = .drifted(reason: "loop threw: \(error)")
                    }
                    guard let consecutiveDrifts = await self?.record(outcome, for: identity) else { return }
                    if case .drifted(let reason) = outcome {
                        await onDrift(snapshot.treeNode, reason, consecutiveDrifts)
                        // `clearBusy` is the remediation caller's responsibility —
                        // fired from the remediation's onComplete callback.
                    }
                }
                guard let nextInterval = await self?.currentInterval(identity: identity) else { return }
                try? await sleep(nextInterval)
            }
        }

        entries[identity] = Entry(
            task: task,
            treeNode: treeNode,
            tickInterval: tickInterval,
            remediationInFlight: false,
            consecutiveDrifts: 0
        )
    }

    /// Cancels and removes the loop for `identity`. No-op if no loop is running.
    func stop(identity: NodeIdentity) {
        entries.removeValue(forKey: identity)?.task.cancel()
    }

    /// Cancels every running loop. Used at engine shutdown.
    func stopAll() {
        for (_, entry) in entries { entry.task.cancel() }
        entries.removeAll()
    }

    func clearBusy(_ identity: NodeIdentity) {
        entries[identity]?.remediationInFlight = false
    }

    /// The wait before the next check after `n` consecutive drifts:
    /// `tickInterval × 2^(n−1)`, capped at `maxDriftBackoff`. `n ≤ 1`, or a
    /// `tickInterval` already at the cap, keeps `tickInterval`.
    static func driftBackoff(tickInterval: Duration, consecutiveDrifts n: Int) -> Duration {
        guard n > 1, tickInterval > .zero, tickInterval < maxDriftBackoff else { return tickInterval }
        // Double step by step instead of computing 2^(n−1): stopping at the cap
        // means nothing can overflow however large `n` grows.
        var interval = tickInterval
        for _ in 1..<n {
            interval *= 2
            if interval >= maxDriftBackoff { return maxDriftBackoff }
        }
        return interval
    }

    // MARK: - Private

    private func snapshot(identity: NodeIdentity) -> (treeNode: TreeNode, busy: Bool)? {
        guard let entry = entries[identity] else { return nil }
        return (entry.treeNode, entry.remediationInFlight)
    }

    private func currentInterval(identity: NodeIdentity) -> Duration? {
        guard let entry = entries[identity] else { return nil }
        return Self.driftBackoff(tickInterval: entry.tickInterval, consecutiveDrifts: entry.consecutiveDrifts)
    }

    /// Counts `outcome` toward the identity's consecutive drifts and returns the
    /// new count — `nil` if its loop was stopped. A drift also latches busy.
    private func record(_ outcome: LoopOutcome, for identity: NodeIdentity) -> Int? {
        guard var entry = entries[identity] else { return nil }
        if case .drifted = outcome {
            entry.consecutiveDrifts += 1
            entry.remediationInFlight = true
        } else {
            entry.consecutiveDrifts = 0
        }
        entries[identity] = entry
        return entry.consecutiveDrifts
    }
}
