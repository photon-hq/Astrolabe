import Foundation
import Testing
@testable import Astrolabe

/// Declares everything in `TestValuesKey`. Never reads `UntrackedKey`.
struct TestApp: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        let _ = test.tracked
        for resource in test.retry { resource }
        for resource in test.rollback { resource }
        for resource in test.wait { resource }
        for resource in test.capped { resource }
    }
}

/// A temporary directory removed when the fixture goes out of scope.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrolabe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var recordsURL: URL { url.appendingPathComponent("records.json") }
}

/// An engine over an app (usually `TestApp`), a `FakeMachine`, `FakeFacts`, a `ManualClock`, and
/// a records file in a temporary directory. The engine knows `resourceTypes` at launch, where
/// the daemon would know every `@Resource` type linked into it.
@MainActor
final class EngineHarness<App: Astrolabe> {
    let machine = FakeMachine()
    /// The facts on the fake Mac. Like `machine`, it outlives a restart.
    let fakeFacts = FakeFacts()
    let clock = ManualClock()
    let telemetry = RecordingTelemetry()
    let recordsURL: URL
    let mode: EngineMode
    let resourceTypes: [any Resource.Type]
    private(set) var app = App()
    private(set) var engine: Engine<App>
    private var runTask: Task<Void, Never>?

    init(recordsURL: URL, mode: EngineMode = .apply, resourceTypes: [any Resource.Type] = fakeResourceTypes) {
        self.recordsURL = recordsURL
        self.mode = mode
        self.resourceTypes = resourceTypes
        engine = Engine(
            app: app, resourceTypes: resourceTypes, store: RecordStore(url: recordsURL),
            clock: clock, mode: mode, telemetry: telemetry
        )
        engine.assertsOnConflicts = false
        fakeFacts.set(TestValuesKey.self, TestValues())
        fakeFacts.set(UntrackedKey.self, 0)
    }

    /// The engine's facts, for `inject`.
    var facts: FactStore { engine.facts }

    /// `TestValuesKey` and `UntrackedKey`, written through to the fake Mac and injected.
    var state: TestState { TestState(fakeFacts: fakeFacts, facts: engine.facts) }

    /// Starts the engine and waits for it to settle. With `injecting`, every value on the fake
    /// Mac is injected first, so the first pass doesn't wait for a read.
    func start(injecting: Bool = true) async {
        if injecting {
            fakeFacts.inject(into: engine.facts)
        }
        let engine = self.engine
        runTask = FakeMachine.$current.withValue(machine) {
            FakeFacts.$current.withValue(fakeFacts) {
                Task { await engine.run() }
            }
        }
        await settle()
    }

    /// Cancels the run, like SIGTERM, and waits for the engine to shut down.
    func stop() async {
        runTask?.cancel()
        // Shutdown waits on the manual clock for up to 10 s; let it through if anything hangs.
        let clock = self.clock
        let nudger = Task {
            while true {
                await realSleep(.milliseconds(20))
                guard !Task.isCancelled else { return }
                clock.advance(by: .seconds(1))
            }
        }
        await runTask?.value
        nudger.cancel()
        await nudger.value
        runTask = nil
    }

    /// Stops the engine and starts a new one — a fresh app and fact store, the same records
    /// file, resource types, machine, facts on the Mac, and clock — like a restart of the daemon.
    func restart(injecting: Bool = true) async {
        await stop()
        app = App()
        engine = Engine(
            app: app, resourceTypes: resourceTypes, store: RecordStore(url: recordsURL),
            clock: clock, mode: mode, telemetry: telemetry
        )
        engine.assertsOnConflicts = false
        await start(injecting: injecting)
    }

    /// Waits until the engine is parked on its wake signal with nothing pending, no fact read is
    /// in flight except held ones, and it stays so.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + .seconds(5)
        var lastPass = -1
        while ContinuousClock.now < deadline {
            await realSleep(.milliseconds(15))
            // One read in flight per fact at most: every one is held when the counts match.
            let quiet = engine.wake.isParked && engine.facts.reading.count == fakeFacts.heldReads
            if engine.passCount == lastPass, quiet { return }
            lastPass = engine.passCount
        }
        Issue.record("engine never settled", sourceLocation: sourceLocation)
    }

    /// Advances the manual clock once the engine has settled, then lets it react.
    func advance(_ duration: Duration) async {
        await settle()
        clock.advance(by: duration)
        await settle()
    }

    /// The record for `id` as it is on disk now.
    func diskRecord(_ id: String) -> Record? {
        let store = RecordStore(url: recordsURL)
        _ = store.load(moveAsideCorrupt: false)
        return store.records[id]
    }

    func logs(_ event: String) -> [RecordingTelemetry.LogRecord] {
        telemetry.logs(named: event)
    }
}

/// Polls `condition` on the main actor until it holds, recording an issue after `timeout`.
@MainActor
func eventually(
    _ description: String = "condition",
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        await realSleep(.milliseconds(1))
    }
}

/// Runs `body` with a started `TestApp` harness over a fresh temporary directory, stopping it
/// after.
@MainActor
func withEngine(
    mode: EngineMode = .apply,
    _ body: (EngineHarness<TestApp>) async throws -> Void
) async throws {
    try await withEngine(TestApp.self, mode: mode, body)
}

/// Runs `body` with a started harness over a fresh temporary directory, stopping it after.
/// `before` runs ahead of `start(injecting:)`, to set up the fake Mac's facts.
@MainActor
func withEngine<App: Astrolabe>(
    _: App.Type,
    mode: EngineMode = .apply,
    resourceTypes: [any Resource.Type] = fakeResourceTypes,
    injecting: Bool = true,
    before: (EngineHarness<App>) -> Void = { _ in },
    _ body: (EngineHarness<App>) async throws -> Void
) async throws {
    let directory = try TemporaryDirectory()
    let harness = EngineHarness<App>(recordsURL: directory.recordsURL, mode: mode, resourceTypes: resourceTypes)
    before(harness)
    await harness.start(injecting: injecting)
    do {
        try await body(harness)
    } catch {
        await harness.stop()
        throw error
    }
    await harness.stop()
    _ = directory.url  // keep the directory until the engine has stopped
}
