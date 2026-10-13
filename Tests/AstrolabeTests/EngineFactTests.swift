import Foundation
import Testing
@testable import Astrolabe

private typealias Call = FakeMachine.Call

// MARK: - Fixtures

/// Read by `GateApp` once its gate opens.
private struct GatedKey: FakeFactKey {
    static let defaultValue: [RetryFake] = []
}

/// Read every 10 seconds.
private struct PolledKey: FakeFactKey {
    static let defaultValue: [RetryFake] = []
    static let schedule: FactSchedule = .every(.seconds(10))
}

private struct OptionalKey: FakeFactKey {
    typealias Value = String?
}

private struct LeftKey: FakeFactKey {
    static let defaultValue = false
}

private struct RightKey: FakeFactKey {
    static let defaultValue = false
}

/// A namespace: reads nothing by itself.
private struct PairFacts {
    let facts: Facts
    var left: Bool { facts[LeftKey.self] }
    var right: Bool { facts[RightKey.self] }
    /// Derived: tracked through both keys, once `left` holds.
    var both: Bool { left && right }
}

extension Facts {
    fileprivate var gated: [RetryFake] { self[GatedKey.self] }
    fileprivate var polled: [RetryFake] { self[PolledKey.self] }
    fileprivate var optional: String? { self[OptionalKey.self] }
    fileprivate var pair: PairFacts { PairFacts(facts: self) }
}

/// Declares `test.retry` until `test.tracked > 0` opens the gate, then `gated` in its place:
/// acted on before `gated` is read, its default would remove everything `test.retry` declared.
private struct GateApp: Astrolabe {
    @Fact(\.test) var test
    @Fact(\.gated) var gated

    var body: some Component {
        if test.tracked == 0 {
            for resource in test.retry { resource }
        } else {
            for resource in gated { resource }
        }
        for resource in test.capped { resource }
    }

    static var resourceTypes: [any Resource.Type] { [RetryFake.self, CappedFake.self] }
}

private struct PollApp: Astrolabe {
    @Fact(\.polled) var polled
    @Fact(\.test) var test

    var body: some Component {
        for resource in polled { resource }
        for resource in test.retry { resource }
    }

    static var resourceTypes: [any Resource.Type] { [RetryFake.self] }
}

private struct OptionalApp: Astrolabe {
    @Fact(\.optional) var optional

    var body: some Component {
        RetryFake("optional", optional ?? "none")
    }

    static var resourceTypes: [any Resource.Type] { [RetryFake.self] }
}

private struct PairApp: Astrolabe {
    @Fact(\.pair) var pair

    var body: some Component {
        if pair.both {
            RetryFake("both", "1")
        }
    }

    static var resourceTypes: [any Resource.Type] { [RetryFake.self] }
}

@MainActor
private func waitingLogs<App>(_ h: EngineHarness<App>) -> [TelemetryValue?] {
    h.logs("astrolabe.facts.waiting").map { $0.attributes["astrolabe.facts.waiting"] }
}

// MARK: - Which changes run a pass

@MainActor
@Test func aChangedFactRunsOnePass() async throws {
    try await withEngine { h in
        await h.settle()
        let passes = h.engine.passCount
        h.state.tracked += 1
        await h.settle()
        #expect(h.engine.passCount == passes + 1)
    }
}

@MainActor
@Test func aChangeToAFactNoPassReadRunsNoPass() async throws {
    try await withEngine { h in
        await h.settle()
        let passes = h.engine.passCount
        h.state.untracked += 1
        await h.settle()
        #expect(h.engine.passCount == passes)
    }
}

@MainActor
@Test func aBurstOfChangesRunsOnePass() async throws {
    try await withEngine { h in
        await h.settle()
        let passes = h.engine.passCount
        for _ in 0..<10 { h.state.tracked += 1 }
        h.state.wait = []
        h.state.tracked += 1
        await h.settle()
        #expect(h.engine.passCount == passes + 1)
    }
}

