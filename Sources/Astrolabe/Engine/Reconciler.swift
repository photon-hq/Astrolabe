import Foundation

/// Thin orchestrator for mount/unmount operations.
///
/// Owns retry logic and error handling. Delegates actual system changes
/// to `ReconcilableNode` conformers (mount) and `PayloadRecord` (unmount).
public struct Reconciler: Sendable {

    public init() {}

    // MARK: - Mount

    public func mount(_ node: TreeNode, callbacks: ModifierStore.Callbacks? = nil, payloadStore: PayloadStore) async {
        let retryConfig = node.modifiers.compactMap { modifier -> (Int, Double?)? in
            if case .retry(let count, let delay) = modifier {
                return (count, delay)
            }
            return nil
        }.first

        let maxAttempts = (retryConfig?.0 ?? 0) + 1
        let retryDelay = retryConfig?.1
        let context = ReconcileContext(payloadStore: payloadStore)

        var lastError: (any Error)?
        for attempt in 1...maxAttempts {
            do {
                guard case .leaf(let reconcilable) = node.kind else { break }

                // Run preInstall hooks
                if let handlers = callbacks?.preInstall {
                    for handler in handlers {
                        try await handler.handler()
                    }
                }

                try await reconcilable.mount(identity: node.identity, context: context)

                // Run postInstall hooks
                if let handlers = callbacks?.postInstall {
                    for handler in handlers {
                        await handler.handler()
                    }
                }

                lastError = nil
                break
            } catch {
                lastError = error
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

        // Execute onFail handlers if mount failed
        if let error = lastError, let onFailHandlers = callbacks?.onFail {
            for handler in onFailHandlers {
                await handler.handler(error)
            }
        }
    }

    // MARK: - Unmount

    public func unmount(_ identity: NodeIdentity, callbacks: ModifierStore.Callbacks? = nil, payloadStore: PayloadStore) async {
        guard let record = payloadStore.record(for: identity) else { return }

        // Run preUninstall hooks (errors logged, do not block unmount)
        if let handlers = callbacks?.preUninstall {
            for handler in handlers {
                do {
                    try await handler.handler()
                } catch {
                    print("[Astrolabe] preUninstall hook failed for \(identity.path): \(error)")
                }
            }
        }

        do {
            try await record.performUnmount()
            payloadStore.remove(for: identity)
            print("[Astrolabe] Unmounted \(identity.path).")

            // Run postUninstall hooks
            if let handlers = callbacks?.postUninstall {
                for handler in handlers {
                    await handler.handler()
                }
            }
        } catch {
            print("[Astrolabe] Unmount failed for \(identity.path): \(error)")
        }
    }
}

public enum ReconcileError: Error, Sendable {
    case processFailed(path: String, arguments: [String], output: String)
}
