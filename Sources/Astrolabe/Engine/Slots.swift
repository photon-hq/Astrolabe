/// Where an operation, or the declaration, wants an id to be.
enum Target: Hashable, Sendable {
    case present(hash: String)
    case absent
}

/// The last snapshot that was successfully applied for an id. Mirrors `records.json`.
struct DiskEntry {
    let resource: AnyResource
    let hash: String
}

/// What the engine last moved an id toward. Set when an operation starts; a cancelled or failed
/// operation leaves it as it is.
///
/// Its monitor hash comes from the snapshot, so `records.json` keeps it without a field of its
/// own. `target` stays declared-only: failures, attempts and `.wait` answer to it alone.
enum Mark {
    case present(hash: String, resource: AnyResource)
    case removing(resource: AnyResource)

    var target: Target {
        switch self {
        case .present(let hash, _): .present(hash: hash)
        case .removing: .absent
        }
    }

    /// The snapshot behind the mark: what a removal of this id removes.
    var resource: AnyResource {
        switch self {
        case .present(_, let resource), .removing(let resource): resource
        }
    }

    /// The monitor hash the snapshot was built with; `nil` while removing, as for an undeclared id.
    var monitor: String? {
        switch self {
        case .present(_, let resource): resource.monitorHash()
        case .removing: nil
        }
    }
}

/// The last operation toward `target` failed.
struct Failure {
    let target: Target
    /// Failed attempts toward `target` in a row. A new target starts again at 1.
    var attempts: Int
    var retry: Retry
    /// The resource's backoff, for scheduling the retry once a rollback ends.
    let backoff: Backoff

    enum Retry {
        /// Due at this engine time.
        case at(Duration)
        /// `.wait`: not until the declared hash changes or a restart. A monitor change doesn't
        /// release it.
        case never
        /// `.rollback`: roll back now, then retry after backoff.
        case rollback(OpPlan)
        /// The rollback is in flight. When it ends, the retry is due after backoff.
        case rollingBack
    }
}

/// Everything the engine keeps for one id. Only `disk` is persisted.
struct Slot {
    /// Last success: mirrors `records.json`.
    var disk: DiskEntry?
    /// What the engine last moved toward.
    var memory: Mark?
    /// The operation toward `memory` was cancelled before it finished, so `memory` was never
    /// reached. Any declaration, even one equal to `memory`, then needs a new operation.
    var interrupted = false
    var failure: Failure?
    var op: RunningOp?

    /// Nothing left to remember: not on record, nothing in flight, nothing to retry, and either
    /// never moved or fully removed.
    var isSettledAbsent: Bool {
        guard disk == nil, op == nil, failure == nil else { return false }
        switch memory {
        case nil: return true
        case .removing?: return !interrupted
        case .present?: return false
        }
    }
}

/// The engine's per-id state, and the diff that turns a declaration into a plan.
struct Slots {
    private(set) var byID: [String: Slot] = [:]

    subscript(id: String) -> Slot? {
        get { byID[id] }
        set { byID[id] = newValue }
    }

    var ids: Dictionary<String, Slot>.Keys { byID.keys }

    var runningIDs: [String] {
        byID.compactMap { $0.value.op == nil ? nil : $0.key }.sorted()
    }

    /// Adds an entry loaded from `records.json`: on disk, and moved toward.
    mutating func load(_ id: String, _ entry: DiskEntry) {
        byID[id] = Slot(disk: entry, memory: .present(hash: entry.hash, resource: entry.resource))
    }

    /// Compares the declaration with what the engine last moved toward, id by id. Anything not
    /// declared is removed.
    ///
    /// Only for a declaration from a pass that read real facts. Mutates only bookkeeping that
    /// holds whether or not the plan is acted on: failures toward a target no longer declared
    /// are dropped, and operations past their deadlines are flagged.
    mutating func diff(_ declaration: Declaration, now: Duration) -> Plan {
        var plan = Plan()
        let ids = Set(byID.keys).union(declaration.items.keys).union(declaration.frozen)
        for id in ids.sorted() {
            var slot = byID[id] ?? Slot()
            defer {
                if declaration.items[id] == nil, slot.isSettledAbsent {
                    byID[id] = nil
                } else {
                    byID[id] = slot
                }
            }

            let timedOut = Scheduler.checkDeadlines(id, &slot, now: now, plan: &plan)

            if declaration.frozen.contains(id) {
                plan.hold(id, .frozen)
                continue
            }

            let item = declaration.items[id]
            let target: Target = item.map { .present(hash: $0.hash) } ?? .absent
            if let failure = slot.failure, failure.target != target {
                // A new target starts again at attempt 1.
                slot.failure = nil
            }

            switch decide(slot, item: item, target: target, now: now) {
            case .idle:
                break
            case .hold(let hold, let until):
                plan.hold(id, hold)
                if let until { plan.wake(at: until) }
            case .start(let op):
                if let running = slot.op {
                    // One operation per id: the replacement starts once this one has ended. Only
                    // a new target supersedes it; a monitor change reruns after it.
                    if running.cancellation == nil, !timedOut, running.plan.target != op.target {
                        plan.actions.append(.cancel(id: id, .superseded))
                    }
                    plan.hold(id, .waitingForOperation)
                } else {
                    plan.actions.append(.start(id: id, op))
                }
            }
        }
        return plan
    }

    /// A waiting pass's only decisions: operations past their deadlines are cancelled, or
    /// flagged as wedged. Nothing else is decided or forgotten.
    mutating func checkDeadlines(now: Duration) -> Plan {
        var plan = Plan()
        for id in runningIDs {
            guard var slot = byID[id] else { continue }
            _ = Scheduler.checkDeadlines(id, &slot, now: now, plan: &plan)
            byID[id] = slot
        }
        return plan
    }

    private enum Decision {
        case idle
        case hold(Plan.Hold, until: Duration?)
        case start(OpPlan)
    }

    private func decide(
        _ slot: Slot,
        item: Declaration.Item?,
        target: Target,
        now: Duration
    ) -> Decision {
        if let failure = slot.failure {
            // Only failures toward `target` survive to here.
            guard slot.op == nil else { return .idle }
            switch failure.retry {
            case .never:
                return .hold(.failedWaiting, until: nil)
            case .rollingBack:
                return .idle
            case .rollback(let rollback):
                return .start(rollback)
            case .at(let due) where due > now:
                return .hold(.backoff(attempts: failure.attempts), until: due)
            case .at:
                break
            }
            switch target {
            case .present:
                guard let item else { return .idle }
                return .start(OpPlan(kind: .rollout, target: target, resource: item.resource))
            case .absent:
                guard let memory = slot.memory else { return .idle }
                return .start(OpPlan(kind: .remove, target: .absent, resource: memory.resource))
            }
        }

        if let memory = slot.memory, memory.target == target, memory.monitor == item?.monitor, !slot.interrupted {
            // Already moved toward the declaration: a rollout in flight keeps running.
            return .idle
        }
        // A new target, an interrupted operation, or the same target with a monitor that moved:
        // `diff` cancels only for a new target.

        switch target {
        case .present:
            guard let item else { return .idle }
            return .start(OpPlan(kind: .rollout, target: target, resource: item.resource))
        case .absent:
            guard let memory = slot.memory else { return .idle }
            return .start(OpPlan(kind: .remove, target: .absent, resource: memory.resource))
        }
    }
}
