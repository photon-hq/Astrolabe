import Foundation
import Observation

/// Whether the engine acts on its plan.
enum EngineMode: String, Sendable {
    case apply
    /// Print the diff each pass. Never start an operation, never write records.
    case dryRun = "dry_run"
}

/// The state engine.
///
/// State is the only thing that drives it. Each pass evaluates `app.body` inside observation
/// tracking, turns it into a declaration (`[id@hash]`), and diffs that against what it last moved
/// toward, id by id. Then it starts and cancels operations so the Mac matches, and waits for the
/// next wake: a tracked state write, an operation ending, or a timer.
///
/// There is no arrow from the Mac back to state. The engine never reads or refreshes state;
/// rollouts never write it; `body` never reads records.
@MainActor
final class Engine<App: Astrolabe> {
    let app: App
    let store: RecordStore
    let clock: EngineClock
    let mode: EngineMode
    let telemetry: any AstrolabeTelemetry
    let wake = Wake()

    private(set) var registry: ResourceRegistry
    var slots = Slots()
    /// Records whose kind isn't registered, or whose snapshot failed to decode. Kept on disk
    /// verbatim and never removed; retried if a declaration registers their kind.
    var undecodable: [String: Record] = [:]
    var opCounter = 0
    /// When records loaded from disk may be removed if still undeclared.
    private(set) var graceEnd: Duration = .zero
    /// Passes run so far, for tests and telemetry.
    private(set) var passCount = 0
    private(set) var lastPlan = Plan()
    /// Trap in DEBUG on a duplicate id or a kind conflict. Tests that exercise them turn it off.
    var assertsOnConflicts = true

    init(
        app: App,
        store: RecordStore,
        clock: any Clock<Duration> = ContinuousClock(),
        mode: EngineMode = .apply,
        telemetry: any AstrolabeTelemetry = NoopAstrolabeTelemetry()
    ) {
        self.app = app
        self.store = store
        self.clock = EngineClock(clock)
        self.mode = mode
        self.telemetry = telemetry
        do {
            registry = try ResourceRegistry(App.resourceTypes)
        } catch {
            fatalError("[Astrolabe] \(error). Every Resource type needs its own kind.")
        }
    }

    /// Runs until the task is cancelled, then cancels every operation in flight, waits up to
    /// `Scheduler.shutdownGrace` for them to end, and returns.
    func run() async {
        load()
        graceEnd = clock.now() + App.removalGrace
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

    /// One pass: synchronous on the main actor, so no state write can land between reading a
    /// value and registering for its changes.
    @discardableResult
    func pass() -> Plan {
        passCount += 1
        var declaration = withObservationTracking {
            Declaration(Flatten.resources(of: app))
        } onChange: { [wake] in
            // Runs in the writer's willSet: only signal.
            wake.signal()
        }
        reportDuplicates(declaration)
        register(&declaration)

        let plan = slots.diff(declaration, now: clock.now(), graceEnd: graceEnd)
        for id in plan.wedged {
            note(.error, "astrolabe.operation.wedged", wedgedAttributes(id), "\(id) is still running \(Scheduler.cancelGrace) after cancel")
        }
        lastPlan = plan
        telemetry.log(
            .debug,
            "astrolabe.pass",
            attributes: TelemetryAttributes.passAttributes(
                declared: declaration.items.count,
                actions: plan.actions.count,
                holds: plan.holds.count
            )
        )

        switch mode {
        case .apply: execute(plan)
        case .dryRun: report(plan)
        }
        return plan
    }

    // MARK: - Private

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
            let message = "\(id) is declared \(hashes.count) times with different hashes; leaving it alone this pass"
            note(
                .error,
                "astrolabe.declaration.duplicate_id",
                TelemetryAttributes.duplicateAttributes(id: id, count: hashes.count, verbose: telemetry.verboseNodeAttributes),
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

    private func report(_ plan: Plan) {
        var lines = ["[Astrolabe] dry run, pass \(passCount):"]
        for action in plan.actions {
            switch action {
            case .start(let id, let op):
                switch op.target {
                case .present(let hash): lines.append("  \(op.kind.rawValue) \(id)@\(hash.prefix(12))")
                case .absent: lines.append("  \(op.kind.rawValue) \(id)")
                }
            case .cancel(let id, let reason):
                lines.append("  cancel \(id) (\(reason.rawValue))")
            }
        }
        let now = clock.now()
        for (id, hold) in plan.holds {
            switch hold {
            case .startupGrace:
                lines.append("  remove \(id) after the startup grace (in \(graceEnd - now))")
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
        print(lines.joined(separator: "\n"))
    }

    private func shutdown() async {
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
