import Foundation
import Testing
@testable import Astrolabe

@MainActor
@Test func dueOperationsForDifferentIdsStartTogether() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.machine.block("fake:b")
        h.machine.block("fake:c")
        h.state.retry = [RetryFake("a", "1"), RetryFake("b", "1")]
        h.state.rollback = [RollbackFake("c", "1")]
        await eventually("all three in flight") { h.machine.activeTotal == 3 }
        h.machine.release("fake:a")
        h.machine.release("fake:b")
        h.machine.release("fake:c")
        await eventually("all rolled out") { h.machine.state.count == 3 }
    }
}

@MainActor
@Test func anIdInBackoffDoesNotHoldOthersBack() async throws {
    try await withEngine { h in
        h.machine.fail("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a failed") { h.engine.slots["fake:a"]?.failure != nil }

        h.state.retry = [RetryFake("a", "1"), RetryFake("b", "1")]
        await eventually("b rolled out") { h.machine.state["fake:b"] == "1" }
        #expect(h.machine.calls("fake:a").count == 1)
    }
}

@MainActor
@Test func aWedgedOperationBlocksOnlyItsOwnId() async throws {
    try await withEngine { h in
        h.machine.block("fake:a")
        h.machine.ignoreCancel("fake:a")
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a1 in flight") { h.machine.activeCount("fake:a") == 1 }

        h.state.retry = [RetryFake("a", "2")]
        await h.advance(.seconds(59))
        #expect(h.logs("astrolabe.operation.wedged").isEmpty)
        await h.advance(.seconds(1))
        await eventually("a logged as wedged") { h.logs("astrolabe.operation.wedged").count == 1 }

        h.state.retry = [RetryFake("a", "2"), RetryFake("b", "1")]
        await eventually("b rolled out") { h.machine.state["fake:b"] == "1" }
        #expect(h.machine.calls("fake:a").count == 1)

        h.machine.release("fake:a")
        await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
        #expect(h.logs("astrolabe.operation.unwedged").count == 1)
        #expect(h.machine.maxActivePerID == 1)
    }
}
