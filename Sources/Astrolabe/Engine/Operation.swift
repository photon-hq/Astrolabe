import Foundation

/// The kind of operation an id runs.
enum OpKind: String, Sendable {
    /// Toward the declared snapshot.
    case rollout
    /// Of the snapshot behind memory, once the id is no longer declared.
    case remove
    /// `.rollback` after a failure: the last successful snapshot rolled back out, or with none on
    /// record, the failed snapshot removed.
    case rollback
}

/// An operation the engine has decided to start.
struct OpPlan: Sendable {
    let kind: OpKind
    let target: Target
    /// The snapshot rolled out (`target` present) or removed (`target` absent).
    let resource: AnyResource
}

/// Why the engine cancelled an operation.
enum CancelReason: String, Sendable {
    /// The declaration moved on. Not a failure.
    case superseded
    /// Past `R.timeout`. A failure: the policy applies once it ends.
    case timedOut = "timed_out"
    /// SIGTERM. Not a failure.
    case shutdown
}

/// An operation in flight. Its task runs on the main actor and awaits the resource's
/// `@concurrent` function, so the work itself runs off the main actor.
struct RunningOp {
    let number: Int
    let plan: OpPlan
    let task: Task<Void, Never>
    let startedAt: Duration
    var cancellation: (reason: CancelReason, at: Duration)?
    /// Still running `Scheduler.cancelGrace` after the cancel.
    var wedged = false
}

/// The engine thrown in place of the operation's own error when it hit `R.timeout`.
struct OperationTimedOut: Error {}

extension Engine {
    func start(_ id: String, _ plan: OpPlan) {
        var slot = slots[id] ?? Slot()
        guard slot.op == nil else { return }

        switch plan.target {
        case .present(let hash): slot.memory = .present(hash: hash, resource: plan.resource)
        case .absent: slot.memory = .removing(resource: plan.resource)
        }
        slot.interrupted = false
        if plan.kind == .rollback {
            slot.failure?.retry = .rollingBack
        }

        opCounter += 1
        let number = opCounter
        let telemetry = self.telemetry
        let attributes = TelemetryAttributes.operationAttributes(
            id: id,
            kind: plan.resource.kind,
            operation: plan.kind.rawValue,
            attempt: plan.kind == .rollback ? nil : (slot.failure?.attempts ?? 0) + 1,
            verbose: telemetry.verboseNodeAttributes
        )
        let task = Task { [weak self] in
            let error: (any Error)?
            do {
                try await telemetry.withSpan("astrolabe.operation", attributes: attributes) {
                    switch plan.target {
                    case .present: try await plan.resource.rollout()
                    case .absent: try await plan.resource.remove()
                    }
                }
                error = nil
            } catch let thrown {
                error = thrown
            }
            self?.finish(id, number: number, error: error)
        }
        slot.op = RunningOp(number: number, plan: plan, task: task, startedAt: clock.now())
        slots[id] = slot
        note(.info, "astrolabe.operation.started", attributes, "\(plan.kind.rawValue) \(id)")
    }

    func cancel(_ id: String, _ reason: CancelReason) {
        guard var slot = slots[id], var op = slot.op, op.cancellation == nil else { return }
        op.cancellation = (reason, clock.now())
        op.task.cancel()
        slot.op = op
        if reason == .superseded {
            // The cancelled operation never reached `memory`.
            slot.interrupted = true
        }
        slots[id] = slot

        var attributes = opAttributes(id, op)
        attributes.merge(TelemetryAttributes.cancelAttributes(reason)) { _, new in new }
        if reason == .timedOut {
            note(.warning, "astrolabe.operation.timed_out", attributes, "\(op.plan.kind.rawValue) \(id) timed out")
        } else {
            telemetry.log(.debug, "astrolabe.operation.cancelling", attributes: attributes)
        }
    }

    /// Runs on the main actor when an operation's task ends.
    func finish(_ id: String, number: Int, error: (any Error)?) {
        guard var slot = slots[id], let op = slot.op, op.number == number else { return }
        slot.op = nil
        let now = clock.now()
        let attributes = opAttributes(id, op)

        if op.wedged {
            note(.info, "astrolabe.operation.unwedged", attributes, "\(op.plan.kind.rawValue) \(id) finally ended")
        }

        switch (error, op.cancellation?.reason) {
        case (nil, _):
            // Returned, even if it was cancelled meanwhile: the Mac now matches this snapshot,
            // so `memory` (which no other op could have moved) was reached after all.
            recordSuccess(id, op.plan)
            slot.disk = switch op.plan.target {
            case .present(let hash): DiskEntry(resource: op.plan.resource, hash: hash)
            case .absent: nil
            }
            slot.interrupted = false
            if op.plan.kind == .rollback {
                rollbackEnded(&slot, now: now)
            } else {
                slot.failure = nil
            }
            note(.info, "astrolabe.operation.succeeded", attributes, "\(op.plan.kind.rawValue) \(id) succeeded")

        case (_?, .superseded?), (_?, .shutdown?):
            // Cancellation is not failure: no policy.
            if op.plan.kind == .rollback {
                rollbackEnded(&slot, now: now)
            }
            telemetry.log(.info, "astrolabe.operation.cancelled", attributes: attributes)

        case (let error?, let reason):
            failed(&slot, op, reason == .timedOut ? OperationTimedOut() : error, now: now, attributes: attributes)
        }

        slots[id] = slot
        wake.signal()
    }

