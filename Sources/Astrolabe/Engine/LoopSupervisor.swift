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
/// `n`, and by default waits `tickInterval × 2^(n−1)` before its next check,
/// capped at 15 minutes and never below `tickInterval`; one
/// `.healthy` outcome resets it. This stays within the constitution — the loop is
/// still the only retry, through the same pipeline, and it never gives up; it
/// just slows down for a node that keeps failing.
actor LoopSupervisor {
    private struct Entry {
        let task: Task<Void, Never>
        let generation: UUID
        var treeNode: TreeNode
        var tickInterval: Duration
        var retryPolicy: RetryPolicy
        var remediationInFlight: Bool
        /// Consecutive `.drifted` outcomes; a `.healthy` one resets it.
        var consecutiveDrifts: Int
    }

    private var entries: [NodeIdentity: Entry] = [:]
    private let sleep: @Sendable (Duration) async throws -> Void
    private let random: @Sendable () -> Double

    /// - Parameter sleep: Waits out the interval between checks. Injectable so
    ///   tests can observe the requested intervals without waiting real time.
    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.sleep = sleep
        self.random = random
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
    /// count (1 on the first drift since the last `.healthy` check), and the
    /// generation required to clear busy when that remediation completes.
    func refresh(
        treeNode: TreeNode,
        tickInterval: Duration,
        retryPolicy: RetryPolicy = .exponential(),
        payloadStore: PayloadStore,
        callbacksProvider: @escaping @Sendable () -> ModifierStore.Callbacks?,
        onDrift: @escaping @Sendable (TreeNode, String?, Int, UUID) async -> Void
    ) {
        let identity = treeNode.identity
        if var existing = entries[identity] {
            existing.treeNode = treeNode
            existing.tickInterval = tickInterval
            existing.retryPolicy = retryPolicy
            entries[identity] = existing
            return
        }
        guard case .leaf = treeNode.kind else { return }

        let sleep = self.sleep
        let generation = UUID()
        let task = Task { [weak self] in
            // Initial delay — let the system settle after mount completes
            // before the first verification.
            guard let initialInterval = await self?.currentInterval(identity: identity, generation: generation) else { return }
            try? await sleep(initialInterval)

            while !Task.isCancelled {
                guard let snapshot = await self?.snapshot(identity: identity, generation: generation) else { return }
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
                    guard !Task.isCancelled,
                          let consecutiveDrifts = await self?.record(outcome, for: identity, generation: generation) else { return }
                    if case .drifted(let reason) = outcome {
                        await onDrift(snapshot.treeNode, reason, consecutiveDrifts, generation)
                        // `clearBusy` is the remediation caller's responsibility —
                        // fired from the remediation's onComplete callback.
                    }
                }
                guard let nextInterval = await self?.currentInterval(identity: identity, generation: generation) else { return }
                try? await sleep(nextInterval)
            }
        }

        entries[identity] = Entry(
            task: task,
            generation: generation,
            treeNode: treeNode,
            tickInterval: tickInterval,
            retryPolicy: retryPolicy,
            remediationInFlight: false,
            consecutiveDrifts: 0
        )
    }

    /// Cancels and removes the loop, returning its task so callers can join it.
    @discardableResult
    func stop(identity: NodeIdentity) -> Task<Void, Never>? {
        guard let entry = entries.removeValue(forKey: identity) else { return nil }
        entry.task.cancel()
        return entry.task
    }

    /// Cancels every running loop. Used at engine shutdown.
    func stopAll() {
        for (_, entry) in entries { entry.task.cancel() }
        entries.removeAll()
    }

    func clearBusy(_ identity: NodeIdentity, generation: UUID) {
        guard entries[identity]?.generation == generation else { return }
        entries[identity]?.remediationInFlight = false
    }

    // MARK: - Private

    private func snapshot(identity: NodeIdentity, generation: UUID) -> (treeNode: TreeNode, busy: Bool)? {
        guard let entry = entries[identity], entry.generation == generation else { return nil }
        return (entry.treeNode, entry.remediationInFlight)
    }

    private func currentInterval(identity: NodeIdentity, generation: UUID) -> Duration? {
        guard let entry = entries[identity], entry.generation == generation else { return nil }
        return entry.retryPolicy.delay(
            tickInterval: entry.tickInterval,
            consecutiveDrifts: entry.consecutiveDrifts,
            random: random
        )
    }

    /// Counts `outcome` toward the identity's consecutive drifts and returns the
    /// new count — `nil` if its loop was stopped. A drift also latches busy.
    private func record(_ outcome: LoopOutcome, for identity: NodeIdentity, generation: UUID) -> Int? {
        guard var entry = entries[identity], entry.generation == generation else { return nil }
        if case .drifted = outcome {
            if entry.consecutiveDrifts < .max { entry.consecutiveDrifts += 1 }
            entry.remediationInFlight = true
        } else {
            entry.consecutiveDrifts = 0
        }
        entries[identity] = entry
        return entry.consecutiveDrifts
    }
}
