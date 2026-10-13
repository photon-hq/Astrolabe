import Foundation
import Testing
@testable import Astrolabe

private typealias Call = FakeMachine.Call

@MainActor
@Test func sameHashMidRolloutKeepsItRunning() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a in flight") { h.machine.activeCount("fake:a") == 1 }
        await h.settle()

        // A write mid-rollout runs a pass, but `a`'s hash is unchanged.
        let passes = h.engine.passCount
        h.state.retry = [RetryFake("a", "1"), RetryFake("b", "1")]
        await eventually("b rolled out") { h.machine.state["fake:b"] == "1" }
        #expect(h.engine.passCount > passes)
        #expect(h.machine.activeCount("fake:a") == 1)
        #expect(h.machine.calls("fake:a").count == 1)

        h.machine.release("fake:a")
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        #expect(h.machine.endings.filter { $0.call.id == "fake:a" }.map(\.ending) == [.returned])
    }
}

@MainActor
@Test func newHashMidRolloutCancelsThenRestartsAfterTheOldTaskEnds() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a1 in flight") { h.machine.activeCount("fake:a") == 1 }

        h.state.retry = [RetryFake("a", "2")]
        await eventually("a2 started") { h.machine.calls("fake:a").count == 2 }
        #expect(h.machine.endings.first.map { [$0.call.value: $0.ending] } == ["1": .cancelled])
        #expect(h.machine.maxActivePerID == 1)

        h.machine.release("fake:a")
        await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
        await h.settle()
        #expect(h.diskRecord("fake:a")?.hash == RetryFake.compute(RetryFake("a", "2")))
        // Cancellation is not failure.
        #expect(h.logs("astrolabe.operation.failed").isEmpty)
        #expect(h.engine.slots["fake:a"]?.failure == nil)
    }
}

@MainActor
@Test func leavingMidRolloutCancelsThenRemovesTheMemorySnapshot() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a1 in flight") { h.machine.activeCount("fake:a") == 1 }

        h.state.retry = []
        await eventually("removal started") { h.machine.calls("fake:a").count == 2 }
        #expect(h.machine.calls("fake:a") == [
            Call(op: .rollout, id: "fake:a", value: "1"),
            Call(op: .remove, id: "fake:a", value: "1"),
        ])
        h.machine.release("fake:a")
        await eventually("removal returned") { h.machine.activeTotal == 0 }
        await h.settle()
        #expect(h.machine.endings.map(\.ending) == [.cancelled, .returned])
        #expect(h.engine.slots["fake:a"] == nil)
        #expect(h.machine.maxActivePerID == 1)
    }
}

@MainActor
@Test func redeclaringMidRemovalRollsOut() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        h.machine.block("fake:a")
        h.state.retry = []
        await eventually("removal in flight") { h.machine.activeCount("fake:a") == 1 }

        h.state.retry = [RetryFake("a", "1")]
        await eventually("rollout started again") { h.machine.calls("fake:a").count == 3 }
        h.machine.release("fake:a")
        await eventually("rollout returned") { h.machine.activeTotal == 0 && h.machine.endings.count == 3 }
        await h.settle()
        #expect(h.machine.calls("fake:a").map(\.op) == [.rollout, .remove, .rollout])
        #expect(h.machine.endings.map(\.ending) == [.returned, .cancelled, .returned])
        #expect(h.machine.state["fake:a"] == "1")
        #expect(h.diskRecord("fake:a")?.hash == RetryFake.compute(RetryFake("a", "1")))
    }
}

@MainActor
@Test func flippingBackDuringTheReplacementRolloutRepairs() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a1 in flight") { h.machine.activeCount("fake:a") == 1 }
        h.state.retry = [RetryFake("a", "2")]
        await eventually("a2 in flight") { h.machine.calls("fake:a").count == 2 && h.machine.activeCount("fake:a") == 1 }

        // Memory says 2, the declaration says 1 again: a difference, so 1 rolls out.
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a1 started again") { h.machine.calls("fake:a").count == 3 }
        h.machine.release("fake:a")
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
        await h.settle()
        #expect(h.machine.calls("fake:a").map(\.value) == ["1", "2", "1"])
        #expect(h.diskRecord("fake:a")?.hash == RetryFake.compute(RetryFake("a", "1")))
    }
}

@MainActor
@Test func flippingBackBeforeTheCancelLandsStillRollsOutAgain() async throws {
    try await withEngine { h in
        // A slow-to-cancel rollout: it keeps running through the cancel until released.
        h.machine.block("fake:a")
        h.machine.ignoreCancel("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a1 in flight") { h.machine.activeCount("fake:a") == 1 }

        h.state.retry = [RetryFake("a", "2")]
        await h.settle()
        h.state.retry = [RetryFake("a", "1")]
        await h.settle()
        // Still the first, cancelled task: nothing new starts until it ends.
        #expect(h.machine.calls("fake:a").count == 1)

        // It ends cancelled, so 1 was never reached: the engine rolls it out again.
        h.machine.release("fake:a")
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
        #expect(h.machine.calls("fake:a").map(\.value) == ["1", "1"])
        #expect(h.machine.endings.map(\.ending) == [.cancelled, .returned])
    }
}

@MainActor
@Test func neverTwoOperationsPerID() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        for value in ["1", "2", "3", "4"] {
            h.state.retry = [RetryFake("a", value)]
            await realSleep(.milliseconds(5))
        }
        h.state.retry = []
        await h.settle()
        h.state.retry = [RetryFake("a", "5")]
        await h.settle()
        h.machine.release("fake:a")
        await eventually("a at 5") { h.machine.state["fake:a"] == "5" }
        #expect(h.machine.maxActivePerID == 1)
    }
}
