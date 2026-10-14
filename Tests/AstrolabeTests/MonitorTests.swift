import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fixtures

/// A monitor of an optional value, coded like a resource's stored property.
private struct OptionalMonitored: Codable {
    var monitor: Monitor<String?>
}

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

// MARK: - Reads

@MainActor
@Test func onTheMainActorOutsideAPassAMonitorReadsNothing() {
    #expect(MonitoredFake(name: "m", value: "0").health == nil)
}

@Test func offTheMainThreadAMonitorReadsNothing() async {
    #expect(MonitoredFake(name: "m", value: "0").health == nil)
    let detached = await Task.detached { MonitoredFake(name: "m", value: "0").health }.value
    #expect(detached == nil)
}

@MainActor
@Test func inAPassAMonitorReadsItsFactAndRecordsTheKey() {
    let fakeFacts = FakeFacts()
    fakeFacts.set(HealthKey.self, "ok")
    let store = FactStore(wake: Wake(), clock: EngineClock(ManualClock()), telemetry: NoopAstrolabeTelemetry())
    defer { store.stopAll() }
    fakeFacts.inject(into: store)

    // The pass starts the key's loop, which reads the fake Mac.
    let (resource, atDefault) = FakeFacts.$current.withValue(fakeFacts) {
        store.tracking { MonitoredFake(name: "m", value: "0") }
    }
    #expect(resource.health == "ok")
    #expect(atDefault.isEmpty)
    #expect(store.lastRead == [ObjectIdentifier(HealthKey.self)])
}

// MARK: - Coding

@Test func anUnreadMonitorIsLeftOutOfTheSnapshot() throws {
    #expect(try AnyResource(MonitoredFake(name: "m", value: "0")).encode() == .object([
        "name": .string("m"), "value": .string("0"),
    ]))
    #expect(try AnyResource(MonitoredFake(name: "m", value: "0", health: "ok")).encode() == .object([
        "name": .string("m"), "value": .string("0"), "health": .string("ok"),
    ]))
}

@Test func aMissingKeyDecodesAsUnread() throws {
    #expect(try decode(MonitoredFake.self, #"{"name":"m","value":"0"}"#).health == nil)
    #expect(try decode(MonitoredFake.self, #"{"name":"m","value":"0","health":"ok"}"#).health == "ok")
}

@Test func anOptionalValueKeepsAReadNilApartFromUnread() throws {
    let unread = OptionalMonitored(monitor: Monitor(observed: nil))
    let readNil = OptionalMonitored(monitor: Monitor(observed: .some(nil)))
    #expect(try json(unread) == "{}")
    #expect(try json(readNil) == #"{"monitor":null}"#)

    let decodedUnread = try decode(OptionalMonitored.self, "{}")
    let decodedReadNil = try decode(OptionalMonitored.self, #"{"monitor":null}"#)
    #expect(decodedUnread.monitor == unread.monitor)
    #expect(decodedReadNil.monitor == readNil.monitor)
    #expect(decodedReadNil.monitor.isObserved)
    #expect(Hash.of(unread.monitor) != Hash.of(readNil.monitor))
}

// MARK: - Monitor hash

@Test func aResourceWithoutMonitorsHasNoMonitorHash() {
    let resource = AnyResource(RetryFake("a", "1"))
    #expect(resource.monitorHash() == nil)
    #expect(resource.unobservedMonitors.isEmpty)
}

@Test func theMonitorHashCoversEachMonitorByNameAndLeavesTheHashAlone() {
    let ok = AnyResource(MonitoredFake(name: "m", value: "0", health: "ok"))
    let drifted = AnyResource(MonitoredFake(name: "m", value: "0", health: "drifted"))
    let unread = AnyResource(MonitoredFake(name: "m", value: "0"))

    #expect(ok.monitorHash() == Hash.of("health", Optional("ok")))
    #expect(ok.monitorHash() != drifted.monitorHash())
    #expect(ok.monitorHash() != unread.monitorHash())
    #expect(ok.hash() == drifted.hash())
    #expect(ok.hash() == unread.hash())
}

@Test func unobservedMonitorsAreNamed() {
    #expect(AnyResource(MonitoredFake(name: "m", value: "0")).unobservedMonitors == ["health"])
    #expect(AnyResource(MonitoredFake(name: "m", value: "0", health: "ok")).unobservedMonitors.isEmpty)
}