    /// Applies the resource's retry policy (§3.4).
    private func failed(
        _ slot: inout Slot,
        _ op: RunningOp,
        _ error: any Error,
        now: Duration,
        attributes: [String: TelemetryValue]
    ) {
        let policy = op.plan.resource.policy
        let backoff = policy.backoff ?? .standard
        var attributes = attributes
        attributes.merge(TelemetryAttributes.errorAttributes(error, verbose: telemetry.verboseNodeAttributes)) { _, new in new }

        if op.plan.kind == .rollback {
            // A failed rollback is never rolled back again. The target it served still retries
            // after its backoff.
            note(.error, "astrolabe.rollback.failed", attributes, "rollback of \(op.plan.resource.id) failed: \(error)")
            if case .rollingBack? = slot.failure?.retry {
                rollbackEnded(&slot, now: now)
            } else {
                // The declaration moved to the rolled-back snapshot meanwhile: retry it as is.
                slot.failure = Failure(
                    target: op.plan.target, attempts: 1, retry: .at(now + backoff.delay(attempt: 1)), backoff: backoff
                )
            }
            return
        }

        let attempts = slot.failure.flatMap { $0.target == op.plan.target ? $0.attempts : nil }.map { $0 + 1 } ?? 1
        let retry: Failure.Retry
        switch policy {
        case .retry:
            retry = .at(now + backoff.delay(attempt: attempts))
        case .wait:
            retry = .never
        case .rollback:
            retry = rollbackPlan(slot, failed: op.plan).map { .rollback($0) } ?? .at(now + backoff.delay(attempt: attempts))
        }
        slot.failure = Failure(target: op.plan.target, attempts: attempts, retry: retry, backoff: backoff)

        attributes.merge(TelemetryAttributes.failureAttributes(policy: policy, attempts: attempts)) { _, new in new }
        note(.error, "astrolabe.operation.failed", attributes, "\(op.plan.kind.rawValue) \(op.plan.resource.id) failed (attempt \(attempts)): \(error)")
    }

    /// What `.rollback` rolls out or removes after `failed`, or `nil` when there is nothing to go back to.
    private func rollbackPlan(_ slot: Slot, failed: OpPlan) -> OpPlan? {
        switch failed.target {
        case .present(let hash):
            guard let disk = slot.disk else {
                // First rollout: remove the failed snapshot.
                return OpPlan(kind: .rollback, target: .absent, resource: failed.resource)
            }
            // Nothing older to go back to when the failed target is the last success.
            guard disk.hash != hash else { return nil }
            return OpPlan(kind: .rollback, target: .present(hash: disk.hash), resource: disk.resource)
        case .absent:
            guard let disk = slot.disk else { return nil }
            return OpPlan(kind: .rollback, target: .present(hash: disk.hash), resource: disk.resource)
        }
    }

    /// The rollback ended, however it ended: the failed target is due after its backoff.
    private func rollbackEnded(_ slot: inout Slot, now: Duration) {
        guard var failure = slot.failure, case .rollingBack = failure.retry else { return }
        failure.retry = .at(now + failure.backoff.delay(attempt: failure.attempts))
        slot.failure = failure
    }

    private func recordSuccess(_ id: String, _ plan: OpPlan) {
        undecodable[id] = nil
        guard mode == .apply else { return }
        do {
            switch plan.target {
            case .present(let hash):
                try store.set(id, Record(kind: plan.resource.kind, hash: hash, snapshot: plan.resource.encode()))
            case .absent:
                try store.delete(id)
            }
        } catch {
            var attributes = TelemetryAttributes.resourceAttributes(
                id: id, kind: plan.resource.kind, verbose: telemetry.verboseNodeAttributes
            )
            attributes.merge(TelemetryAttributes.errorAttributes(error, verbose: telemetry.verboseNodeAttributes)) { _, new in new }
            note(.error, "astrolabe.records.write_failed", attributes, "writing records.json failed: \(error)")
        }
    }

    private func opAttributes(_ id: String, _ op: RunningOp) -> [String: TelemetryValue] {
        TelemetryAttributes.operationAttributes(
            id: id,
            kind: op.plan.resource.kind,
            operation: op.plan.kind.rawValue,
            attempt: nil,
            verbose: telemetry.verboseNodeAttributes
        )
    }
}
