import Foundation
import Testing
@testable import Astrolabe

private typealias Call = FakeMachine.Call

@MainActor
@Test func retryLeavesTheMacAndRetriesAfterBackoff() async throws {
    try await withEngine { h in
        h.machine.fail("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a failed") { h.engine.slots["fake:a"]?.failure != nil }
        await h.settle()
        #expect(h.machine.calls("fake:a") == [Call(op: .rollout, id: "fake:a", value: "1")])
        #expect(h.diskRecord("fake:a") == nil)
        #expect(h.logs("astrolabe.operation.failed").count == 1)

        await h.advance(.seconds(14))
        #expect(h.machine.calls("fake:a").count == 1)

        await h.advance(.seconds(1))
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        #expect(h.machine.calls("fake:a").map(\.op) == [.rollout, .rollout])
        await h.settle()
        #expect(h.engine.slots["fake:a"]?.failure == nil)
    }
}

@MainActor
@Test func retryBacksOffExponentially() async throws {
    try await withEngine { h in
        h.machine.fail("fake:a", times: 3)
        h.state.retry = [RetryFake("a", "1")]
        await eventually("first failure") { h.engine.slots["fake:a"]?.failure?.attempts == 1 }

        await h.advance(.seconds(15))
        await eventually("second failure") { h.engine.slots["fake:a"]?.failure?.attempts == 2 }
        await h.advance(.seconds(29))
        #expect(h.machine.calls("fake:a").count == 2)
        await h.advance(.seconds(1))
        await eventually("third failure") { h.engine.slots["fake:a"]?.failure?.attempts == 3 }
        await h.advance(.seconds(60))
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        #expect(h.machine.calls("fake:a").count == 4)
    }
}

@MainActor
@Test func rollbackRestoresTheDiskSnapshotThenRetries() async throws {
    try await withEngine { h in
        h.state.rollback = [RollbackFake("a", "1")]
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        h.machine.fail("fake:a")
        h.state.rollback = [RollbackFake("a", "2")]
        await eventually("rolled back") { h.machine.calls("fake:a").count == 3 }
        await h.settle()
        #expect(h.machine.calls("fake:a").map(\.value) == ["1", "2", "1"])
        #expect(h.machine.state["fake:a"] == "1")
        #expect(h.diskRecord("fake:a")?.hash == RollbackFake.compute(RollbackFake("a", "1")))

        // The retry is due a backoff after the rollback ended.
        await h.advance(.seconds(14))
        #expect(h.machine.calls("fake:a").count == 3)
        await h.advance(.seconds(1))
        await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
        #expect(h.machine.calls("fake:a").map(\.value) == ["1", "2", "1", "2"])
    }
}

@MainActor
@Test func rollbackWithNothingOnDiskRemovesTheFailedSnapshot() async throws {
    try await withEngine { h in
        h.machine.fail("fake:a")
        h.state.rollback = [RollbackFake("a", "1")]
        await eventually("failed snapshot removed") { h.machine.calls("fake:a").count == 2 }
        await h.settle()
        #expect(h.machine.calls("fake:a") == [
            Call(op: .rollout, id: "fake:a", value: "1"),
            Call(op: .remove, id: "fake:a", value: "1"),
        ])
        #expect(h.diskRecord("fake:a") == nil)

        await h.advance(.seconds(15))
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
        await h.settle()
        #expect(h.engine.slots["fake:a"]?.failure == nil)
    }
}

@MainActor
@Test func failedRemovalUnderRollbackRollsTheDiskSnapshotBackOut() async throws {
    try await withEngine { h in
        h.state.rollback = [RollbackFake("a", "1")]
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        h.machine.fail("fake:a")
        h.state.rollback = []
        await eventually("rolled back out") { h.machine.calls("fake:a").count == 3 }
        await h.settle()
        #expect(h.machine.calls("fake:a").map(\.op) == [.rollout, .remove, .rollout])
        #expect(h.diskRecord("fake:a") != nil)

        await h.advance(.seconds(15))
        await eventually("a removed") { h.machine.state["fake:a"] == nil && h.machine.calls("fake:a").count == 4 }
        await h.settle()
        #expect(h.diskRecord("fake:a") == nil)
    }
}

