import Testing
@testable import Astrolabe

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
    #expect(TelemetryAttributes.idHash("file:/tmp/a.txt") == TelemetryAttributes.idHash("file:/tmp/a.txt"))
}

@Test func idHashDiffersForDifferentIds() {
    #expect(TelemetryAttributes.idHash("file:/tmp/a.txt") != TelemetryAttributes.idHash("file:/tmp/b.txt"))
}

@Test func idHashIsEightLowercaseHexChars() {
    let hash = TelemetryAttributes.idHash("file:/tmp/a.txt")
    #expect(hash.count == 8)
    #expect(hash.allSatisfy { c in
        ("0"..."9").contains(c) || ("a"..."f").contains(c)
    })
}

@Test func idHashDoesNotContainOriginalString() {
    let hash = TelemetryAttributes.idHash("brew:wget")
    #expect(!hash.contains("wget"))
    #expect(!hash.contains("brew"))
}

@Test func resourceAttributesVerboseIncludesId() {
    let attrs = TelemetryAttributes.resourceAttributes(id: "file:/tmp/a.txt", kind: "staging.file", verbose: true)
    #expect(attrs["astrolabe.resource.id"] == .string("file:/tmp/a.txt"))
    #expect(attrs["astrolabe.resource.kind"] == .string("staging.file"))
}

@Test func resourceAttributesDefaultOmitsId() {
    let attrs = TelemetryAttributes.resourceAttributes(id: "file:/tmp/a.txt", kind: "staging.file", verbose: false)
    #expect(attrs["astrolabe.resource.id"] == nil)
    #expect(attrs["astrolabe.resource.id_hash"] == .string(TelemetryAttributes.idHash("file:/tmp/a.txt")))
}

@Test func operationAttributesCarryKindAndAttempt() {
    let attrs = TelemetryAttributes.operationAttributes(
        id: "file:/tmp/a.txt", kind: "staging.file", operation: "rollout", attempt: 2, verbose: false
    )
    #expect(attrs["astrolabe.operation.kind"] == .string("rollout"))
    #expect(attrs["astrolabe.operation.attempt"] == .int(2))
    #expect(attrs["astrolabe.resource.id"] == nil)
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