@MainActor
@Test func anEqualValueRunsNoPass() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()
        let passes = h.engine.passCount
        h.state.retry = [RetryFake("a", "1")]
        h.state.tracked = h.state.tracked
        await h.settle()
        #expect(h.engine.passCount == passes)
    }
}

@MainActor
@Test func anOperationEndingRunsAPass() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a in flight") { h.machine.activeCount("fake:a") == 1 }
        await h.settle()
        let passes = h.engine.passCount
        h.machine.release("fake:a")
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()
        #expect(h.engine.passCount == passes + 1)
    }
}

@MainActor
@Test func aPollThatReadsEqualValuesRunsNoPasses() async throws {
    try await withEngine(PollApp.self, before: { $0.fakeFacts.set(PolledKey.self, [RetryFake("a", "1")]) }) { h in
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()
        let passes = h.engine.passCount
        let reads = h.fakeFacts.reads(PolledKey.self)

        for _ in 0..<5 {
            await h.advance(.seconds(10))
        }
        #expect(h.fakeFacts.reads(PolledKey.self) == reads + 5)
        #expect(h.engine.passCount == passes)
    }
}

@MainActor
@Test func anOperationEndingNeverTriggersARead() async throws {
    try await withEngine(PollApp.self, before: { $0.fakeFacts.set(PolledKey.self, []) }) { h in
        let polled = h.fakeFacts.reads(PolledKey.self)
        let test = h.fakeFacts.reads(TestValuesKey.self)

        h.machine.fail("fake:a")
        h.state.retry = [RetryFake("a", "1"), RetryFake("b", "1")]
        await eventually("a failed, b rolled out") {
            h.engine.slots["fake:a"]?.failure != nil && h.machine.state["fake:b"] == "1"
        }
        await h.settle()
        #expect(h.fakeFacts.reads(PolledKey.self) == polled)
        #expect(h.fakeFacts.reads(TestValuesKey.self) == test)
    }
}

// MARK: - Waiting for a first value

@MainActor
@Test func aPassThatReadsADefaultActsOnNothingAndTouchesNoBookkeeping() async throws {
    try await withEngine(GateApp.self) { h in
        h.machine.fail("fake:b")
        h.state.retry = [RetryFake("a", "1"), RetryFake("b", "1")]
        await eventually("a rolled out, b failed") {
            h.machine.state["fake:a"] == "1" && h.engine.slots["fake:b"]?.failure != nil
        }
        await h.settle()

        // The gate opens onto `gated`, never read before. Acted on, its default would remove a,
        // and the diff would drop b's failure.
        h.fakeFacts.set(GatedKey.self, [RetryFake("a", "1")])
        h.fakeFacts.block(GatedKey.self)
        h.state.tracked = 1
        await h.settle()
        #expect(h.engine.lastPlan.waitingFor == ["GatedKey"])
        #expect(h.engine.lastPlan.actions.isEmpty)
        #expect(h.engine.lastPlan.holds.isEmpty)
        #expect(h.engine.slots["fake:b"]?.failure?.attempts == 1)
        #expect(h.engine.slots["fake:a"]?.disk != nil)

        // b's retry comes due, and a pass runs: it still decides nothing.
        await h.advance(.seconds(15))
        let passes = h.engine.passCount
        h.state.tracked = 2
        await h.settle()
        #expect(h.engine.passCount == passes + 1)
        #expect(h.engine.lastPlan.waitingFor == ["GatedKey"])
        #expect(h.machine.calls.count == 2)

        // The first value wakes a pass that acts: a is still declared, b no longer is.
        h.fakeFacts.release(GatedKey.self)
        await eventually("b removed") { h.machine.calls("fake:b").map(\.op) == [.rollout, .remove] }
        await h.settle()
        #expect(h.engine.lastPlan.waitingFor.isEmpty)
        #expect(h.machine.calls("fake:a") == [Call(op: .rollout, id: "fake:a", value: "1")])
        #expect(h.engine.slots["fake:b"] == nil)
        #expect(waitingLogs(h) == [.string("GatedKey")])
    }
}

