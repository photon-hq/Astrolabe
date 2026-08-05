import Foundation

/// A system fact that costs a subprocess to read but is consumed from synchronous code.
///
/// Both `StateProvider.check(updating:)` and `EnvironmentKey.defaultValue` are synchronous
/// requirements, and swift-subprocess is async-only — so the read cannot happen inline. It
/// also *should* not: `StateNotifier.updateEnvironment` runs providers inside its lock, so a
/// slow probe there stalls every state update and, through `currentEnvironment()`, the tick
/// path itself. The CONSTITUTION already asks for this shape — *"Read state (already current
/// — no polling inside tick)"*.
///
/// So: `current` is a cached value that never blocks and never spawns, and the actual read
/// happens on a background task. Seed `initialValue` with whatever the old synchronous code
/// returned on failure, so the pre-warm-up window behaves the way a failed probe did.
final class SystemProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private var isRefreshing = false
    private let read: @Sendable () async -> Bool

    init(initialValue: Bool, read: @escaping @Sendable () async -> Bool) {
        self.value = initialValue
        self.read = read
    }

    /// The last known value. Safe to call from a lock, a tick, anywhere.
    var current: Bool {
        lock.withLock { value }
    }

    /// Starts a refresh unless one is already in flight, and returns immediately.
    ///
    /// Collapsing concurrent refreshes matters because the poll loop calls this on every
    /// tick; without it a slow `profiles` would pile up one subprocess per interval.
    func refreshInBackground() {
        let shouldStart = lock.withLock {
            guard !isRefreshing else { return false }
            isRefreshing = true
            return true
        }
        guard shouldStart else { return }

        Task.detached { [self] in
            let fresh = await read()
            lock.withLock {
                value = fresh
                isRefreshing = false
            }
        }
    }

    /// Refreshes and waits for the result.
    ///
    /// Used for the one-shot warm-up before the first `tick()`, so no `body` is ever
    /// evaluated against the seed value.
    @discardableResult
    func refresh() async -> Bool {
        let fresh = await read()
        lock.withLock { value = fresh }
        return fresh
    }
}