@MainActor
@Test func failedRollbackIsLoggedAndNotRolledBackAgain() async throws {
    try await withEngine { h in
        h.state.rollback = [RollbackFake("a", "1")]
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        h.machine.fail("fake:a", times: 2)
        h.state.rollback = [RollbackFake("a", "2")]
        await eventually("rollback failed") { h.logs("astrolabe.rollback.failed").count == 1 }
        await h.settle()
        #expect(h.machine.calls("fake:a").map(\.value) == ["1", "2", "1"])

        // The target still retries after its backoff.
        await h.advance(.seconds(15))
        await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
        #expect(h.machine.calls("fake:a").map(\.value) == ["1", "2", "1", "2"])
        #expect(h.logs("astrolabe.rollback.failed").count == 1)
    }
}

@MainActor
@Test func waitNeverRetriesUntilTheHashChanges() async throws {
    try await withEngine { h in
        h.machine.fail("fake:a")
        h.state.wait = [WaitFake("a", "1")]
        await eventually("a failed") { h.engine.slots["fake:a"]?.failure != nil }

        await h.advance(.seconds(3600))
        #expect(h.machine.calls("fake:a").count == 1)
        #expect(h.engine.lastPlan.holds.map(\.hold) == [.failedWaiting])

        h.state.wait = [WaitFake("a", "2")]
        await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
        #expect(h.machine.calls("fake:a").map(\.value) == ["1", "2"])
    }
}

@MainActor
@Test func waitRetriesAfterARestart() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<TestApp>(recordsURL: directory.recordsURL)
    h.start()
    h.machine.fail("fake:a")
    h.state.wait = [WaitFake("a", "1")]
    await eventually("a failed") { h.engine.slots["fake:a"]?.failure != nil }

    await h.restart()
    h.state.wait = [WaitFake("a", "1")]
    await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
    await h.stop()
}

@MainActor
@Test func cancellationNeverTriggersThePolicy() async throws {
    try await withEngine { h in
        h.state.rollback = [RollbackFake("a", "1")]
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        h.machine.block("fake:a")
        h.state.rollback = [RollbackFake("a", "2")]
        await eventually("a2 in flight") { h.machine.activeCount("fake:a") == 1 }
        h.state.rollback = [RollbackFake("a", "3")]
        await eventually("a3 started") { h.machine.calls("fake:a").count == 3 }
        h.machine.release("fake:a")
        await eventually("a at 3") { h.machine.state["fake:a"] == "3" }
        await h.settle()
        #expect(h.machine.calls("fake:a").map(\.value) == ["1", "2", "3"])
        #expect(h.logs("astrolabe.operation.failed").isEmpty)
    }
}

@MainActor
@Test func aNewTargetStartsAgainAtAttemptOne() async throws {
    try await withEngine { h in
        h.machine.fail("fake:a", times: 3)
        h.state.retry = [RetryFake("a", "1")]
        await eventually("first failure") { h.engine.slots["fake:a"]?.failure?.attempts == 1 }
        await h.advance(.seconds(15))
        await eventually("second failure") { h.engine.slots["fake:a"]?.failure?.attempts == 2 }

        // No waiting on the old target's backoff: the new one is due at once.
        h.state.retry = [RetryFake("a", "2")]
        await eventually("a2 attempted") { h.machine.calls("fake:a").count == 3 }
        await h.settle()
        let failure = try #require(h.engine.slots["fake:a"]?.failure)
        #expect(failure.attempts == 1)
        #expect(failure.target == .present(hash: RetryFake.compute(RetryFake("a", "2"))))
    }
}

@MainActor
@Test func anOperationPastItsCapIsCancelledAndFails() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.state.capped = [CappedFake("a", "1")]
        await eventually("a in flight") { h.machine.activeCount("fake:a") == 1 }

        await h.advance(.seconds(60))
        await eventually("a failed") { h.engine.slots["fake:a"]?.failure != nil }
        #expect(h.logs("astrolabe.operation.timed_out").count == 1)
        let failed = try #require(h.logs("astrolabe.operation.failed").first)
        #expect(failed.attributes["astrolabe.error.type"] == .string("OperationTimedOut"))

        h.machine.release("fake:a")
        await h.advance(.seconds(15))
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
    }
}
