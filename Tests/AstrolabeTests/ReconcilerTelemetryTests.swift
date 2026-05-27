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

    await reconciler.mount(node, callbacks: nil, payloadStore: PayloadStore())
    #expect(recorder.spans.count == 1)
    let span = recorder.spans[0]
    #expect(span.name == "astrolabe.mount")
    #expect(span.outcome == .ok)
    #expect(span.attributes["astrolabe.node.type"] == .string("AlwaysSucceedsNode"))
    #expect(span.attributes["astrolabe.node.id_hash"] != nil)
}

@Test func mountFailureVerboseIncludesFullErrorMessage() async {
    let recorder = RecordingTelemetry(verbose: true)
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(AlwaysFailsNode(), name: "boom-node-verbose")

    await reconciler.mount(node, callbacks: nil, payloadStore: PayloadStore())

    let failureLogs = recorder.logs(named: "astrolabe.mount.failed")
    #expect(failureLogs.count == 1)
    #expect(failureLogs[0].attributes["astrolabe.error.message"] != nil)
    let span = recorder.span(named: "astrolabe.mount")
    if case .error(_, let status)? = span?.outcome {
        #expect(status.contains("Boom"))
    } else {
        Issue.record("Expected error span outcome")
    }
}

@Test func mountFailureRecordsErrorTypeOnly() async {
    let recorder = RecordingTelemetry()
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(AlwaysFailsNode(), name: "boom-node")

    await reconciler.mount(node, callbacks: nil, payloadStore: PayloadStore())

    let span = recorder.span(named: "astrolabe.mount")
    #expect(span?.outcome == .error(typeName: "Boom", statusDescription: "Boom"))

    let failureLogs = recorder.logs(named: "astrolabe.mount.failed")
    #expect(failureLogs.count == 1)
    #expect(failureLogs[0].level == .error)
    #expect(failureLogs[0].attributes["astrolabe.error.type"] == .string("Boom"))
}

@Test func mountThrowingDoesNotEscapeReconciler() async {
    // Mount is a fire-and-forget wave: a throwing inner mount is caught, logged,
    // and returns normally. Convergence is `loop()`'s job, not the Reconciler's.
    let recorder = RecordingTelemetry()
    let reconciler = Reconciler(telemetry: recorder)
    let node = makeNode(AlwaysFailsNode(), name: "boom-no-escape")

    await reconciler.mount(node, callbacks: nil, payloadStore: PayloadStore())

    #expect(recorder.spans.count == 1)
    #expect(recorder.logs(named: "astrolabe.mount.failed").count == 1)
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
    #expect(span?.outcome == .error(typeName: "UnmountBoom", statusDescription: "UnmountBoom"))

    let logs = recorder.logs(named: "astrolabe.unmount.failed")
    #expect(logs.count == 1)
    #expect(logs[0].attributes["astrolabe.error.type"] == .string("UnmountBoom"))
}
