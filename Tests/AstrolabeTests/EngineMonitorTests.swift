import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fixtures

extension Facts {
    /// Resources built outside `body`, where their monitors read nothing.
    @FactEntry(read: { try await FakeFacts.read("prebuilt", as: [MonitoredFake].self) })
    fileprivate var prebuilt: [MonitoredFake] = []
}

private struct PrebuiltApp: Astrolabe {
    @Fact(\.prebuilt) var prebuilt

    var body: some Component {
        for resource in prebuilt { resource }
    }
}

/// `m`'s record hash at `value`: the same whatever its health.
private func hash(_ value: String) -> String {
    MonitoredFake.compute(MonitoredFake(name: "m", value: value))
}

/// `m`'s snapshot in `records.json`.
private func snapshot(_ value: String, health: String?) -> JSONValue {
    var fields: [String: JSONValue] = ["name": .string("m"), "value": .string(value)]
    fields["health"] = health.map(JSONValue.string)
    return .object(fields)
}

/// What `m`'s rollouts put on the Mac, failed and cancelled ones included.
@MainActor
private func rollouts<App>(_ h: EngineHarness<App>) -> [String] {
    h.machine.calls("fake:m").filter { $0.op == .rollout }.map(\.value)
}

@MainActor
private func started<App>(_ h: EngineHarness<App>) -> Int {
    h.logs("astrolabe.operation.started").count
}

/// Runs `body` with a started `MonitoredApp<R>` whose health reads `ok`. `before` runs ahead of
/// the start.
@MainActor
private func withMonitored<R: MonitoredFakeResource>(
    _: R.Type,
    before: (EngineHarness<MonitoredApp<R>>) -> Void = { _ in },
    _ body: (EngineHarness<MonitoredApp<R>>) async throws -> Void
) async throws {
    try await withEngine(MonitoredApp<R>.self, before: { h in
        h.fakeFacts.set(HealthKey.self, "ok")
        before(h)
    }, body)
}

/// `withMonitored(MonitoredFake.self)`.
@MainActor
private func withMonitored(
    before: (EngineHarness<MonitoredApp<MonitoredFake>>) -> Void = { _ in },
    _ body: (EngineHarness<MonitoredApp<MonitoredFake>>) async throws -> Void
) async throws {
    try await withMonitored(MonitoredFake.self, before: before, body)
}

/// A harness over `recordsURL` whose health reads `health`, not yet started.
@MainActor
private func monitoredHarness(_ recordsURL: URL, health: String = "ok") -> EngineHarness<MonitoredApp<MonitoredFake>> {
    let h = EngineHarness<MonitoredApp<MonitoredFake>>(recordsURL: recordsURL)
    h.fakeFacts.set(HealthKey.self, health)
    return h
}

@MainActor
struct EngineMonitorTests {
    // MARK: - Changes

    @Test func aMonitorChangeWhileIdleRollsOutTheSameHashAgain() async throws {
        try await withMonitored { h in
            await eventually("m at ok") { h.machine.state["fake:m"] == "0@ok" }
            await h.settle()
            #expect(h.diskRecord("fake:m")?.snapshot == snapshot("0", health: "ok"))

            h.state.health = "drifted"
            await eventually("m at drifted") { h.machine.state["fake:m"] == "0@drifted" }
            await h.settle()
            #expect(rollouts(h) == ["0@ok", "0@drifted"])
            #expect(h.diskRecord("fake:m")?.hash == hash("0"))
            #expect(h.diskRecord("fake:m")?.snapshot == snapshot("0", health: "drifted"))
        }
    }

    @Test func aMonitorChangeMidRolloutNeverCancelsItAndRerunsOnceItEnds() async throws {
        try await withMonitored(before: { $0.machine.block("fake:m") }) { h in
            await eventually("m in flight") { h.machine.activeCount("fake:m") == 1 }
            h.state.health = "drifted"
            await h.settle()
            #expect(h.engine.lastPlan.holds.map(\.hold) == [.waitingForOperation])
            #expect(h.machine.calls("fake:m").count == 1)

            h.machine.release("fake:m")
            await eventually("m at drifted") { h.machine.state["fake:m"] == "0@drifted" }
            await h.settle()
            #expect(rollouts(h) == ["0@ok", "0@drifted"])
            #expect(h.machine.endings.map(\.ending) == [.returned, .returned])
            #expect(h.logs("astrolabe.operation.cancelling").isEmpty)
            #expect(h.machine.maxActivePerID == 1)
        }
    }

