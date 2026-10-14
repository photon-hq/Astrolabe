import Foundation

/// Whether the engine acts on its plan.
enum EngineMode: String, Sendable {
    case apply
    /// Print the diff each pass. Never start an operation, never write records.
    case dryRun = "dry_run"
}

/// The state engine.
///
/// Facts are its only input. Each pass evaluates `app.body` while the fact store records which
/// facts it reads, turns it into a declaration (`[id@hash]`), and diffs that against what it last
/// moved toward, id by id. Then it starts and cancels operations so the Mac matches, and waits for
/// the next wake: a fact the pass read changing, an operation ending, or a timer.
///
/// A pass that reads a fact before its first value has landed acts on nothing: the default only
/// lets `body` evaluate. The fact's first value wakes the next pass. So the diff stays pure —
/// anything not declared is removed — and nothing is ever removed or rolled out on a default.
///
/// The only arrow is fact → engine. The engine never asks for a read, rollouts never write
/// facts, and `body` never reads records.
@MainActor
final class Engine<App: Astrolabe> {
    let app: App
    let store: RecordStore
    let clock: EngineClock
    let mode: EngineMode
    let telemetry: any AstrolabeTelemetry
    let wake: Wake
    let facts: FactStore

    private(set) var registry: ResourceRegistry
    var slots = Slots()
    /// Records whose kind isn't registered, or whose snapshot failed to decode. Kept on disk
    /// verbatim and never removed; retried if a declaration registers their kind.
    var undecodable: [String: Record] = [:]
    var opCounter = 0
    /// The facts the engine last logged it was waiting for, so each new set is logged once.
    private var waitingFor: [String] = []
    /// Passes run so far, for tests and telemetry.
    private(set) var passCount = 0
    private(set) var lastPlan = Plan()
    /// Trap in DEBUG on a duplicate id, a kind conflict, or a monitor built outside a pass.
    /// Tests that exercise them turn it off.
    var assertsOnConflicts = true

    /// `resourceTypes` seeds the registry, so records decode at launch: the daemon passes
    /// `ResourceRecords.linkedTypes()`, tests pass the types they mean to know.
    init(
        app: App,
        resourceTypes: [any Resource.Type],
        store: RecordStore,
        clock: any Clock<Duration> = ContinuousClock(),
        mode: EngineMode = .apply,
        telemetry: any AstrolabeTelemetry = NoopAstrolabeTelemetry()
    ) {
        let clock = EngineClock(clock)
        let wake = Wake()
        self.app = app
        self.store = store
        self.clock = clock
        self.mode = mode
        self.telemetry = telemetry
        self.wake = wake
        facts = FactStore(wake: wake, clock: clock, telemetry: telemetry)
        do {
            registry = try ResourceRegistry(resourceTypes)
        } catch {
            fatalError("[Astrolabe] \(error). Every Resource type needs its own kind.")
        }
    }

    /// Runs until the task is cancelled, then cancels every operation in flight, waits up to
    /// `Scheduler.shutdownGrace` for them to end, and returns.
    func run() async {
        load()
        note(
            .info,
            "astrolabe.engine.started",
            TelemetryAttributes.runAttributes(App.self, mode: mode, records: slots.ids.count),
            "engine started (\(mode.rawValue)) with \(slots.ids.count) record(s)"
        )

        while !Task.isCancelled {
            let plan = pass()
            let timer = [plan.nextTimer, Scheduler.nextDeadline(in: slots)].compactMap { $0 }.min()
            await wake.wait(until: timer, clock: clock)
        }

        await shutdown()
        telemetry.log(.info, "astrolabe.engine.stopped")
    }

