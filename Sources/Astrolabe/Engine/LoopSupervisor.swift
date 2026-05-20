import Foundation

/// Owns the per-identity background tasks that periodically call `node.loop(...)`
/// to detect drift between the declared state and reality.
///
/// Domain-agnostic — speaks only the `ReconcilableNode` protocol. Scheduling and
/// cancellation live here; the *check itself* lives in each node's `loop` method.
actor LoopSupervisor {
    private struct Entry {
        let task: Task<Void, Never>
        var treeNode: TreeNode
        var remediationInFlight: Bool
    }

    private var entries: [NodeIdentity: Entry] = [:]

    /// Starts a drift loop for `treeNode.identity`, or refreshes the stored
    /// `TreeNode` if a loop is already running. Idempotent — safe to call on
    /// every tick. The freshest `TreeNode` is what `onDrift` receives and what
    /// the periodic `loop(_:)` call dispatches to (via `.kind`'s leaf).
    ///
    /// `callbacksProvider` is invoked freshly on every drift check because
    /// `ModifierStore` is rebuilt each tick — a captured snapshot would go stale.
    func refresh(
        treeNode: TreeNode,
        tickInterval: Duration,
        payloadStore: PayloadStore,
        callbacksProvider: @escaping @Sendable () -> ModifierStore.Callbacks?,
        onDrift: @escaping @Sendable (TreeNode, String?) async -> Void
    ) {
        let identity = treeNode.identity
        if var existing = entries[identity] {
            existing.treeNode = treeNode
            entries[identity] = existing
            return
        }
        guard case .leaf = treeNode.kind else { return }

        let task = Task { [weak self] in
            // Initial delay — let the system settle after mount completes
            // before the first verification.
            try? await Task.sleep(for: tickInterval)

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
                    if case .drifted(let reason) = outcome {
                        await self?.markBusy(identity)
                        await onDrift(snapshot.treeNode, reason)
                        // `clearBusy` is the remediation caller's responsibility —
                        // fired from the remediation's onComplete callback.
                    }
                }
                try? await Task.sleep(for: tickInterval)
            }
        }

        entries[identity] = Entry(task: task, treeNode: treeNode, remediationInFlight: false)
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

    // MARK: - Private

    private func snapshot(identity: NodeIdentity) -> (treeNode: TreeNode, busy: Bool)? {
        guard let entry = entries[identity] else { return nil }
        return (entry.treeNode, entry.remediationInFlight)
    }

    private func markBusy(_ identity: NodeIdentity) {
        entries[identity]?.remediationInFlight = true
    }
}