    @Test func aDeclaredChangeMidRolloutStillSupersedesIt() async throws {
        try await withMonitored(before: { $0.machine.block("fake:m") }) { h in
            await eventually("m0 in flight") { h.machine.activeCount("fake:m") == 1 }
            h.state.tracked = 1
            await eventually("m1 started") { h.machine.calls("fake:m").count == 2 }

            // Both at once, in one pass: the declared change decides.
            h.state.tracked = 2
            h.state.health = "drifted"
            await eventually("m2 started") { h.machine.calls("fake:m").count == 3 }

            h.machine.release("fake:m")
            await eventually("m at 2") { h.machine.state["fake:m"] == "2@drifted" }
            await h.settle()
            #expect(rollouts(h) == ["0@ok", "1@ok", "2@drifted"])
            #expect(h.machine.endings.map(\.ending) == [.cancelled, .cancelled, .returned])
            #expect(h.logs("astrolabe.operation.cancelling").count == 2)
            #expect(h.machine.maxActivePerID == 1)
            #expect(h.diskRecord("fake:m")?.hash == hash("2"))
        }
    }

    @Test func aMonitorThatFlipsBackBeforeTheRolloutEndsStartsNothingMore() async throws {
        try await withMonitored(before: { $0.machine.block("fake:m") }) { h in
            await eventually("m in flight") { h.machine.activeCount("fake:m") == 1 }
            h.state.health = "drifted"
            await h.settle()
            h.state.health = "ok"
            await h.settle()
            #expect(h.engine.lastPlan.holds.isEmpty)

            h.machine.release("fake:m")
            await eventually("m at ok") { h.machine.state["fake:m"] == "0@ok" }
            await h.settle()
            #expect(rollouts(h) == ["0@ok"])
            #expect(h.logs("astrolabe.operation.cancelling").isEmpty)
        }
    }

    @Test func aRepairCausesExactlyOneFollowUpRollout() async throws {
        try await withMonitored { h in
            await eventually("m at ok") { h.machine.state["fake:m"] == "0@ok" }
            await h.settle()

            // The next read finds it broken: the repair rolls out.
            h.fakeFacts.set(HealthKey.self, "broken")
            await h.advance(.seconds(10))
            #expect(rollouts(h) == ["0@ok", "0@broken"])

            // The read after sees the repair: one more rollout, then nothing.
            h.fakeFacts.set(HealthKey.self, "ok")
            await h.advance(.seconds(10))
            #expect(rollouts(h) == ["0@ok", "0@broken", "0@ok"])
            let passes = h.engine.passCount
            for _ in 0..<6 {
                await h.advance(.seconds(10))
            }
            #expect(rollouts(h).count == 3)
            #expect(h.engine.passCount == passes)
        }
    }

    // MARK: - Records

    @Test func aMonitoredValueIsRecordedAndComparedAfterARestart() async throws {
        let directory = try TemporaryDirectory()
        let h = monitoredHarness(directory.recordsURL)
        await h.start()
        await eventually("m at ok") { h.machine.state["fake:m"] == "0@ok" }
        await h.settle()
        #expect(h.diskRecord("fake:m")?.snapshot == snapshot("0", health: "ok"))

        // The same value at launch: nothing to do.
        await h.restart()
        await h.settle()
        #expect(rollouts(h) == ["0@ok"])
        #expect(h.logs("astrolabe.records.undecodable").isEmpty)

        // It drifted while the daemon was down: one rollout, toward the same hash.
        await h.stop()
        h.fakeFacts.set(HealthKey.self, "drifted")
        let before = started(h)
        await h.restart()
        await eventually("m at drifted") { h.machine.state["fake:m"] == "0@drifted" }
        await h.settle()
        #expect(started(h) == before + 1)
        #expect(rollouts(h) == ["0@ok", "0@drifted"])
        #expect(h.diskRecord("fake:m")?.hash == hash("0"))
        await h.stop()
    }

    @Test func aRecordWrittenBeforeTheMonitorExistedDecodesAndRollsOutOnce() async throws {
        let directory = try TemporaryDirectory()
        let old = Record(kind: MonitoredFake.kind, hash: hash("0"), snapshot: snapshot("0", health: nil))
        try RecordStore(url: directory.recordsURL).set("fake:m", old)

        let h = monitoredHarness(directory.recordsURL)
        await h.start()
        await eventually("m at ok") { h.machine.state["fake:m"] == "0@ok" }
        await h.settle()
        #expect(h.logs("astrolabe.records.undecodable").isEmpty)
        #expect(h.diskRecord("fake:m")?.snapshot == snapshot("0", health: "ok"))

        await h.advance(.seconds(60))
        #expect(rollouts(h) == ["0@ok"])
        await h.stop()
    }