    /// One pass: synchronous on the main actor, so a fact's value lands either before it, which
    /// sees it, or after it, which wakes the next pass.
    @discardableResult
    func pass() -> Plan {
        passCount += 1
        let (resources, atDefault) = facts.tracking { Flatten.resources(of: app) }

        var plan: Plan
        var declared = 0
        if atDefault.isEmpty {
            waitingFor = []
            var declaration = Declaration(resources)
            reportDuplicates(declaration)
            reportUnobservedMonitors(declaration)
            register(&declaration)
            declared = declaration.items.count
            plan = slots.diff(declaration, now: clock.now())
        } else {
            // `body` saw a default, so the declaration is a placeholder: decide nothing from it,
            // and touch no bookkeeping. Running operations still answer to their deadlines.
            plan = slots.checkDeadlines(now: clock.now())
            plan.waitingFor = atDefault
            reportWaiting(atDefault)
        }
        for id in plan.wedged {
            note(.error, "astrolabe.operation.wedged", wedgedAttributes(id), "\(id) is still running \(Scheduler.cancelGrace) after cancel")
        }
        lastPlan = plan
        telemetry.log(
            .debug,
            "astrolabe.pass",
            attributes: TelemetryAttributes.passAttributes(
                declared: declared,
                actions: plan.actions.count,
                holds: plan.holds.count,
                factsRead: facts.lastRead.count,
                factsWaiting: atDefault.count
            )
        )

        switch mode {
        case .apply: execute(plan)
        case .dryRun: report(plan)
        }
        return plan
    }

    // MARK: - Private

    /// Decodes outside `facts.tracking`, as `promoteUndecodable` does: decoding runs each
    /// `@Monitor`'s initializer, which must not read the facts of a pass.
    private func load() {
        let outcome = store.load(moveAsideCorrupt: mode == .apply)
        if case .reset(let reason, let movedTo) = outcome {
            note(
                .error,
                "astrolabe.records.reset",
                TelemetryAttributes.recordsResetAttributes(reason: reason, movedAside: movedTo != nil),
                "records.json was \(reason); starting empty" + (movedTo.map { " (moved to \($0.path))" } ?? "")
            )
        }
        for (id, record) in store.records.sorted(by: { $0.key < $1.key }) {
            do {
                let resource = try AnyResource.decode(kind: record.kind, record.snapshot, registry: registry)
                slots.load(id, DiskEntry(resource: resource, hash: record.hash))
            } catch {
                undecodable[id] = record
                var attributes = TelemetryAttributes.resourceAttributes(
                    id: id, kind: record.kind, verbose: telemetry.verboseNodeAttributes
                )
                attributes.merge(TelemetryAttributes.errorAttributes(error, verbose: telemetry.verboseNodeAttributes)) { _, new in new }
                note(.warning, "astrolabe.records.undecodable", attributes, "keeping undecodable record \(id) (\(record.kind)): \(error)")
            }
        }
    }

    /// Registers every declared type, freezing ids whose kind another type already claims.
    private func register(_ declaration: inout Declaration) {
        for (id, item) in declaration.items {
            switch registry.register(item.resource.type) {
            case .known:
                break
            case .new:
                promoteUndecodable(kind: item.resource.kind)
            case .conflict(let existing):
                declaration.freeze(id)
                let message = "kind \"\(item.resource.kind)\" of \(item.resource.type) is already claimed by \(existing)"
                note(
                    .error,
                    "astrolabe.declaration.kind_conflict",
                    TelemetryAttributes.resourceAttributes(id: id, kind: item.resource.kind, verbose: telemetry.verboseNodeAttributes),
                    message
                )
                if assertsOnConflicts { assertionFailure(message) }
            }
        }
    }

    /// A declaration registered `kind`: records of it that couldn't be decoded at launch may
    /// decode now. They join as if loaded from disk.
    private func promoteUndecodable(kind: String) {
        for (id, record) in undecodable where record.kind == kind {
            guard slots[id] == nil,
                  let resource = try? AnyResource.decode(kind: kind, record.snapshot, registry: registry)
            else { continue }
            slots.load(id, DiskEntry(resource: resource, hash: record.hash))
            undecodable[id] = nil
        }
    }

    private func reportDuplicates(_ declaration: Declaration) {
        for (id, hashes) in declaration.duplicates.sorted(by: { $0.key < $1.key }) {
            let message = "\(id) is declared \(hashes.count) times, not all alike; leaving it alone this pass"
            note(
                .error,
                "astrolabe.declaration.duplicate_id",
                TelemetryAttributes.duplicateAttributes(id: id, count: hashes.count, verbose: telemetry.verboseNodeAttributes),
                message
            )
            if assertsOnConflicts { assertionFailure(message) }
        }
    }

