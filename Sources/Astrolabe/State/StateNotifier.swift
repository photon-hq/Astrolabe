import Foundation

/// Unified notification hub for all state changes.
///
/// Replaces `StateTracker`. Owns the notification stream and the canonical
/// environment values. Providers write here, `@State` notifies here.
/// Only actual changes trigger `tick()`.
public final class StateNotifier: @unchecked Sendable {
    public static let shared = StateNotifier()

    private let lock = NSLock()
    private var environment = EnvironmentValues()

    private let _continuation: AsyncStream<Void>.Continuation
    public let changes: AsyncStream<Void>

    private init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.changes = stream
        self._continuation = continuation
    }

    /// Snapshot environment for tick().
    func currentEnvironment() -> EnvironmentValues {
        lock.withLock { environment }
    }

    /// Write provider results into the canonical environment.
    /// Returns `true` if any provider reported a change.
    func updateEnvironment(from providers: [any StateProvider]) -> Bool {
        lock.withLock {
            var env = environment
            var changed = false
            for provider in providers {
                if provider.check(updating: &env) {
                    changed = true
                }
            }
            if changed { environment = env }
            return changed
        }
    }

    /// Signal that state changed — triggers tick().
    func notifyChange() {
        _continuation.yield()
    }
}
