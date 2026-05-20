import Foundation

/// Owns the per-identity background tasks that periodically call `node.loop(...)`
/// to detect drift between the declared state and reality.
///
/// Domain-agnostic — speaks only the `ReconcilableNode` protocol. Scheduling and
/// cancellation live here; the *check itself* lives in each node's `loop` method.
actor LoopSupervisor {
    private struct Entry {
        let task: Task<Void, Never>
        var remediationInFlight: Bool
    }

    private var entries: [NodeIdentity: Entry] = [:]

    /// Begins looping for `treeNode.identity`. No-op if a loop is already running.
    ///
    /// The tree node is captured for use in drift remediation (it carries the
    /// `.retry` / `.priority` modifiers). `callbacksProvider` is invoked freshly
    /// on every drift event because `ModifierStore` is rebuilt each tick — a
    /// captured snapshot would go stale.
    func start(
        treeNode: TreeNode,
        tickInterval: Duration,
        payloadStore: PayloadStore,
        callbacksProvider: @escaping @Sendable () -> ModifierStore.Callbacks?,
        onDrift: @escaping @Sendable (TreeNode, String?) async -> Void
    ) {
        let identity = treeNode.identity
        guard entries[identity] == nil else { return }
        guard case .leaf(let reconcilable) = treeNode.kind else { return }

        let task = Task { [weak self] in
            // Initial delay — let the system settle after mount completes
            // before the first verification.
            try? await Task.sleep(for: tickInterval)

            while !Task.isCancelled {
                let busy = await self?.isBusy(identity) ?? false
                if !busy {
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
                    if case .drifted(let reason) = outcome {
                        await self?.markBusy(identity)
                        await onDrift(treeNode, reason)
                        // `clearBusy` is the remediation caller's responsibility —
                        // fired from the remediation's onComplete callback.
                    }
                }
                try? await Task.sleep(for: tickInterval)
            }
        }

        entries[identity] = Entry(task: task, remediationInFlight: false)
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

    func isBusy(_ identity: NodeIdentity) -> Bool {
        entries[identity]?.remediationInFlight ?? false
    }

    func markBusy(_ identity: NodeIdentity) {
        entries[identity]?.remediationInFlight = true
    }

    func clearBusy(_ identity: NodeIdentity) {
        entries[identity]?.remediationInFlight = false
    }
}
