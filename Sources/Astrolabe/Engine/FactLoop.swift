import Synchronization

/// One fact's loop: read, store what was read, sleep, read again.
///
/// Started by the first pass that reads the fact, and cancelled only at shutdown: a gate that
/// closes and reopens finds a current value. Nothing the engine does starts, stops, or hurries
/// a read.
///
/// | after   | success          | failure           |
/// |---------|------------------|-------------------|
/// | `.once` | done             | backoff           |
/// | `.every(d)` | `d`          | `min(d, backoff)` |
///
/// Backoff is `Backoff.standard`, counted over failures in a row.
struct FactLoop {
    let id: ObjectIdentifier
    let schedule: FactSchedule
    let timeout: Duration
    let read: @Sendable () async throws -> AnyFactValue
    let clock: EngineClock
    weak var store: FactStore?

    @MainActor
    func run() async {
        var failures = 0
        while true {
            let result = await Self.race(read, timeout: timeout, clock: clock)
            guard !Task.isCancelled, let store else { return }
            switch result {
            case .success(let value):
                failures = 0
                store.readSucceeded(id, value)
            case .failure(let error):
                failures += 1
                store.readFailed(id, error, inARow: failures)
            }

            guard let delay = delay(afterFailures: failures) else { return }
            do {
                try await clock.sleep(clock.now() + delay)
            } catch {
                return
            }
            self.store?.readStarted(id)
        }
    }

    /// How long to sleep before the next read, or `nil` when there is none before shutdown.
    func delay(afterFailures failures: Int) -> Duration? {
        guard failures > 0 else { return schedule.interval }
        let backoff = Backoff.standard.delay(attempt: failures)
        return schedule.interval.map { min($0, backoff) } ?? backoff
    }

    /// Runs `read` against `timeout` on `clock`. A read past its timeout is cancelled and
    /// abandoned, like a wedged operation: nothing waits for it to end.
    static func race(
        _ read: @escaping @Sendable () async throws -> AnyFactValue,
        timeout: Duration,
        clock: EngineClock
    ) async -> Result<AnyFactValue, any Error> {
        let deadline = clock.now() + timeout
        let first = FirstResult()
        let reader = Task {
            do {
                first.resolve(.success(try await read()))
            } catch {
                first.resolve(.failure(error))
            }
        }
        let timer = Task {
            do { try await clock.sleep(deadline) } catch { return }
            first.resolve(.failure(FactReadTimedOut()))
        }
        let result = await withTaskCancellationHandler {
            await first.value
        } onCancel: {
            first.resolve(.failure(CancellationError()))
        }
        reader.cancel()
        timer.cancel()
        return result
    }
}

/// Thrown in place of a read that hit `K.timeout`.
struct FactReadTimedOut: Error {}

/// The first of several racing results; later ones are dropped.
private final class FirstResult: Sendable {
    private struct State {
        var result: Result<AnyFactValue, any Error>?
        var waiter: CheckedContinuation<Result<AnyFactValue, any Error>, Never>?
    }

    private let state = Mutex(State())

    func resolve(_ result: Result<AnyFactValue, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Result<AnyFactValue, any Error>, Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: result)
    }

    var value: Result<AnyFactValue, any Error> {
        get async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Result<AnyFactValue, any Error>? in
                    if let result = state.result { return result }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
