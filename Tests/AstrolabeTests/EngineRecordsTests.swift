import Foundation
import Testing
@testable import Astrolabe

private typealias Call = FakeMachine.Call

// MARK: - Restarts

@MainActor
@Test func aRestartActsOnNothingUntilItsFactsAreRead() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    await h.start()
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
    await h.settle()

    // While the daemon is down, the Mac's facts move on: a goes, b arrives. The new engine
    // can't read them yet.
    await h.stop()
    h.state.retry = [RetryFake("b", "1")]
    h.fakeFacts.block(TestValuesKey.self)
    await h.restart(injecting: false)
    #expect(h.engine.lastPlan.waitingFor == ["TestValuesKey"])

    // However long the reads take, nothing is rolled out or removed.
    for _ in 0..<10 {
        await h.advance(.seconds(60))
    }
    #expect(h.engine.lastPlan.waitingFor == ["TestValuesKey"])
    #expect(h.engine.lastPlan.actions.isEmpty)
    #expect(h.machine.calls == [Call(op: .rollout, id: "fake:a", value: "1")])
    #expect(h.diskRecord("fake:a") != nil)
    #expect(h.logs("astrolabe.facts.waiting").count == 1)
    #expect(h.logs("astrolabe.fact.read_failed").count == 1)

    // The next read lands: the first acting pass sees the real values.
    h.fakeFacts.release(TestValuesKey.self)
    await h.advance(.seconds(30 * 60))
    await eventually("b in, a out") { h.machine.state == ["fake:b": "1"] }
    await h.settle()
    #expect(h.machine.calls("fake:a") == [
        Call(op: .rollout, id: "fake:a", value: "1"),
        Call(op: .remove, id: "fake:a", value: "1"),
    ])
    #expect(h.machine.calls("fake:b") == [Call(op: .rollout, id: "fake:b", value: "1")])
    #expect(h.diskRecord("fake:a") == nil)
    await h.stop()
}

@MainActor
@Test func aRestartWithTheSameFactsChangesNothing() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    await h.start()
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }

    // The first pass waits for the read, the second sees `a` unchanged.
    await h.restart(injecting: false)
    await eventually("the read landed") { h.engine.lastPlan.waitingFor.isEmpty }
    await h.advance(.seconds(300))
    #expect(h.machine.calls("fake:a").count == 1)
    #expect(h.diskRecord("fake:a") != nil)
    await h.stop()
}

@MainActor
@Test func aDiskRecordWithANewHashRollsOutAfterARestart() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    await h.start()
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a at 1") { h.machine.state["fake:a"] == "1" }

    await h.restart()
    await h.settle()
    #expect(h.machine.calls("fake:a").count == 1)
    h.state.retry = [RetryFake("a", "2")]
    await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
    await h.stop()
}

@MainActor
@Test func undecodableRecordsAreKeptAndNeverRemoved() async throws {
    let directory = try TemporaryDirectory()
    let foreign = Record(kind: "gone.kind", hash: "h", snapshot: .object(["x": .int(1)]))
    try RecordStore(url: directory.recordsURL).set("gone:x", foreign)

    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    await h.start()
    await h.settle()
    #expect(h.logs("astrolabe.records.undecodable").count == 1)

    await h.advance(.seconds(300))
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
    await h.settle()
    #expect(h.machine.calls.map(\.id) == ["fake:a"])
    #expect(h.diskRecord("gone:x") == foreign)
    await h.stop()
}

// MARK: - Records

@MainActor
@Test func memoryMovesAtStartAndDiskOnlyOnSuccess() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a in flight") { h.machine.activeCount("fake:a") == 1 }
        #expect(h.engine.slots["fake:a"]?.memory?.target == .present(hash: RetryFake.compute(RetryFake("a", "1"))))
        #expect(h.diskRecord("fake:a") == nil)

        h.machine.release("fake:a")
        await eventually("a recorded") { h.diskRecord("fake:a") != nil }
    }
}

@MainActor
@Test func aCrashMidRolloutLeavesTheLastSuccessOnDisk() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    await h.start()
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a at 1") { h.machine.state["fake:a"] == "1" }

    h.machine.block("fake:a")
    h.state.retry = [RetryFake("a", "2")]
    await eventually("a2 in flight") { h.machine.activeCount("fake:a") == 1 }

    // Shutdown cancels the rollout; the disk keeps the last success.
    await h.restart()
    #expect(h.machine.endings.last?.ending == .cancelled)
    #expect(h.diskRecord("fake:a")?.hash == RetryFake.compute(RetryFake("a", "1")))

    // The unchanged declaration differs from what's on disk, so it rolls out again.
    h.machine.release("fake:a")
    await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
    await h.stop()
}

@MainActor
@Test func dryRunNeverActsOrWrites() async throws {
    try await withEngine(mode: .dryRun) { h in
        h.state.retry = [RetryFake("a", "1")]
        await h.settle()
        #expect(h.machine.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.recordsURL.path))
        guard case .start(let id, let op)? = h.engine.lastPlan.actions.first else {
            Issue.record("expected a planned rollout")
            return
        }
        #expect(id == "fake:a")
        #expect(op.kind == .rollout)
    }
}

@MainActor
@Test func shutdownAbandonsAnOperationThatIgnoresCancel() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    await h.start()
    h.machine.block("fake:a")
    h.machine.ignoreCancel("fake:a")
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a in flight") { h.machine.activeCount("fake:a") == 1 }

    await h.stop()
    #expect(h.logs("astrolabe.engine.shutdown_abandoned").count == 1)
    h.machine.release("fake:a")
}
