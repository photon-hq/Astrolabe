import Foundation
import Testing
@testable import Astrolabe

// MARK: - Test reconcilable nodes

private struct AlwaysSucceedsNode: ReconcilableNode {
    let displayName = "AlwaysSucceeds"
    func mount(identity: NodeIdentity, context: ReconcileContext) async throws {}
    func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {}
}

private struct AlwaysFailsNode: ReconcilableNode {
    struct Boom: Error {}
    let displayName = "AlwaysFails"
    func mount(identity: NodeIdentity, context: ReconcileContext) async throws { throw Boom() }
    func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {}
}

private final class FlakyNodeBox: @unchecked Sendable {
    var attemptsRemaining: Int
    init(failures: Int) { attemptsRemaining = failures }
}

private struct FlakyNode: ReconcilableNode {
    struct Transient: Error {}
    let displayName = "Flaky"
    let box: FlakyNodeBox

    func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        if box.attemptsRemaining > 0 {
            box.attemptsRemaining -= 1
            throw Transient()
        }
    }
    func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {}
}

private struct UnmountFailsNode: ReconcilableNode {
    struct UnmountBoom: Error {}
    let displayName = "UnmountFails"
    func mount(identity: NodeIdentity, context: ReconcileContext) async throws {}
    func unmount(identity: NodeIdentity, context: ReconcileContext) async throws { throw UnmountBoom() }
}

private func makeNode(
    _ reconcilable: any ReconcilableNode,
    name: String,
    modifiers: [NodeModifier] = []
) -> TreeNode {
    TreeNode(identity: NodeIdentity([.named(name)]), kind: .leaf(reconcilable), modifiers: modifiers)
}

// MARK: - Mount tests

@Test func mountEmitsSpanOnSuccess() async {
    let recorder = RecordingTelemetry()
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(AlwaysSucceedsNode(), name: "ok-node")

    let ok = await reconciler.mount(node, callbacks: nil, payloadStore: PayloadStore())
    #expect(ok == true)
    #expect(recorder.spans.count == 1)
    let span = recorder.spans[0]
    #expect(span.name == "astrolabe.mount")
    #expect(span.outcome == .ok)
    #expect(span.attributes["astrolabe.node.type"] == .string("AlwaysSucceedsNode"))
    #expect(span.attributes["astrolabe.node.id_hash"] != nil)
}

@Test func mountFailureRecordsErrorTypeOnly() async {
    let recorder = RecordingTelemetry()
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(AlwaysFailsNode(), name: "boom-node")

    let ok = await reconciler.mount(node, callbacks: nil, payloadStore: PayloadStore())
    #expect(ok == false)

    let span = recorder.span(named: "astrolabe.mount")
    #expect(span?.outcome == .error(typeName: "Boom"))

    let failureLogs = recorder.logs(named: "astrolabe.mount.failed")
    #expect(failureLogs.count == 1)
    #expect(failureLogs[0].level == .error)
    #expect(failureLogs[0].attributes["astrolabe.error.type"] == .string("Boom"))
}

@Test func mountSuccessAfterRetryEmitsSingleSuccessfulSpan() async {
    let recorder = RecordingTelemetry()
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(
        FlakyNode(box: FlakyNodeBox(failures: 1)),
        name: "flaky-node",
        modifiers: [.retry(count: 2, delaySeconds: nil)]
    )

    let ok = await reconciler.mount(node, callbacks: nil, payloadStore: PayloadStore())
    #expect(ok == true)
    let mountSpans = recorder.spans.filter { $0.name == "astrolabe.mount" }
    #expect(mountSpans.count == 1)
    #expect(mountSpans[0].outcome == .ok)
    #expect(recorder.logs(named: "astrolabe.mount.failed").isEmpty)
}

@Test func mountFailureRunsOnFailHandlersAfterSpanEnded() async {
    let recorder = RecordingTelemetry()
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(AlwaysFailsNode(), name: "boom-node-2")

    let onFailFired = OnFailFlag()
    var callbacks = ModifierStore.Callbacks()
    callbacks.onFail = [OnFailModifier(handler: { _ in await onFailFired.set() })]

    let ok = await reconciler.mount(node, callbacks: callbacks, payloadStore: PayloadStore())
    #expect(ok == false)
    #expect(await onFailFired.value == true)

    let span = recorder.span(named: "astrolabe.mount")
    #expect(span != nil)
    let onFailAt = await onFailFired.firedAtUptimeNanoseconds
    #expect(onFailAt != nil)
    #expect(span!.endedAtUptimeNanoseconds < onFailAt!)
}

// MARK: - Unmount tests

@Test func unmountEmitsSpanOnSuccess() async {
    let recorder = RecordingTelemetry()
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(AlwaysSucceedsNode(), name: "ok-unmount")

    await reconciler.unmount(node, callbacks: nil, payloadStore: PayloadStore())
    let span = recorder.span(named: "astrolabe.unmount")
    #expect(span != nil)
    #expect(span?.outcome == .ok)
    #expect(span?.attributes["astrolabe.node.type"] == .string("AlwaysSucceedsNode"))
}

@Test func unmountFailureRecordsErrorTypeOnly() async {
    let recorder = RecordingTelemetry()
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(UnmountFailsNode(), name: "boom-unmount")

    await reconciler.unmount(node, callbacks: nil, payloadStore: PayloadStore())
    let span = recorder.span(named: "astrolabe.unmount")
    #expect(span?.outcome == .error(typeName: "UnmountBoom"))

    let logs = recorder.logs(named: "astrolabe.unmount.failed")
    #expect(logs.count == 1)
    #expect(logs[0].attributes["astrolabe.error.type"] == .string("UnmountBoom"))
}

private actor OnFailFlag {
    private var fired = false
    private var firedAt: UInt64?

    func set() {
        fired = true
        firedAt = DispatchTime.now().uptimeNanoseconds
    }

    var value: Bool { fired }
    var firedAtUptimeNanoseconds: UInt64? { firedAt }
}
