import Foundation
import Observation
import Testing
@testable import Astrolabe

/// A test-only state object, written directly by the test.
@Observable @MainActor
final class TestState {
    var retry: [RetryFake] = []
    var rollback: [RollbackFake] = []
    var wait: [WaitFake] = []
    var capped: [CappedFake] = []
    /// Read by `body` without affecting what it declares.
    var tracked = 0
    /// Never read by `body`: writing it must not wake the engine.
    var untracked = 0
}

struct TestApp: Astrolabe {
    let state = TestState()

    var body: some Component {
        let _ = state.tracked
        for resource in state.retry { resource }
        for resource in state.rollback { resource }
        for resource in state.wait { resource }
        for resource in state.capped { resource }
    }

    static var resourceTypes: [any Resource.Type] {
        [RetryFake.self, RollbackFake.self, WaitFake.self, CappedFake.self]
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

/// An engine over an app (usually `TestApp`), a `FakeMachine`, a `ManualClock`, and a records
/// file in a temporary directory.
@MainActor
final class EngineHarness<App: Astrolabe> {
    let machine = FakeMachine()
    let clock = ManualClock()
    let telemetry = RecordingTelemetry()
    let recordsURL: URL
    let mode: EngineMode
    private(set) var app = App()
    private(set) var engine: Engine<App>
    private var runTask: Task<Void, Never>?

    init(recordsURL: URL, mode: EngineMode = .apply) {
        self.recordsURL = recordsURL
        self.mode = mode
        engine = Engine(
            app: app, store: RecordStore(url: recordsURL), clock: clock, mode: mode, telemetry: telemetry
        )
        engine.assertsOnConflicts = false
    }

    func start() {
        let engine = self.engine
        runTask = FakeMachine.$current.withValue(machine) {
            Task { await engine.run() }
        }
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

    /// Stops the engine and starts a new one — a fresh app and state, the same records file,
    /// machine, and clock — like a restart of the daemon.
    func restart() async {
        await stop()
        app = App()
        engine = Engine(
            app: app, store: RecordStore(url: recordsURL), clock: clock, mode: mode, telemetry: telemetry
        )
        engine.assertsOnConflicts = false
        start()
    }

    /// Waits until the engine is parked on its wake signal with nothing pending, and stays so.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + .seconds(5)
        var lastPass = -1
        while ContinuousClock.now < deadline {
            await realSleep(.milliseconds(15))
            if engine.passCount == lastPass, engine.wake.isParked { return }
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

extension EngineHarness where App == TestApp {
    var state: TestState { app.state }
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

/// Runs `body` with a started harness over a fresh temporary directory, stopping it after.
@MainActor
func withEngine(
    mode: EngineMode = .apply,
    _ body: (EngineHarness<TestApp>) async throws -> Void
) async throws {
    let directory = try TemporaryDirectory()
    let harness = EngineHarness<TestApp>(recordsURL: directory.recordsURL, mode: mode)
    harness.start()
    do {
        try await body(harness)
    } catch {
        await harness.stop()
        throw error
    }
    await harness.stop()
    _ = directory.url  // keep the directory until the engine has stopped
}
