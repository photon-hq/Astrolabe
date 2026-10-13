/// The engine's view of a clock: time as a `Duration` since the engine was created.
///
/// Wraps any `Clock<Duration>` so the engine can store instants without carrying the clock's
/// `Instant` type around. Tests drive the engine with a manual clock.
struct EngineClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (_ until: Duration) async throws -> Void

    init(_ clock: any Clock<Duration>) {
        self.init(opening: clock)
    }

    private init<C: Clock<Duration>>(opening clock: C) {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { deadline in
            try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil)
        }
    }
}

/// What one pass decided.
struct Plan {
    enum Action {
        case start(id: String, OpPlan)
        case cancel(id: String, CancelReason)
    }

    /// Why an id that differs from the declaration isn't being acted on this pass.
    enum Hold: Equatable {
        /// Loaded from disk and not declared: removal waits for the startup grace.
        case startupGrace
        /// The last attempt failed; the retry waits for its backoff.
        case backoff(attempts: Int)
        /// The last attempt failed under `.wait`.
        case failedWaiting
        /// A cancelled operation has to end before the next one starts.
        case waitingForOperation
        /// Declared twice with different hashes, or its kind is claimed by another type.
        case frozen
    }

    var actions: [Action] = []
    var holds: [(id: String, hold: Hold)] = []
    /// Ids whose cancelled operation outlived the cancel grace this pass.
    var wedged: [String] = []
    /// The earliest time a held id becomes due: a backoff or the startup grace. Operation caps
    /// and cancel graces come from `Scheduler.nextDeadline(in:)` once the plan has run.
    private(set) var nextTimer: Duration?

    mutating func hold(_ id: String, _ hold: Hold) {
        holds.append((id, hold))
    }

    mutating func wake(at time: Duration) {
        nextTimer = min(nextTimer ?? time, time)
    }
}

/// Timing rules: per-operation caps, the cancel grace, and shutdown.
enum Scheduler {
    /// How long a cancelled operation gets to end before it is logged as wedged.
    static let cancelGrace: Duration = .seconds(60)
    /// How long shutdown waits for cancelled operations to end.
    static let shutdownGrace: Duration = .seconds(10)

    /// Checks the in-flight operation's deadlines: past `R.timeout` it is cancelled, and past
    /// the cancel grace after a cancel it is flagged as wedged. Returns whether it timed out
    /// this pass.
    static func checkDeadlines(_ id: String, _ slot: inout Slot, now: Duration, plan: inout Plan) -> Bool {
        guard var op = slot.op, let deadline = deadline(of: op), now >= deadline else { return false }
        guard op.cancellation != nil else {
            plan.actions.append(.cancel(id: id, .timedOut))
            return true
        }
        // Only this id waits on it: it gets no new operation until the task ends.
        op.wedged = true
        slot.op = op
        plan.wedged.append(id)
        return false
    }

    /// The earliest operation deadline across `slots`. Computed after a pass has started and
    /// cancelled operations, so their caps and cancel graces are included.
    static func nextDeadline(in slots: Slots) -> Duration? {
        slots.ids.compactMap { slots[$0]?.op.flatMap(deadline(of:)) }.min()
    }

    /// When `op` next needs attention: its cap while running, the end of the cancel grace once
    /// cancelled, nothing once wedged.
    private static func deadline(of op: RunningOp) -> Duration? {
        guard let cancellation = op.cancellation else {
            return op.startedAt + op.plan.resource.timeout
        }
        return op.wedged ? nil : cancellation.at + cancelGrace
    }
}
