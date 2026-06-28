import Foundation
import Testing
@testable import Astrolabe

// MARK: - Tree building & identity

@Test func customizedBuildsLeaf() {
    ModifierStore.shared.clear()
    let tree = TreeBuilder.build(Customized("demo") {} check: { true })
    if case .leaf(let node) = tree.kind {
        #expect(node is CustomizedNode)
    } else {
        #expect(Bool(false), "Expected .leaf kind")
    }
}

@Test func customizedContentIdentityIsStable() {
    let a = TreeBuilder.build(Customized("demo") {} check: { true })
    let b = TreeBuilder.build(Customized("demo") {} check: { false })   // same id, different closures
    let c = TreeBuilder.build(Customized("other") {} check: { true })

    #expect(a.identity.path == [.named("customized:demo")])
    #expect(a.identity == b.identity)   // identity is the id alone — stable across rebuilds
    #expect(a.identity != c.identity)   // different id → distinct identity
}

// MARK: - Mount convergence

@Test func customizedMountSkipsWhenAlreadySatisfied() async throws {
    let didMount = Box(false)
    let node = try #require(customizedNode(Customized("demo") { didMount.value = true } check: { true }))
    let store = PayloadStore()

    try await node.mount(identity: cid("demo"), context: ReconcileContext(payloadStore: store))

    #expect(didMount.value == false)                    // check already true → mount skipped
    #expect(store.record(for: cid("demo")) != nil)      // payload still recorded
}

@Test func customizedMountRunsWhenNotSatisfied() async throws {
    let didMount = Box(false)
    let node = try #require(customizedNode(Customized("demo") { didMount.value = true } check: { false }))
    let store = PayloadStore()

    try await node.mount(identity: cid("demo"), context: ReconcileContext(payloadStore: store))

    #expect(didMount.value == true)
    if case .customized(let recordedID)? = store.record(for: cid("demo")) {
        #expect(recordedID == "demo")
    } else {
        #expect(Bool(false), "Expected .customized payload record")
    }
}

// MARK: - Drift loop

@Test func customizedLoopReflectsCheck() async throws {
    let healthy = try #require(customizedNode(Customized("h") {} check: { true }))
    let drifted = try #require(customizedNode(Customized("d") {} check: { false }))
    let ctx = ReconcileContext(payloadStore: PayloadStore())

    #expect(try await healthy.loop(identity: cid("h"), context: ctx) == .healthy)

    let outcome = try await drifted.loop(identity: cid("d"), context: ctx)
    if case .drifted = outcome {} else { #expect(Bool(false), "Expected .drifted") }
}

// MARK: - Unmount

@Test func customizedUnmountRunsClosureAndClearsPayload() async throws {
    let didUnmount = Box(false)
    let node = try #require(customizedNode(
        Customized("demo") {} check: { false } unmount: { didUnmount.value = true }
    ))
    let store = PayloadStore()
    store.set(.customized(id: "demo"), for: cid("demo"))

    try await node.unmount(identity: cid("demo"), context: ReconcileContext(payloadStore: store))

    #expect(didUnmount.value == true)
    #expect(store.record(for: cid("demo")) == nil)
}

@Test func customizedUnmountDefaultsToNoOp() async throws {
    // No `unmount:` supplied — should clear the payload without throwing.
    let node = try #require(customizedNode(Customized("demo") {} check: { false }))
    let store = PayloadStore()
    store.set(.customized(id: "demo"), for: cid("demo"))

    try await node.unmount(identity: cid("demo"), context: ReconcileContext(payloadStore: store))

    #expect(store.record(for: cid("demo")) == nil)
}

// MARK: - Persisted form (post-restart, closures gone)

@Test func customizedPersistedFormDegradesGracefully() async throws {
    let node = PayloadRecord.customized(id: "demo").reconcilableNode()
    let store = PayloadStore()
    store.set(.customized(id: "demo"), for: cid("demo"))
    let ctx = ReconcileContext(payloadStore: store)

    // Can't verify a persisted custom step → assume healthy.
    #expect(try await node.loop(identity: cid("demo"), context: ctx) == .healthy)

    // Can't run custom unmount, but still clears the payload — and doesn't crash.
    try await node.unmount(identity: cid("demo"), context: ctx)
    #expect(store.record(for: cid("demo")) == nil)
}

// MARK: - Helpers

private func cid(_ name: String) -> NodeIdentity {
    NodeIdentity([.named("customized:\(name)")])
}

private func customizedNode(_ step: Customized) -> CustomizedNode? {
    ModifierStore.shared.clear()
    guard case .leaf(let node) = TreeBuilder.build(step).kind else { return nil }
    return node as? CustomizedNode
}

/// Thread-safe box for observing side effects from `@Sendable` closures in tests.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
