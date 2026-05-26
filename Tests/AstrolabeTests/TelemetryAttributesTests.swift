import Testing
@testable import Astrolabe

private struct AttrTestLeaf: ReconcilableNode {
    let displayName = "AttrTestLeaf"
    func mount(identity: NodeIdentity, context: ReconcileContext) async throws {}
    func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {}
}

private struct AttrTestError: Error {}
private enum AttrTestErrorEnum: Error { case kaboom(secret: String) }

@Test func errorTypeNameStripsAssociatedValues() {
    let typed: any Error = AttrTestErrorEnum.kaboom(secret: "hunter2")
    let name = TelemetryAttributes.errorTypeName(typed)
    #expect(name == "AttrTestErrorEnum")
    #expect(!name.contains("hunter2"))
}

@Test func errorTypeNameOnEmptyStruct() {
    let e: any Error = AttrTestError()
    #expect(TelemetryAttributes.errorTypeName(e) == "AttrTestError")
}

@Test func idHashIsDeterministic() {
    let a = NodeIdentity([.named("brew:formula:wget")])
    let b = NodeIdentity([.named("brew:formula:wget")])
    #expect(TelemetryAttributes.idHash(a) == TelemetryAttributes.idHash(b))
}

@Test func idHashDiffersForDifferentIdentities() {
    let a = NodeIdentity([.named("brew:formula:wget")])
    let b = NodeIdentity([.named("brew:formula:jq")])
    #expect(TelemetryAttributes.idHash(a) != TelemetryAttributes.idHash(b))
}

@Test func idHashIsEightLowercaseHexChars() {
    let id = NodeIdentity([.named("brew:formula:wget")])
    let hash = TelemetryAttributes.idHash(id)
    #expect(hash.count == 8)
    #expect(hash.allSatisfy { c in
        ("0"..."9").contains(c) || ("a"..."f").contains(c)
    })
}

@Test func idHashDoesNotContainOriginalString() {
    let id = NodeIdentity([.named("brew:formula:wget")])
    let hash = TelemetryAttributes.idHash(id)
    #expect(!hash.contains("wget"))
    #expect(!hash.contains("brew"))
}

@Test func nodeAttributesVerboseIncludesCanonicalIdentity() {
    let node = TreeNode(
        identity: NodeIdentity([.named("brew:formula:wget")]),
        kind: .leaf(AttrTestLeaf())
    )
    let attrs = TelemetryAttributes.nodeAttributes(node, verbose: true)
    #expect(attrs["astrolabe.node.identity"] == .string("n:brew:formula:wget"))
}

@Test func nodeAttributesDefaultOmitsCanonicalIdentity() {
    let node = TreeNode(
        identity: NodeIdentity([.named("brew:formula:wget")]),
        kind: .leaf(AttrTestLeaf())
    )
    let attrs = TelemetryAttributes.nodeAttributes(node, verbose: false)
    #expect(attrs["astrolabe.node.identity"] == nil)
}

@Test func nodeAttributesVerboseIncludesDisplayName() {
    let node = TreeNode(
        identity: NodeIdentity([.named("brew:formula:wget")]),
        kind: .leaf(AttrTestLeaf())
    )
    let attrs = TelemetryAttributes.nodeAttributes(node, verbose: true)
    #expect(attrs["astrolabe.node.display_name"] == .string("AttrTestLeaf"))
}

@Test func errorAttributesVerboseIncludesMessageAndShellFields() {
    let error = ReconcileError.processFailed(
        path: "/usr/bin/brew",
        arguments: ["install", "wget"],
        output: "Error: network"
    )
    let attrs = TelemetryAttributes.errorAttributes(error, verbose: true)
    #expect(attrs["astrolabe.error.message"] != nil)
    #expect(attrs["astrolabe.shell.path"] == .string("/usr/bin/brew"))
    #expect(attrs["astrolabe.shell.arguments"] == .string("install wget"))
    #expect(attrs["astrolabe.shell.output"] == .string("Error: network"))
}

@Test func errorAttributesDefaultOmitsMessage() {
    let error = ReconcileError.processFailed(path: "/x", arguments: [], output: "secret")
    let attrs = TelemetryAttributes.errorAttributes(error, verbose: false)
    #expect(attrs["astrolabe.error.message"] == nil)
    #expect(attrs["astrolabe.shell.output"] == nil)
}

@Test func environmentSnapshotVerboseIncludesGitHubToken() {
    var env = EnvironmentValues()
    env.githubToken = "ghp_test_token"
    let snapshot = TelemetryAttributes.environmentSnapshot(env)
    #expect(snapshot.contains("githubToken=ghp_test_token"))
}
