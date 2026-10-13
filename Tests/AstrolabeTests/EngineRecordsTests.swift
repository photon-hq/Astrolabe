import Foundation
import Testing
@testable import Astrolabe

private typealias Call = FakeMachine.Call

// MARK: - Startup grace

@MainActor
@Test func aDiskOnlyRecordIsRemovedOnlyAfterTheGrace() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    h.start()
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }

    // A restart before anything writes state: nothing is declared.
    await h.restart()
    await h.settle()
    #expect(h.engine.lastPlan.holds.map(\.hold) == [.startupGrace])
    await h.advance(.seconds(119))
    #expect(h.machine.calls("fake:a").count == 1)

    await h.advance(.seconds(1))
    await eventually("a removed") { h.machine.state["fake:a"] == nil }
    #expect(h.machine.calls("fake:a").last == Call(op: .remove, id: "fake:a", value: "1"))
    await h.settle()
    #expect(h.diskRecord("fake:a") == nil)
    await h.stop()
}

@MainActor
@Test func redeclaredWithinTheGraceNothingHappens() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    h.start()
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }

    await h.restart()
    await h.advance(.seconds(5))
    h.state.retry = [RetryFake("a", "1")]
    await h.settle()
    await h.advance(.seconds(300))
    #expect(h.machine.calls("fake:a").count == 1)
    #expect(h.diskRecord("fake:a") != nil)
    await h.stop()
}

@MainActor
@Test func aDiskRecordWithANewHashRollsOutAfterARestart() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    h.start()
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a at 1") { h.machine.state["fake:a"] == "1" }

    await h.restart()
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
    h.start()
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
    h.start()
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
    h.state.retry = [RetryFake("a", "2")]
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
    h.start()
    h.machine.block("fake:a")
    h.machine.ignoreCancel("fake:a")
    h.state.retry = [RetryFake("a", "1")]
    await eventually("a in flight") { h.machine.activeCount("fake:a") == 1 }

    await h.stop()
    #expect(h.logs("astrolabe.engine.shutdown_abandoned").count == 1)
    h.machine.release("fake:a")
}