@MainActor
@Test func eachFactAGateReachesIsWaitedFor() async throws {
    try await withEngine(GateApp.self, injecting: false, before: { h in
        h.fakeFacts.set(TestValuesKey.self, TestValues(retry: [RetryFake("a", "1")]))
    }) { h in
        // The first pass waited for `test`; the second rolled out what it declared.
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        #expect(waitingLogs(h) == [.string("TestValuesKey")])

        h.fakeFacts.set(GatedKey.self, [RetryFake("g", "1")])
        h.state.tracked = 1
        await eventually("g in, a out") { h.machine.state == ["fake:g": "1"] }
        await h.settle()
        #expect(waitingLogs(h) == [.string("TestValuesKey"), .string("GatedKey")])
        // Nothing acted on `gated`'s empty default.
        #expect(h.machine.calls("fake:g") == [Call(op: .rollout, id: "fake:g", value: "1")])
    }
}

@MainActor
@Test func aWaitingPassStillTimesOutARunningOperation() async throws {
    try await withEngine(GateApp.self) { h in
        h.machine.block("fake:c")
        h.state.capped = [CappedFake("c", "1")]
        await eventually("c in flight") { h.machine.activeCount("fake:c") == 1 }

        h.fakeFacts.set(GatedKey.self, [])
        h.fakeFacts.block(GatedKey.self)
        h.state.tracked = 1
        await h.settle()
        #expect(h.engine.lastPlan.waitingFor == ["GatedKey"])

        await h.advance(.seconds(60))
        await eventually("c cancelled") { h.machine.activeCount("fake:c") == 0 }
        await h.settle()
        #expect(h.logs("astrolabe.operation.timed_out").count == 1)
        #expect(h.machine.endings.map(\.ending) == [.cancelled])
        // Its retry waits for a pass that reads real facts.
        #expect(h.engine.slots["fake:c"]?.failure != nil)
        #expect(h.engine.lastPlan.waitingFor == ["GatedKey"])
        #expect(h.machine.calls("fake:c").count == 1)
        h.fakeFacts.release(GatedKey.self)
    }
}

@MainActor
@Test func aFactThatFailsFromTheStartKeepsPassesWaitingAndRetriesWithBackoff() async throws {
    try await withEngine(TestApp.self, injecting: false, before: { h in
        h.fakeFacts.set(TestValuesKey.self, TestValues(retry: [RetryFake("a", "1")]))
        h.fakeFacts.fail(TestValuesKey.self, times: 3)
    }) { h in
        #expect(h.fakeFacts.reads(TestValuesKey.self) == 1)
        #expect(h.engine.lastPlan.waitingFor == ["TestValuesKey"])
        let failed = try #require(h.logs("astrolabe.fact.read_failed").first)
        #expect(failed.attributes["astrolabe.fact.name"] == .string("TestValuesKey"))
        #expect(failed.attributes["astrolabe.fact.has_value"] == .bool(false))

        // 15 seconds, then 30, then 60.
        await h.advance(.seconds(14))
        #expect(h.fakeFacts.reads(TestValuesKey.self) == 1)
        await h.advance(.seconds(1))
        #expect(h.fakeFacts.reads(TestValuesKey.self) == 2)
        await h.advance(.seconds(29))
        #expect(h.fakeFacts.reads(TestValuesKey.self) == 2)
        await h.advance(.seconds(1))
        #expect(h.fakeFacts.reads(TestValuesKey.self) == 3)
        #expect(h.machine.calls.isEmpty)
        #expect(h.engine.lastPlan.waitingFor == ["TestValuesKey"])

        await h.advance(.seconds(60))
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        #expect(h.fakeFacts.reads(TestValuesKey.self) == 4)
        // Only the first failure in a row is logged.
        #expect(h.logs("astrolabe.fact.read_failed").count == 1)
        #expect(h.logs("astrolabe.facts.waiting").count == 1)
    }
}

