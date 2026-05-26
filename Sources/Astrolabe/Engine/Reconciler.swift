import Foundation

/// Thin orchestrator for mount/unmount operations.
///
/// Owns retry logic and error handling. Delegates actual system changes
/// to `ReconcilableNode` conformers (mount) and `PayloadRecord` (unmount).
public struct Reconciler: Sendable {

    let telemetry: any AstrolabeTelemetry

    public init(telemetry: any AstrolabeTelemetry = NoopAstrolabeTelemetry()) {
        self.telemetry = telemetry
    }

    // MARK: - Mount

    @discardableResult
    public func mount(_ node: TreeNode, callbacks: ModifierStore.Callbacks? = nil, payloadStore: PayloadStore) async -> Bool {
        let retryConfig = node.modifiers.compactMap { modifier -> (Int, Double?)? in
            if case .retry(let count, let delay) = modifier {
                return (count, delay)
            }
            return nil
        }.first

        let maxAttempts = (retryConfig?.0 ?? 0) + 1
        let retryDelay = retryConfig?.1
        let context = ReconcileContext(payloadStore: payloadStore, callbacks: callbacks)

        var spanAttributes = TelemetryAttributes.nodeAttributes(node)
        spanAttributes["astrolabe.max_attempts"] = .int(maxAttempts)

        let attemptState = MountAttemptState()

        do {
            try await telemetry.withSpan("astrolabe.mount", attributes: spanAttributes) {
                for attempt in 1...maxAttempts {
                    attemptState.attemptsUsed = attempt
                    do {
                        guard case .leaf(let reconcilable) = node.kind else { return }

                        try await reconcilable.mount(identity: node.identity, context: context)

                        attemptState.lastError = nil
                        return
                    } catch {
                        attemptState.lastError = error
                        let desc: String
                        if case .leaf(let r) = node.kind { desc = r.displayName } else { desc = "unknown" }
                        if attempt < maxAttempts {
                            print("[Astrolabe] Mount failed for \(desc) (attempt \(attempt)/\(maxAttempts)): \(error)")
                            if let delay = retryDelay {
                                try? await Task.sleep(for: .seconds(delay))
                            }
                        } else {
                            print("[Astrolabe] Mount failed for \(desc): \(error)")
                        }
                    }
                }
                if let lastError = attemptState.lastError { throw lastError }
            }
        } catch {
            var logAttributes = TelemetryAttributes.nodeAttributes(node)
            logAttributes["astrolabe.error.type"] = .string(TelemetryAttributes.errorTypeName(error))
            logAttributes["astrolabe.attempt"] = .int(attemptState.attemptsUsed)
            logAttributes["astrolabe.max_attempts"] = .int(maxAttempts)
            telemetry.log(.error, "astrolabe.mount.failed", attributes: logAttributes)
        }

        let lastError = attemptState.lastError
        if let error = lastError, let onFailHandlers = callbacks?.onFail {
            for handler in onFailHandlers {
                await handler.handler(error)
            }
        }

        return lastError == nil
    }

    // MARK: - Unmount

    public func unmount(_ node: TreeNode, callbacks: ModifierStore.Callbacks? = nil, payloadStore: PayloadStore) async {
        do {
            guard case .leaf(let reconcilable) = node.kind else { return }
            let context = ReconcileContext(payloadStore: payloadStore, callbacks: callbacks)
            try await reconcilable.unmount(identity: node.identity, context: context)
            print("[Astrolabe] Unmounted \(node.identity.path).")
        } catch {
            print("[Astrolabe] Unmount failed for \(node.identity.path): \(error)")
        }
    }
}

public enum ReconcileError: Error, Sendable {
    case processFailed(path: String, arguments: [String], output: String)
}

private final class MountAttemptState: @unchecked Sendable {
    var lastError: (any Error)?
    var attemptsUsed = 0
}
