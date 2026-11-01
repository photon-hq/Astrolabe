import Testing
@testable import Astrolabe

/// Nested and never declared or named by an engine: only its record makes it known.
private enum Namespace {
    @Resource
    struct Unlisted {
        static let kind = "test.unlisted"
        var id: String { "unlisted" }
        static func compute(_ resource: Self) -> String { Hash.of(kind) }
        @concurrent static func rollout(_ resource: Self) async throws {}
        @concurrent static func remove(_ resource: Self) async throws {}
    }
}

@Test func everyResourceTypeInTheBinaryIsFoundOnce() {
    var counts: [String: Int] = [:]
    for type in ResourceRecords.linkedTypes() {
        counts[type.kind, default: 0] += 1
    }
    for kind in ["fake.retry", "fake.rollback", "fake.wait", "fake.capped", "test.file", "test.unlisted", "astrolabe.commandLineTools", "astrolabe.homebrew", "astrolabe.brew"] {
        #expect(counts[kind] == 1, "\(kind)")
    }
    // `ClashA` and `ClashB` share a kind.
    #expect(counts["clash"] == 2)
}

@Test func aRegistryOverTheLinkedTypesDecodesAnyOfThem() throws {
    let registry = try ResourceRegistry(ResourceRecords.linkedTypes().filter { $0.kind != "clash" })
    #expect(registry.type(for: "test.unlisted") == Namespace.Unlisted.self)
    #expect(registry.type(for: "fake.retry") == RetryFake.self)
}

/// At launch the daemon registers every linked type, so two types claiming one kind fail it
/// even if `body` never declares either.
@Test func twoLinkedTypesWithOneKindFailTheRegistry() {
    #expect(throws: ResourceRegistry.Conflict.self) {
        _ = try ResourceRegistry(ResourceRecords.linkedTypes())
    }
}