@MainActor
@Test func afterTheFirstValueAFailedOrTimedOutReadKeepsTheLastValue() async throws {
    try await withEngine(PollApp.self, before: { $0.fakeFacts.set(PolledKey.self, [RetryFake("a", "1")]) }) { h in
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        // A read that throws.
        h.fakeFacts.fail(PolledKey.self)
        await h.advance(.seconds(10))
        #expect(h.fakeFacts.reads(PolledKey.self) == 2)
        #expect(h.logs("astrolabe.fact.read_failed").count == 1)
        #expect(h.logs("astrolabe.fact.read_failed").first?.attributes["astrolabe.fact.has_value"] == .bool(true))

        // The next read, `min(10 s, backoff)` later, succeeds and ends the run of failures.
        await h.advance(.seconds(10))
        #expect(h.fakeFacts.reads(PolledKey.self) == 3)

        // A read that hangs past its timeout.
        h.fakeFacts.block(PolledKey.self)
        await h.advance(.seconds(10))
        #expect(h.facts.reading.contains(ObjectIdentifier(PolledKey.self)))
        await h.advance(.seconds(30))
        #expect(!h.facts.reading.contains(ObjectIdentifier(PolledKey.self)))
        let timedOut = try #require(h.logs("astrolabe.fact.read_failed").last)
        #expect(timedOut.attributes["astrolabe.error.type"] == .string("FactReadTimedOut"))
        #expect(h.logs("astrolabe.fact.read_failed").count == 2)

        // Neither changed what's declared.
        #expect(h.machine.calls == [Call(op: .rollout, id: "fake:a", value: "1")])
        #expect(h.engine.lastPlan.waitingFor.isEmpty)

        // A later read brings a new value.
        h.fakeFacts.release(PolledKey.self)
        h.fakeFacts.set(PolledKey.self, [RetryFake("a", "2")])
        await h.advance(.seconds(10))
        await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
    }
}

@MainActor
@Test func aHangingReadDoesNotDelayPassesForOtherFacts() async throws {
    try await withEngine(PollApp.self, before: { $0.fakeFacts.set(PolledKey.self, [RetryFake("a", "1")]) }) { h in
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        h.fakeFacts.block(PolledKey.self)
        await h.advance(.seconds(10))
        #expect(h.facts.reading.contains(ObjectIdentifier(PolledKey.self)))

        h.state.retry = [RetryFake("b", "1")]
        await eventually("b rolled out") { h.machine.state["fake:b"] == "1" }
        #expect(h.facts.reading.contains(ObjectIdentifier(PolledKey.self)))
        #expect(h.machine.state["fake:a"] == "1")
        h.fakeFacts.release(PolledKey.self)
    }
}

@MainActor
@Test func shutdownWhileWaitingExitsCleanly() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    h.fakeFacts.block(TestValuesKey.self)
    await h.start(injecting: false)
    #expect(h.engine.lastPlan.waitingFor == ["TestValuesKey"])

    await h.stop()
    #expect(h.logs("astrolabe.engine.stopped").count == 1)
    #expect(h.logs("astrolabe.engine.shutdown_abandoned").isEmpty)
    // A read cancelled at shutdown is not a failure.
    #expect(h.logs("astrolabe.fact.read_failed").isEmpty)
    h.fakeFacts.release(TestValuesKey.self)
}