    // MARK: - Failures

    @Test func aFailedRepairBacksOffAndItsRetryCarriesTheLatestValue() async throws {
        try await withMonitored { h in
            await eventually("m at ok") { h.machine.state["fake:m"] == "0@ok" }
            await h.settle()

            h.machine.fail("fake:m", times: 2)
            h.state.health = "broken"
            await eventually("first failure") { h.engine.slots["fake:m"]?.failure?.attempts == 1 }
            await h.settle()

            // Another change waits out the backoff, and keeps counting attempts.
            h.state.health = "worse"
            await h.settle()
            #expect(h.engine.lastPlan.holds.map(\.hold) == [.backoff(attempts: 1)])
            #expect(rollouts(h) == ["0@ok", "0@broken"])

            await h.advance(.seconds(15))
            await eventually("second failure") { h.engine.slots["fake:m"]?.failure?.attempts == 2 }
            #expect(rollouts(h) == ["0@ok", "0@broken", "0@worse"])

            await h.advance(.seconds(30))
            await eventually("m at worse") { h.machine.state["fake:m"] == "0@worse" }
            await h.settle()
            #expect(rollouts(h) == ["0@ok", "0@broken", "0@worse", "0@worse"])
            #expect(h.engine.slots["fake:m"]?.failure == nil)
        }
    }

    @Test func underRollbackAFailedRepairRetriesWithoutRollingBack() async throws {
        try await withMonitored(MonitoredRollbackFake.self) { h in
            await eventually("m at ok") { h.machine.state["fake:m"] == "0@ok" }
            await h.settle()

            // The declared hash is the last success: there is nothing older to go back to.
            h.machine.fail("fake:m")
            h.state.health = "broken"
            await eventually("failed") { h.engine.slots["fake:m"]?.failure != nil }
            await h.settle()
            #expect(h.machine.calls("fake:m").map(\.op) == [.rollout, .rollout])

            await h.advance(.seconds(15))
            await eventually("m at broken") { h.machine.state["fake:m"] == "0@broken" }
            await h.settle()
            #expect(h.machine.calls("fake:m").map(\.op) == [.rollout, .rollout, .rollout])
            #expect(rollouts(h) == ["0@ok", "0@broken", "0@broken"])
            #expect(h.logs("astrolabe.rollback.failed").isEmpty)
        }
    }

    // MARK: - Reporting

    @Test func aDryRunMarksAMonitorOnlyRollout() async throws {
        let directory = try TemporaryDirectory()
        let old = Record(kind: MonitoredFake.kind, hash: hash("0"), snapshot: snapshot("0", health: "drifted"))
        try RecordStore(url: directory.recordsURL).set("fake:m", old)

        let h = EngineHarness<MonitoredApp<MonitoredFake>>(recordsURL: directory.recordsURL, mode: .dryRun)
        h.fakeFacts.set(HealthKey.self, "ok")
        await h.start()
        let monitorOnly = h.engine.dryRunReport(h.engine.lastPlan)
        #expect(monitorOnly.contains("rollout fake:m@\(hash("0").prefix(12)) (monitor)"))

        h.state.tracked = 1
        await h.settle()
        let declared = h.engine.dryRunReport(h.engine.lastPlan)
        #expect(declared.contains("rollout fake:m@\(hash("1").prefix(12))"))
        #expect(!declared.contains("(monitor)"))
        #expect(h.machine.calls.isEmpty)
        await h.stop()
    }

    @Test func aMonitorBuiltOutsideBodyIsReported() async throws {
        try await withEngine(PrebuiltApp.self, before: { $0.fakeFacts.set("prebuilt", [MonitoredFake(name: "m", value: "0")]) }) { h in
            await eventually("m rolled out") { h.machine.state["fake:m"] == "0@-" }
            await h.settle()
            let logged = try #require(h.logs("astrolabe.declaration.unobserved_monitor").first)
            #expect(logged.level == .error)
            #expect(logged.attributes["astrolabe.resource.kind"] == .string(MonitoredFake.kind))
        }
    }
}
