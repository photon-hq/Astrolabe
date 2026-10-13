import Foundation
import Testing
@testable import Astrolabe

// An `@FactEntry` fact behaves as the hand-written key it expands to. `EngineFactTests` covers
// the hand-written form.

// MARK: - Fixtures

extension Facts {
    @FactEntry(read: { try await FakeFacts.read("entry", as: [RetryFake].self) })
    fileprivate var entry: [RetryFake] = []

    /// Read every 10 seconds; a read may take 5.
    @FactEntry(schedule: .every(.seconds(10)), timeout: .seconds(5), read: {
        try await FakeFacts.read("polledEntry", as: [RetryFake].self)
    })
    fileprivate var polledEntry: [RetryFake] = []

    /// No initializer: the default is `nil`.
    @FactEntry(read: { try await FakeFacts.read("optionalEntry", as: String?.self) })
    fileprivate var optionalEntry: String?

    fileprivate var entryPair: EntryPair { EntryPair(facts: self) }
}

/// `PairFacts`, declared with `@FactEntry`.
private struct EntryPair: FactNamespace {
    let facts: Facts

    @FactEntry(read: { try await FakeFacts.read("left", as: Bool.self) })
    var left: Bool = false

    @FactEntry(read: { try await FakeFacts.read("right", as: Bool.self) })
    var right: Bool = false

    /// Derived: tracked through both keys, once `left` holds.
    var both: Bool { left && right }
}

/// Reads a macro fact and a hand-written one.
private struct EntryApp: Astrolabe {
    @Fact(\.entry) var entry
    @Fact(\.test) var test

    var body: some Component {
        for resource in entry { resource }
        for resource in test.retry { resource }
    }
}

private struct PolledEntryApp: Astrolabe {
    @Fact(\.polledEntry) var polled

    var body: some Component {
        for resource in polled { resource }
    }
}

private struct OptionalEntryApp: Astrolabe {
    @Fact(\.optionalEntry) var optional

    var body: some Component {
        RetryFake("optional", optional ?? "none")
    }
}

private struct EntryPairApp: Astrolabe {
    @Fact(\.entryPair) var pair

    var body: some Component {
        if pair.both {
            RetryFake("both", "1")
        }
    }
}

@MainActor
private func waitingLogs<App>(_ h: EngineHarness<App>) -> [TelemetryValue?] {
    h.logs("astrolabe.facts.waiting").map { $0.attributes["astrolabe.facts.waiting"] }
}

@MainActor
struct EngineFactEntryTests {
    // MARK: - Tests

    @Test func aMacroFactAtItsDefaultIsWaitedForUnderItsPropertyName() async throws {
        try await withEngine(EntryApp.self, before: { h in
            h.fakeFacts.set("entry", [RetryFake("a", "1")])
            h.fakeFacts.block("entry")
        }) { h in
            #expect(h.engine.lastPlan.waitingFor == ["entry"])
            #expect(h.engine.dryRunReport(h.engine.lastPlan).contains("waiting for facts: entry"))
            #expect(waitingLogs(h) == [.string("entry")])
            #expect(h.machine.calls.isEmpty)

            // The first value wakes a pass that acts on it, next to the hand-written fact's.
            h.state.retry = [RetryFake("b", "1")]
            h.fakeFacts.release("entry")
            await eventually("a and b rolled out") { h.machine.state == ["fake:a": "1", "fake:b": "1"] }
            await h.settle()
            #expect(h.engine.lastPlan.waitingFor.isEmpty)
            #expect(h.fakeFacts.reads("entry") == 1)
        }
    }

