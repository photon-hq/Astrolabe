import Foundation
import Testing
@testable import Astrolabe

private func record(_ value: String) -> Record {
    Record(kind: "fake.retry", hash: "h-\(value)", snapshot: .object(["name": .string("a"), "value": .string(value)]))
}

@MainActor
@Test func missingFileLoadsEmpty() throws {
    let directory = try TemporaryDirectory()
    let store = RecordStore(url: directory.recordsURL)
    #expect(store.load() == .missing)
    #expect(store.records.isEmpty)
}

@MainActor
@Test func writesRoundTripAndAreReadableJSON() throws {
    let directory = try TemporaryDirectory()
    let store = RecordStore(url: directory.recordsURL)
    try store.set("fake:a", record("1"))
    try store.set("fake:a@weird", record("2"))

    let reloaded = RecordStore(url: directory.recordsURL)
    #expect(reloaded.load() == .loaded)
    #expect(reloaded.records == ["fake:a": record("1"), "fake:a@weird": record("2")])

    // Nested JSON rather than base64, so `jq` works on a host.
    let data = try Data(contentsOf: directory.recordsURL)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["version"] as? Int == 1)
    let records = try #require(json["records"] as? [String: [String: Any]])
    let snapshot = try #require(records["fake:a"]?["snapshot"] as? [String: String])
    #expect(snapshot == ["name": "a", "value": "1"])
}

@MainActor
@Test func fileIsOwnerOnlyAndLeavesNoTemporaries() throws {
    let directory = try TemporaryDirectory()
    let store = RecordStore(url: directory.recordsURL)
    try store.set("fake:a", record("1"))
    try store.set("fake:a", record("2"))

    let attributes = try FileManager.default.attributesOfItem(atPath: directory.recordsURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
    #expect(contents == ["records.json"])
}

@MainActor
@Test func deleteRemovesTheEntry() throws {
    let directory = try TemporaryDirectory()
    let store = RecordStore(url: directory.recordsURL)
    try store.set("fake:a", record("1"))
    try store.set("fake:b", record("1"))
    try store.delete("fake:a")
    try store.delete("fake:missing")

    let reloaded = RecordStore(url: directory.recordsURL)
    _ = reloaded.load()
    #expect(Array(reloaded.records.keys) == ["fake:b"])
}

@MainActor
@Test func corruptFileIsMovedAside() throws {
    let directory = try TemporaryDirectory()
    try Data("{ not json".utf8).write(to: directory.recordsURL)

    let store = RecordStore(url: directory.recordsURL)
    guard case .reset("corrupt", let movedTo?) = store.load() else {
        Issue.record("expected a reset with the file moved aside")
        return
    }
    #expect(store.records.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.recordsURL.path))
    #expect(movedTo.lastPathComponent.hasPrefix("records.json.corrupt-"))
    #expect(try Data(contentsOf: movedTo) == Data("{ not json".utf8))
}

@MainActor
@Test func unknownVersionIsMovedAside() throws {
    let directory = try TemporaryDirectory()
    try Data(#"{"version": 2, "records": "a different shape"}"#.utf8).write(to: directory.recordsURL)

    let store = RecordStore(url: directory.recordsURL)
    guard case .reset("unknown_version", _?) = store.load() else {
        Issue.record("expected an unknown-version reset")
        return
    }
    #expect(store.records.isEmpty)
}

@MainActor
@Test func dryRunLoadLeavesACorruptFileInPlace() throws {
    let directory = try TemporaryDirectory()
    try Data("garbage".utf8).write(to: directory.recordsURL)

    let store = RecordStore(url: directory.recordsURL)
    #expect(store.load(moveAsideCorrupt: false) == .reset(reason: "corrupt", movedTo: nil))
    #expect(try Data(contentsOf: directory.recordsURL) == Data("garbage".utf8))
}

@MainActor
@Test func unknownKindsSurviveRewritesVerbatim() throws {
    let directory = try TemporaryDirectory()
    let foreign = Record(kind: "gone.kind", hash: "h", snapshot: .object(["n": .int(7), "deep": .array([.null, .bool(true), .double(1.5)])]))
    let first = RecordStore(url: directory.recordsURL)
    try first.set("gone:x", foreign)

    let second = RecordStore(url: directory.recordsURL)
    _ = second.load()
    try second.set("fake:a", record("1"))

    let third = RecordStore(url: directory.recordsURL)
    _ = third.load()
    #expect(third.records["gone:x"] == foreign)
}
