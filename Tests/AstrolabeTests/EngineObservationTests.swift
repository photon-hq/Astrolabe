import Foundation
import Testing
@testable import Astrolabe

@MainActor
@Test func aTrackedWriteRunsOnePass() async throws {
    try await withEngine { h in
        await h.settle()
        let passes = h.engine.passCount
        h.state.tracked += 1
        await h.settle()
        #expect(h.engine.passCount == passes + 1)
    }
}

@MainActor
@Test func anUntrackedWriteRunsNoPass() async throws {
    try await withEngine { h in
        await h.settle()
        let passes = h.engine.passCount
        h.state.untracked += 1
        await h.settle()
        #expect(h.engine.passCount == passes)
    }
}

@MainActor
@Test func aBurstOfWritesRunsOnePass() async throws {
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
@Test func anEqualValueWriteRunsNoPass() async throws {
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
