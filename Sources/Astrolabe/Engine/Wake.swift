import Synchronization

/// The engine's wake signal: a single slot.
///
/// A burst of signals before the engine waits again collapses into one pass. Signals are hints,
/// not data — every pass recomputes every hash — so a spurious wake costs one evaluation and
/// changes nothing.
///
/// Lock-based rather than actor-isolated because observation's `onChange` is a synchronous
/// `@Sendable` closure that runs inside the writer's `willSet`.
final class Wake: Sendable {
    private struct State {
        var pending = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter else {
                state.pending = true
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Someone is waiting and no signal is pending. Tests use it to tell when the engine is idle.
    var isParked: Bool {
        state.withLock { $0.waiter != nil && !$0.pending }
    }

    /// Returns at the first signal since the last wait, at `deadline` on `clock`, or when the
    /// task is cancelled.
    func wait(until deadline: Duration?, clock: EngineClock) async {
        let timer = deadline.map { deadline in
            Task { [self] in
                do { try await clock.sleep(deadline) } catch { return }
                signal()
            }
        }
        defer { timer?.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if state.pending {
                        state.pending = false
                        return true
                    }
                    state.waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            signal()
        }
    }
}