    /// A resource built outside `body`, such as one stored in a fact's value, read none of its
    /// monitors: the engine never sees it drift.
    private func reportUnobservedMonitors(_ declaration: Declaration) {
        for (id, item) in declaration.items.sorted(by: { $0.key < $1.key }) {
            let names = item.resource.unobservedMonitors
            guard !names.isEmpty else { continue }
            let message = "\(id) was built outside `body`, so its monitors read nothing: \(names.joined(separator: ", "))"
            note(
                .error,
                "astrolabe.declaration.unobserved_monitor",
                TelemetryAttributes.resourceAttributes(id: id, kind: item.resource.kind, verbose: telemetry.verboseNodeAttributes),
                message
            )
            if assertsOnConflicts { assertionFailure(message) }
        }
    }

    private func execute(_ plan: Plan) {
        // No ordering between ids: every due operation starts at once.
        for action in plan.actions {
            switch action {
            case .cancel(let id, let reason): cancel(id, reason)
            case .start(let id, let op): start(id, op)
            }
        }
    }

    /// Logs the facts a waiting pass read before their first value, once per set.
    private func reportWaiting(_ names: [String]) {
        guard names != waitingFor else { return }
        waitingFor = names
        note(
            .info,
            "astrolabe.facts.waiting",
            TelemetryAttributes.factsWaitingAttributes(names),
            "waiting for facts: \(names.joined(separator: ", "))"
        )
    }

    private func report(_ plan: Plan) {
        print(dryRunReport(plan))
    }

    /// What a dry run prints for `plan`.
    func dryRunReport(_ plan: Plan) -> String {
        var lines = ["[Astrolabe] dry run, pass \(passCount):"]
        if !plan.waitingFor.isEmpty {
            lines.append("  waiting for facts: \(plan.waitingFor.joined(separator: ", "))")
        }
        for action in plan.actions {
            switch action {
            case .start(let id, let op):
                // The declared target is what the engine last moved toward: only a monitor moved.
                let monitor = slots[id]?.memory?.target == op.target ? " (monitor)" : ""
                switch op.target {
                case .present(let hash): lines.append("  \(op.kind.rawValue) \(id)@\(hash.prefix(12))\(monitor)")
                case .absent: lines.append("  \(op.kind.rawValue) \(id)")
                }
            case .cancel(let id, let reason):
                lines.append("  cancel \(id) (\(reason.rawValue))")
            }
        }
        for (id, hold) in plan.holds {
            switch hold {
            case .backoff(let attempts):
                lines.append("  retry \(id) after backoff (attempt \(attempts + 1))")
            case .failedWaiting:
                lines.append("  hold \(id): failed under .wait")
            case .waitingForOperation:
                lines.append("  hold \(id): waiting for its operation to end")
            case .frozen:
                lines.append("  hold \(id): frozen this pass")
            }
        }
        if lines.count == 1 { lines.append("  nothing to do") }
        return lines.joined(separator: "\n")
    }

    private func shutdown() async {
        facts.stopAll()
        let deadline = clock.now() + Scheduler.shutdownGrace
        for id in slots.runningIDs {
            cancel(id, .shutdown)
        }
        // A fresh task: this one is cancelled, and the wait has to outlive that.
        let wake = self.wake
        let clock = self.clock
        while !slots.runningIDs.isEmpty, clock.now() < deadline {
            await Task { await wake.wait(until: deadline, clock: clock) }.value
        }
        let abandoned = slots.runningIDs
        if !abandoned.isEmpty {
            note(
                .warning,
                "astrolabe.engine.shutdown_abandoned",
                TelemetryAttributes.shutdownAttributes(abandoned: abandoned.count),
                "exiting with \(abandoned.count) operation(s) still running: \(abandoned.joined(separator: ", "))"
            )
        }
    }

    private func wedgedAttributes(_ id: String) -> [String: TelemetryValue] {
        guard let op = slots[id]?.op else { return [:] }
        return TelemetryAttributes.operationAttributes(
            id: id,
            kind: op.plan.resource.kind,
            operation: op.plan.kind.rawValue,
            attempt: nil,
            verbose: telemetry.verboseNodeAttributes
        )
    }

    /// Logs an event to telemetry and a line to the daemon log.
    func note(_ level: TelemetryLogLevel, _ event: String, _ attributes: [String: TelemetryValue], _ message: String) {
        telemetry.log(level, event, attributes: attributes)
        print("[Astrolabe] \(message)")
    }
}
