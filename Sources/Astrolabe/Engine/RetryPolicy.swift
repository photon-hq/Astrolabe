/// Controls the drift-check cadence while a declaration keeps reporting drift.
///
/// The loop remains the retry: drift re-enqueues mount through the normal task
/// queue, and a healthy observation restores the configured loop interval.
public enum RetryPolicy: Sendable, Equatable {
    /// Keeps checking and retrying at the configured loop interval.
    case constant

    /// Doubles the loop interval after each repeat drift, up to `maxDelay`.
    ///
    /// The first drift keeps the normal interval. The cap never shortens that
    /// interval. Jitter is opt-in, so the defaults preserve deterministic timing.
    case exponential(maxDelay: Duration = .seconds(900), jitter: Jitter = .none)

    /// Randomization of the wait after drift, bounded by the normal cadence.
    public enum Jitter: Sendable, Equatable {
        case none
        /// Samples between half the backed-off delay and the full delay,
        /// with the normal loop interval as the lower bound.
        case equal
    }

    func delay(
        tickInterval: Duration,
        consecutiveDrifts: Int,
        random: () -> Double
    ) -> Duration {
        guard case .exponential(let maxDelay, let jitter) = self,
              consecutiveDrifts > 1, tickInterval > .zero, tickInterval < maxDelay else {
            return tickInterval
        }

        var interval = tickInterval
        for _ in 1..<consecutiveDrifts {
            if interval >= maxDelay - interval {
                interval = maxDelay
                break
            }
            interval += interval
        }

        guard jitter == .equal else { return interval }
        let lowerBound = max(tickInterval, interval / 2)
        let window = interval - lowerBound
        return lowerBound + min(window, window * random())
    }
}
