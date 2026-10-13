/// What the engine does when a rollout or removal toward a target fails (throws or times out).
///
/// Cancellation is not failure and never triggers a policy.
public enum RetryPolicy: Sendable, Equatable {
    /// Leave the Mac as is and retry the declared target after backoff.
    ///
    /// Fits when an older snapshot can't be applied again — a tool that only installs its
    /// latest version.
    case retry(Backoff = .standard)

    /// Restore the last successful snapshot now, then retry the declared target after backoff.
    /// With no successful snapshot on record, the failed snapshot is removed instead.
    ///
    /// Fits when an older snapshot can be applied again — a package whose old version can be
    /// downloaded again. On a first rollout this removes what failed, which can undo something
    /// that existed before Astrolabe managed it; pick it only where that's safe.
    case rollback(Backoff = .standard)

    /// Leave the Mac as is and don't retry until the declared hash changes or the agent restarts.
    case wait

    /// The backoff between attempts, or `nil` for `.wait`.
    var backoff: Backoff? {
        switch self {
        case .retry(let backoff), .rollback(let backoff): backoff
        case .wait: nil
        }
    }
}

/// Exponential backoff between attempts toward the same target.
///
/// Kept per id and target in memory: a new target starts again at attempt 1, and a restart
/// resets everything.
public struct Backoff: Sendable, Equatable {
    /// The delay after the first failure. Default: 15 seconds.
    public var initial: Duration
    /// The longest delay. Default: 30 minutes.
    public var max: Duration

    public init(initial: Duration = .seconds(15), max: Duration = .seconds(30 * 60)) {
        self.initial = initial
        self.max = max
    }

    public static let standard = Backoff()

    /// `initial × 2^(attempt − 1)`, capped at `max`. `attempt` counts from 1.
    public func delay(attempt: Int) -> Duration {
        var delay = initial
        for _ in 1..<Swift.max(attempt, 1) {
            guard delay < max else { break }
            delay *= 2
        }
        return Swift.min(delay, max)
    }
}