    @Test func aMacroFactsScheduleAndTimeoutApply() async throws {
        try await withEngine(PolledEntryApp.self, before: { $0.fakeFacts.set("polledEntry", [RetryFake("a", "1")]) }) { h in
            await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
            await h.settle()
            let passes = h.engine.passCount
            #expect(h.fakeFacts.reads("polledEntry") == 1)

            // Read again every 10 seconds; equal values run no pass.
            for _ in 0..<3 {
                await h.advance(.seconds(10))
            }
            #expect(h.fakeFacts.reads("polledEntry") == 4)
            #expect(h.engine.passCount == passes)

            // A read held past 5 seconds times out and counts as a failure.
            h.fakeFacts.block("polledEntry")
            await h.advance(.seconds(10))
            await h.advance(.seconds(4))
            #expect(h.facts.reading.count == 1)
            #expect(h.logs("astrolabe.fact.read_failed").isEmpty)
            await h.advance(.seconds(1))
            #expect(h.facts.reading.isEmpty)
            let timedOut = try #require(h.logs("astrolabe.fact.read_failed").first)
            #expect(timedOut.attributes["astrolabe.fact.name"] == .string("polledEntry"))
            #expect(timedOut.attributes["astrolabe.error.type"] == .string("FactReadTimedOut"))
            #expect(timedOut.attributes["astrolabe.fact.has_value"] == .bool(true))
            #expect(h.machine.state == ["fake:a": "1"])
            h.fakeFacts.release("polledEntry")
        }
    }

    @Test func aMacroFactInjectsThroughItsKeyPath() async throws {
        try await withEngine(EntryApp.self, before: { $0.fakeFacts.block("entry") }) { h in
            #expect(h.engine.lastPlan.waitingFor == ["entry"])

            h.facts.inject(\.entry, [RetryFake("a", "1")])
            await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
            #expect(h.engine.lastPlan.waitingFor.isEmpty)
            #expect(h.fakeFacts.reads("entry") == 1)
        }
    }

    @Test func aMacroNamespaceTracksADerivedPropertyThroughBothKeys() async throws {
        try await withEngine(EntryPairApp.self, before: { h in
            h.fakeFacts.set("left", true)
            h.fakeFacts.set("right", true)
        }) { h in
            await eventually("both rolled out") { h.machine.state["fake:both"] == "1" }
            await h.settle()
            // `right` is only read once `left` holds, so the passes wait for one, then the other.
            #expect(waitingLogs(h) == [.string("left"), .string("right")])
            #expect(h.facts.lastRead.count == 2)

            h.facts.inject(\.entryPair.right, false)
            await eventually("removed through right") { h.machine.state["fake:both"] == nil }
            h.facts.inject(\.entryPair.right, true)
            await eventually("back") { h.machine.state["fake:both"] == "1" }
            h.facts.inject(\.entryPair.left, false)
            await eventually("removed through left") { h.machine.state["fake:both"] == nil }
            await h.settle()
            // With `left` false, `&&` never reads `right`.
            #expect(h.facts.lastRead.count == 1)
        }
    }

    @Test func aMacroOptionalWithoutAnInitializerIsNilBeforeItsFirstRead() {
        let store = FactStore(wake: Wake(), clock: EngineClock(ContinuousClock()), telemetry: NoopAstrolabeTelemetry())
        store.stopAll()  // evaluates without starting a read
        let (value, atDefault) = store.tracking { Facts(store: store).optionalEntry }
        #expect(value == nil)
        #expect(atDefault == ["optionalEntry"])
    }

    @Test func aMacroOptionalWaitsForItsFirstReadThenNilIsARealValue() async throws {
        try await withEngine(OptionalEntryApp.self, before: { h in
            h.fakeFacts.set("optionalEntry", String?.none)
            h.fakeFacts.block("optionalEntry")
        }) { h in
            #expect(h.engine.lastPlan.waitingFor == ["optionalEntry"])
            #expect(h.machine.calls.isEmpty)

            h.fakeFacts.release("optionalEntry")
            await eventually("declared from a read nil") { h.machine.state["fake:optional"] == "none" }
            h.facts.inject(\.optionalEntry, "x")
            await eventually("x") { h.machine.state["fake:optional"] == "x" }
        }
    }
}
