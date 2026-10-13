import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fixtures

private struct BuilderState {
    var flag = true
    var optional: String? = "x"
    var names = ["a", "b"]
    var choice = 0
}

private struct Pair: Component {
    let prefix: String

    var body: some Component {
        RetryFake("\(prefix)-1", "v")
        RetryFake("\(prefix)-2", "v")
    }
}

private struct Everything: Component {
    let state: BuilderState

    var body: some Component {
        RetryFake("first", "v")
        if state.flag {
            RetryFake("if", "v")
        }
        if let value = state.optional {
            RetryFake("iflet-\(value)", "v")
        }
        if state.flag {
            RetryFake("then", "v")
        } else {
            WaitFake("else", "v")
        }
        switch state.choice {
        case 0: RetryFake("case0", "v")
        default: EmptyComponent()
        }
        for name in state.names {
            Pair(prefix: name)
        }
    }
}

private struct Nothing: Component {
    var body: some Component {}
}

@MainActor
private func ids<C: Component>(_ component: C) -> [String] {
    Flatten.resources(of: component).map(\.id)
}

// MARK: - Builder and flatten

@MainActor
@Test func flattenWalksEveryBuilderFormInOrder() {
    let state = BuilderState()
    #expect(ids(Everything(state: state)) == [
        "fake:first", "fake:if", "fake:iflet-x", "fake:then", "fake:case0",
        "fake:a-1", "fake:a-2", "fake:b-1", "fake:b-2",
    ])
}

@MainActor
@Test func flattenFollowsTheOtherBranches() {
    var state = BuilderState()
    state.flag = false
    state.optional = nil
    state.names = []
    state.choice = 1
    #expect(ids(Everything(state: state)) == ["fake:first", "fake:else"])
}

@MainActor
@Test func emptyBodyDeclaresNothing() {
    #expect(ids(Nothing()).isEmpty)
    #expect(ids(EmptyComponent()).isEmpty)
}

@MainActor
@Test func flattenCopiesTheDeclaredSnapshot() throws {
    let resources = Flatten.resources(of: Pair(prefix: "p"))
    let first = try #require(resources.first?.base as? RetryFake)
    #expect(first == RetryFake("p-1", "v"))
    #expect(resources.first?.kind == "fake.retry")
    #expect(resources.first?.policy == .retry())
}

// MARK: - Declaration

@Test func identicalDuplicatesAreDeduplicated() {
    let declaration = Declaration([AnyResource(RetryFake("a", "1")), AnyResource(RetryFake("a", "1"))])
    #expect(declaration.items.count == 1)
    #expect(declaration.frozen.isEmpty)
    #expect(declaration.duplicates.isEmpty)
}

@Test func conflictingDuplicatesFreezeTheId() {
    let declaration = Declaration([
        AnyResource(RetryFake("a", "1")),
        AnyResource(RetryFake("b", "1")),
        AnyResource(RetryFake("a", "2")),
        AnyResource(RetryFake("a", "1")),
    ])
    #expect(declaration.items.keys.sorted() == ["fake:b"])
    #expect(declaration.frozen == ["fake:a"])
    #expect(declaration.duplicates["fake:a"]?.count == 3)
}

@Test func equalSnapshotsGiveEqualHashes() {
    #expect(RetryFake.compute(RetryFake("a", "1")) == RetryFake.compute(RetryFake("a", "1")))
    #expect(RetryFake.compute(RetryFake("a", "1")) != RetryFake.compute(RetryFake("a", "2")))
}

// MARK: - Registry and snapshots

private struct ClashA: Resource {
    static let kind = "clash"
    var id: String { "clash" }
    static func compute(_ resource: Self) -> String { Hash.of("a") }
    @concurrent static func rollout(_ resource: Self) async throws {}
    @concurrent static func remove(_ resource: Self) async throws {}
}

private struct ClashB: Resource {
    static let kind = "clash"
    var id: String { "clash" }
    static func compute(_ resource: Self) -> String { Hash.of("b") }
    @concurrent static func rollout(_ resource: Self) async throws {}
    @concurrent static func remove(_ resource: Self) async throws {}
}

@Test func registryRejectsTwoTypesWithOneKind() {
    #expect(throws: ResourceRegistry.Conflict.self) {
        _ = try ResourceRegistry([ClashA.self, ClashB.self])
    }
}

@Test func registryReportsKnownNewAndConflictingTypes() throws {
    var registry = try ResourceRegistry([RetryFake.self, RetryFake.self, ClashA.self])
    guard case .known = registry.register(RetryFake.self) else {
        Issue.record("expected .known")
        return
    }
    guard case .new = registry.register(WaitFake.self) else {
        Issue.record("expected .new")
        return
    }
    guard case .conflict = registry.register(ClashB.self) else {
        Issue.record("expected .conflict")
        return
    }
    // The first type keeps the kind.
    #expect(registry.type(for: "clash") == ClashA.self)
}

@Test func snapshotRoundTripsThroughNestedJSON() throws {
    let resource = AnyResource(RetryFake("a", "1"))
    let json = try resource.encode()
    #expect(json == .object(["name": .string("a"), "value": .string("1")]))

    let registry = try ResourceRegistry([RetryFake.self])
    let decoded = try AnyResource.decode(kind: "fake.retry", json, registry: registry)
    #expect(decoded.base as? RetryFake == RetryFake("a", "1"))
    #expect(decoded.hash() == resource.hash())
}

@Test func decodingAnUnknownKindThrows() throws {
    let registry = try ResourceRegistry([RetryFake.self])
    #expect(throws: AnyResource.DecodeError.unknownKind("gone")) {
        _ = try AnyResource.decode(kind: "gone", .object([:]), registry: registry)
    }
}

// MARK: - Engine: duplicate ids and kind conflicts

@MainActor
@Test func engineDeduplicatesIdenticalDuplicates() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1"), RetryFake("a", "1")]
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()
        #expect(h.machine.calls("fake:a").count == 1)
        #expect(h.logs("astrolabe.declaration.duplicate_id").isEmpty)
    }
}

@MainActor
@Test func engineFreezesConflictingDuplicates() async throws {
    try await withEngine { h in
        h.state.retry = [RetryFake("a", "1")]
        await eventually("a rolled out") { h.machine.state["fake:a"] == "1" }
        await h.settle()

        h.state.retry = [RetryFake("a", "2"), RetryFake("a", "3")]
        await h.settle()
        // Frozen: neither rolled out nor removed.
        #expect(h.machine.calls("fake:a").count == 1)
        #expect(h.machine.state["fake:a"] == "1")
        #expect(h.logs("astrolabe.declaration.duplicate_id").count >= 1)

        h.state.retry = [RetryFake("a", "3")]
        await eventually("a rolled out at 3") { h.machine.state["fake:a"] == "3" }
    }
}

private struct ClashApp: Astrolabe {
    var body: some Component {
        ClashB()
    }

    static var resourceTypes: [any Resource.Type] { [ClashA.self] }
}

@MainActor
@Test func engineFreezesResourcesWhoseKindIsTaken() async throws {
    let directory = try TemporaryDirectory()
    let h = EngineHarness<ClashApp>(recordsURL: directory.recordsURL)
    await h.start()
    await h.settle()
    #expect(h.logs("astrolabe.declaration.kind_conflict").count >= 1)
    #expect(h.engine.lastPlan.holds.map(\.hold) == [.frozen])
    #expect(h.engine.lastPlan.actions.isEmpty)
    await h.stop()
}
