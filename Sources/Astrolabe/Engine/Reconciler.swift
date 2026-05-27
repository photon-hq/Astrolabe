import Foundation

/// Thin orchestrator for mount/unmount waves.
///
/// Dispatches a single attempt to the node's `mount`/`unmount` and logs any
/// thrown error via telemetry. The Reconciler has no notion of success or
/// failure — convergence is `loop()`'s job, and re-attempting on drift is
/// `LoopSupervisor`'s job.
public struct Reconciler: Sendable {

    let telemetry: any AstrolabeTelemetry

    public init(telemetry: any AstrolabeTelemetry = NoopAstrolabeTelemetry()) {
        self.telemetry = telemetry
    }

    // MARK: - Mount

    public func mount(_ node: TreeNode, callbacks: ModifierStore.Callbacks? = nil, payloadStore: PayloadStore) async {
        let context = ReconcileContext(payloadStore: payloadStore, callbacks: callbacks)
        let attrs = TelemetryAttributes.nodeAttributes(
            node,
            verbose: telemetry.verboseNodeAttributes
        )
        do {
            try await telemetry.withSpan("astrolabe.mount", attributes: attrs) {
                guard case .leaf(let reconcilable) = node.kind else { return }
                try await reconcilable.mount(identity: node.identity, context: context)
            }
        } catch {
            let desc: String
            if case .leaf(let r) = node.kind { desc = r.displayName } else { desc = "unknown" }
            print("[Astrolabe] Mount failed for \(desc): \(error)")
            var logAttrs = attrs
            logAttrs.merge(
                TelemetryAttributes.errorAttributes(error, verbose: telemetry.verboseNodeAttributes)
            ) { _, new in new }
            telemetry.log(.error, "astrolabe.mount.failed", attributes: logAttrs)
        }
    }

    // MARK: - Unmount

    public func unmount(_ node: TreeNode, callbacks: ModifierStore.Callbacks? = nil, payloadStore: PayloadStore) async {
        let attrs = TelemetryAttributes.nodeAttributes(
            node,
            verbose: telemetry.verboseNodeAttributes
        )
        do {
            try await telemetry.withSpan("astrolabe.unmount", attributes: attrs) {
                guard case .leaf(let reconcilable) = node.kind else { return }
                let context = ReconcileContext(payloadStore: payloadStore, callbacks: callbacks)
                try await reconcilable.unmount(identity: node.identity, context: context)
                print("[Astrolabe] Unmounted \(node.identity.path).")
            }
        } catch {
            print("[Astrolabe] Unmount failed for \(node.identity.path): \(error)")
            var logAttrs = attrs
            logAttrs.merge(
                TelemetryAttributes.errorAttributes(error, verbose: telemetry.verboseNodeAttributes)
            ) { _, new in new }
            telemetry.log(.error, "astrolabe.unmount.failed", attributes: logAttrs)
        }
    }
}

public enum ReconcileError: Error, Sendable {
    case processFailed(path: String, arguments: [String], output: String)
}
