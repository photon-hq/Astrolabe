import Foundation
import Testing
@testable import Astrolabe

private typealias Call = FakeMachine.Call

private func hash(_ resource: RetryFake) -> String { RetryFake.compute(resource) }

@MainActor
@Test func newIdRollsOut() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()
        #expect(h.machine.calls == [Call(op: .rollout, id: "fake:a", value: "1")])
        #expect(h.diskRecord("fake:a")?.hash == hash(RetryFake("a", "1")))
        #expect(h.diskRecord("fake:a")?.kind == "fake.retry")
    }
}

@MainActor
@Test func sameIdAndHashDoesNothing() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        // A pass in which `a` is declared unchanged.
        h.state.retry = [RetryFake("a", "1"), RetryFake("b", "1")]
        await eventually("b rolled out") { h.machine.state["fake:b"] == "1" }
        await h.settle()
        #expect(h.machine.calls("fake:a").count == 1)
    }
}

@MainActor
@Test func newHashRollsOutExactlyTheDeclaredSnapshot() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a at 1") { h.machine.state["fake:a"] == "1" }
        h.state.retry = [RetryFake("a", "2")]
        await eventually("a at 2") { h.machine.state["fake:a"] == "2" }
        await h.settle()
        #expect(h.machine.calls("fake:a") == [
            Call(op: .rollout, id: "fake:a", value: "1"),
            Call(op: .rollout, id: "fake:a", value: "2"),
        ])
        #expect(h.diskRecord("fake:a")?.hash == hash(RetryFake("a", "2")))
        #expect(h.diskRecord("fake:a")?.snapshot == .object(["name": .string("a"), "value": .string("2")]))
    }
}

@MainActor
@Test func undeclaredIdIsRemovedOnceWithTheMemorySnapshot() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        h.state.retry = []
        await eventually("a removed") { h.machine.state["fake:a"] == nil }
        await h.settle()
        #expect(h.machine.calls("fake:a") == [
            Call(op: .rollout, id: "fake:a", value: "1"),
            Call(op: .remove, id: "fake:a", value: "1"),
        ])
        #expect(h.diskRecord("fake:a") == nil)
        #expect(h.engine.slots["fake:a"] == nil)

        // Later passes don't remove it again.
        h.state.retry = [RetryFake("b", "1")]
        await eventually("b rolled out") { h.machine.state["fake:b"] == "1" }
        await h.settle()
        #expect(h.machine.calls("fake:a").count == 2)
    }
}

@MainActor
@Test func changingAnIdBearingPropertyRollsOutTheNewIdAndRemovesTheOld() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }

        h.state.retry = [RetryFake("b", "1")]
        await eventually("b in, a out") { h.machine.state == ["fake:b": "1"] }
        await h.settle()
        #expect(h.machine.calls("fake:a").map(\.op) == [.rollout, .remove])
        #expect(h.machine.calls("fake:b").map(\.op) == [.rollout])
        #expect(h.diskRecord("fake:a") == nil)
        #expect(h.diskRecord("fake:b") != nil)
    }
}