@MainActor
@Test func aDryRunPrintsTheFactsItWaitsForThenTheDiff() async throws {
    try await withEngine(TestApp.self, mode: .dryRun, injecting: false, before: { h in
        h.fakeFacts.set(TestValuesKey.self, TestValues(retry: [RetryFake("a", "1")]))
        h.fakeFacts.block(TestValuesKey.self)
    }) { h in
        let waiting = h.engine.dryRunReport(h.engine.lastPlan)
        #expect(waiting.contains("waiting for facts: TestValuesKey"))
        #expect(!waiting.contains("rollout"))

        h.fakeFacts.release(TestValuesKey.self)
        await eventually("the read landed") { h.engine.lastPlan.waitingFor.isEmpty }
        let diff = h.engine.dryRunReport(h.engine.lastPlan)
        #expect(diff.contains("rollout fake:a@"))
        #expect(!diff.contains("waiting"))
        #expect(h.machine.calls.isEmpty)
    }
}

// MARK: - Keys

@Test func anOptionalFactDefaultsToNil() {
    #expect(OptionalKey.defaultValue == nil)
    #expect(OptionalKey.schedule == .once)
    #expect(OptionalKey.timeout == .seconds(30))
}

@MainActor
@Test func anOptionalFactWaitsForItsFirstReadThenNilIsARealValue() async throws {
    try await withEngine(OptionalApp.self, injecting: false, before: { h in
        h.fakeFacts.set(OptionalKey.self, nil)
        h.fakeFacts.block(OptionalKey.self)
    }) { h in
        // Its default is `nil`, yet a pass that reads it before the first read waits.
        #expect(h.engine.lastPlan.waitingFor == ["OptionalKey"])
        #expect(h.machine.calls.isEmpty)

        h.fakeFacts.release(OptionalKey.self)
        await eventually("declared from a read nil") { h.machine.state["fake:optional"] == "none" }
        h.facts.inject(\.optional, "x")
        await eventually("x") { h.machine.state["fake:optional"] == "x" }
        h.facts.inject(\.optional, nil)
        await eventually("none again") { h.machine.state["fake:optional"] == "none" }
    }
}

@MainActor
@Test func aDerivedPropertyIsTrackedThroughBothKeys() async throws {
    try await withEngine(PairApp.self, before: { h in
        h.fakeFacts.set(LeftKey.self, true)
        h.fakeFacts.set(RightKey.self, true)
    }) { h in
        await eventually("both rolled out") { h.machine.state["fake:both"] == "1" }
        await h.settle()
        #expect(h.facts.lastRead == [ObjectIdentifier(LeftKey.self), ObjectIdentifier(RightKey.self)])

        h.facts.inject(\.pair.right, false)
        await eventually("removed through right") { h.machine.state["fake:both"] == nil }
        h.facts.inject(\.pair.right, true)
        await eventually("back") { h.machine.state["fake:both"] == "1" }
        h.facts.inject(\.pair.left, false)
        await eventually("removed through left") { h.machine.state["fake:both"] == nil }
        await h.settle()
        // With `left` false, `&&` never reads `right`.
        #expect(h.facts.lastRead == [ObjectIdentifier(LeftKey.self)])
    }
}

// MARK: - Traps

/// Exit tests run the trap in a child process. On some beta macOS builds a trapping process never
/// exits, and each exit test blocks a cooperative thread until it does, stalling the whole run:
/// opt in with `ASTROLABE_EXIT_TESTS=1`.
private let exitTestsEnabled = ProcessInfo.processInfo.environment["ASTROLABE_EXIT_TESTS"] != nil

@Test(.enabled(if: exitTestsEnabled, "set ASTROLABE_EXIT_TESTS=1"))
func injectingAKeyPathThatReadsTwoKeysTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            let store = FactStore(
                wake: Wake(), clock: EngineClock(ContinuousClock()), telemetry: NoopAstrolabeTelemetry()
            )
            // Short-circuits on `left`'s default, then reads both once `left` is set.
            store.inject(\.pair.both, true)
        }
    }
}

@Test(.enabled(if: exitTestsEnabled, "set ASTROLABE_EXIT_TESTS=1"))
func readingAFactOutsideAPassTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            _ = PairApp().pair.left
        }
    }
}
