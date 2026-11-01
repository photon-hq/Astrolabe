import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fixtures

private func v(_ string: String) -> CLTVersion { CLTVersion(string)! }

/// The record hash of `HomebrewInstall(owner:)`.
private func hash(_ owner: String) -> String {
    HomebrewInstall.compute(HomebrewInstall(owner: owner))
}

private let homebrewResourceTypes: [any Resource.Type] =
    fakeResourceTypes + [CommandLineToolsInstall.self, HomebrewInstall.self]

private func readOwners() async throws -> [String] {
    try await HomebrewReads.owners()
}

/// A `HomebrewInstall` as a pass that read `owners` would build it.
private func install(_ owner: String, owners: [String]) throws -> HomebrewInstall {
    let json = try JSONEncoder().encode(["owner": .string(owner), "owners": .array(owners.map(JSONValue.string))] as [String: JSONValue])
    return try JSONDecoder().decode(HomebrewInstall.self, from: json)
}

/// `HomebrewInstaller.ensure(owner:)` on `brew`, with CLT from `clt`: installed unless given.
@MainActor
private func ensure(_ owner: String, _ brew: FakeHomebrewSystem, clt: FakeCLTSystem? = nil) async throws {
    try await withCLT(clt ?? FakeCLTSystem(installed: v("26.4.1"))) { _ in
        try await withHomebrew(brew) { _ in try await HomebrewInstaller.ensure(owner: owner) }
    }
}

/// CLT and Homebrew owned by `ops`, as a farm app declares them.
private struct FarmApp: Astrolabe {
    var body: some Component {
        CommandLineTools()
        Homebrew(owner: "ops")
    }
}

/// Homebrew without `CommandLineTools()`: it waits forever.
private struct HomebrewOnlyApp: Astrolabe {
    var body: some Component {
        Homebrew(owner: "ops")
    }
}

/// Owned by `ops` while `test.tracked` is 0, by `bob` at 1, and dropped after that.
private struct SwitchingOwnerApp: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        CommandLineTools()
        switch test.tracked {
        case 0: Homebrew(owner: "ops")
        case 1: Homebrew(owner: "bob")
        default: EmptyComponent()
        }
    }
}

@MainActor
private func started<App>(_ h: EngineHarness<App>) -> Int {
    h.logs("astrolabe.operation.started").count
}

@Suite(.timeLimit(.minutes(1)))
struct HomebrewTests {
    // MARK: - Resource

    @MainActor
    struct InstallResource {
        @Test func thereIsOnePerMac() {
            #expect(HomebrewInstall(owner: "ops").id == "homebrew")
            #expect(HomebrewInstall(owner: "bob").id == "homebrew")
        }

        @Test func theHashMovesOnlyWithTheOwner() throws {
            #expect(hash("ops") == hash("ops"))
            #expect(hash("ops") != hash("bob"))
            let healthy = try install("ops", owners: ["ops"])
            let mixed = try install("ops", owners: ["bob", "ops"])
            #expect(HomebrewInstall.compute(healthy) == hash("ops"))
            #expect(HomebrewInstall.compute(mixed) == hash("ops"))
        }

        @Test func theSnapshotRecordsTheOwnerAndWhatTheMonitorRead() throws {
            #expect(try AnyResource(install("ops", owners: ["ops"])).encode() == .object([
                "owner": .string("ops"), "owners": .array([.string("ops")]),
            ]))
            #expect(try AnyResource(install("ops", owners: [])).encode() == .object([
                "owner": .string("ops"), "owners": .array([]),
            ]))
            // Unread: left out, so it stays apart from a read `[]`.
            #expect(try AnyResource(HomebrewInstall(owner: "ops")).encode() == .object(["owner": .string("ops")]))
        }

        @Test func removeLeavesHomebrewAlone() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withHomebrew(brew) { _ in try await HomebrewInstall.remove(HomebrewInstall(owner: "ops")) }
            #expect(brew.calls.isEmpty)
        }
    }

    // MARK: - owners

    @MainActor
    struct OwnersRead {
        @Test func itIsEmptyWithoutBrew() async throws {
            let owners = try await withHomebrew(FakeHomebrewSystem()) { _ in try await readOwners() }
            #expect(owners == [])
        }

        @Test func itIsTheOwnerWhenHealthy() async throws {
            let owners = try await withHomebrew(FakeHomebrewSystem(owner: "ops")) { _ in try await readOwners() }
            #expect(owners == ["ops"])
        }

        @Test func everyOwnerIsListedOnceInOrder() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("jq", owner: "bob")
            brew.addFormula("wget", owner: "bob")
            brew.addFormula("ripgrep", owner: "alice")
            let owners = try await withHomebrew(brew) { _ in try await readOwners() }
            #expect(owners == ["alice", "bob", "ops"])
        }

        @Test func aFailedReadThrowsRatherThanReadingAsMissing() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.fail(.owners)
            try await withHomebrew(brew) { _ in
                await #expect(throws: FakeHomebrewSystem.FakeError.self) { try await readOwners() }
            }
        }

        @Test func itWaitsOutAnInstall() async throws {
            let brew = FakeHomebrewSystem()
            brew.hold(.runInstallScript)
            try await withCLT(FakeCLTSystem(installed: v("26.4.1"))) { _ in
                try await withHomebrew(brew) { _ in
                    let rollout = Task { try await HomebrewInstaller.ensure(owner: "ops") }
                    await eventually("installing") { brew.installs == ["ops"] }
                    // `brew` is there but the script isn't done: a read now would act on it.
                    #expect(brew.ownersOnMac == ["ops"])
                    let reads = brew.count(.owners)
                    let reading = Task { try await readOwners() }
                    await realSleep(.milliseconds(50))
                    #expect(brew.count(.owners) == reads, "the read waits out the install")

                    brew.release(.runInstallScript)
                    try await rollout.value
                    #expect(try await reading.value == ["ops"])
                    // It read the Mac once the rollout had checked its work, and not before.
                    #expect(Array(brew.calls.suffix(2)) == [.brewVersion("ops"), .owners])
                }
            }
        }
    }

    // MARK: - ensure

    @MainActor
    struct Ensure {
        @Test func whenHealthyItChangesNothingAndTakesNoLock() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { context in
                    try await context.lock.waitUnlessCancelled()  // held throughout: waiting on it would hang
                    let rollout = Task { try await HomebrewInstaller.ensure(owner: "ops") }
                    await eventually("checked") { brew.count(.brewVersion("ops")) == 1 }
                    await realSleep(.milliseconds(20))
                    rollout.cancel()
                    let result = await rollout.result
                    context.lock.signal()
                    #expect((try? result.get()) != nil, "returned without waiting on the lock")
                }
            }
            #expect(brew.calls == [.owners, .brewVersion("ops")])
            #expect(clt.calls.isEmpty, "no CLT check")
        }

        @Test func aFreshMacGetsHomebrewOwnedByTheOwner() async throws {
            let brew = FakeHomebrewSystem()
            try await ensure("ops", brew)
            #expect(brew.ownersOnMac == ["ops"])
            #expect(brew.inPaths)
            #expect(brew.calls == [
                .owners,  // the Mac first, without the lock
                .owners,  // again under it
                .owners,  // missing: install
                .createPrefix, .reown("ops"), .runInstallScript("ops"), .addToPaths,
                .owners, .brewVersion("ops"),  // verify
            ])
        }

        @Test func whatABrokenInstallLeftIsGivenToTheOwnerBeforeTheScriptRuns() async throws {
            let brew = FakeHomebrewSystem(owner: "bob")
            brew.addFormula("jq", owner: "bob")
            brew.deleteBrewCommand()
            try await ensure("ops", brew)
            #expect(brew.ownersOnMac == ["ops"])
            #expect(brew.installs == ["ops"])
        }

        @Test func aFailedInstallScriptThrows() async throws {
            let brew = FakeHomebrewSystem()
            brew.fail(.runInstallScript)
            await #expect(throws: FakeHomebrewSystem.FakeError.self) { try await ensure("ops", brew) }
            #expect(brew.count(.addToPaths) == 0)
            #expect(brew.ownersOnMac == [])
        }

        @Test func aCancelledInstallLeavesNothingMarkedInstalling() async throws {
            let brew = FakeHomebrewSystem()
            brew.hold(.runInstallScript)
            try await withCLT(FakeCLTSystem(installed: v("26.4.1"))) { _ in
                try await withHomebrew(brew) { context in
                    let rollout = Task { try await HomebrewInstaller.ensure(owner: "ops") }
                    await eventually("installing") { brew.installs.count == 1 }
                    #expect(context.installing.withLock { $0 })
                    rollout.cancel()
                    await #expect(throws: CancellationError.self) { try await rollout.value }
                    #expect(!context.installing.withLock { $0 })
                    #expect(brew.count(.addToPaths) == 0)
                }
            }
        }

        @Test func anUnknownOwnerThrowsBeforeTouchingTheMac() async throws {
            let brew = FakeHomebrewSystem()
            await #expect(throws: HomebrewError.unknownOwner("nobody")) { try await ensure("nobody", brew) }
            #expect(brew.calls.isEmpty)
        }

        @Test func rootIsRefusedAsTheOwner() async throws {
            let brew = FakeHomebrewSystem()
            await #expect(throws: HomebrewError.ownerIsRoot("root")) { try await ensure("root", brew) }
            #expect(brew.calls.isEmpty)
        }

        @Test func anIntelMacThrowsBeforeTouchingTheMac() async throws {
            let brew = FakeHomebrewSystem()
            brew.appleSilicon = false
            await #expect(throws: HomebrewError.unsupportedArchitecture) { try await ensure("ops", brew) }
            #expect(brew.calls.isEmpty)
        }

        @Test func withoutCLTItThrowsAndNeverInstallsCLT() async throws {
            let brew = FakeHomebrewSystem()
            let clt = FakeCLTSystem(catalog: [v("26.4.1")])
            await #expect(throws: HomebrewError.commandLineToolsMissing) { try await ensure("ops", brew, clt: clt) }
            #expect(brew.calls == [.owners])
            #expect(clt.calls == [.installedVersion])
        }

        @Test func aCLTInstallInProgressIsWaitedOut() async throws {
            let clt = FakeCLTSystem(catalog: [v("26.4.1")])
            clt.hold(.install)
            let brew = FakeHomebrewSystem()
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    let cltRollout = Task { try await CLTInstaller.ensure(minimum: nil) }
                    await eventually("CLT installing") { clt.installs.count == 1 }
                    // The receipt already shows 26.4.1, but CLT isn't all there yet.
                    let rollout = Task { try await HomebrewInstaller.ensure(owner: "ops") }
                    await realSleep(.milliseconds(50))
                    #expect(brew.changes.isEmpty, "waits for CLT before changing anything")

                    clt.release(.install)
                    try await cltRollout.value
                    try await rollout.value
                    #expect(brew.installs == ["ops"])
                }
            }
        }

        @Test func anotherAdminsFormulaIsGivenBackWithoutInstalling() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("jq", owner: "bob")
            try await ensure("ops", brew)
            #expect(brew.changes == [.reown("ops")])
            #expect(brew.ownersOnMac == ["ops"])
        }

        @Test func aNewOwnerIsGivenThePrefixWithoutInstalling() async throws {
            let brew = FakeHomebrewSystem(owner: "alice")
            brew.addFormula("jq", owner: "alice")
            try await ensure("bob", brew)
            #expect(brew.changes == [.reown("bob")])
            #expect(brew.ownersOnMac == ["bob"])
        }

        @Test func aReownThatDidNotTakeThrows() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("jq", owner: "bob")
            brew.reownDoesNotTake()
            await #expect(throws: HomebrewError.didNotTake(expected: "ops", owners: ["bob", "ops"])) {
                try await ensure("ops", brew)
            }
        }

        @Test func aBrewThatWontRunIsReownedThenThrows() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.brewRuns = false
            await #expect(throws: HomebrewError.brewDoesNotRun(owner: "ops")) { try await ensure("ops", brew) }
            #expect(brew.changes == [.reown("ops")])
        }
    }

    // MARK: - Lock

    @MainActor
    struct Lock {
        @Test func twoRolloutsStartedTogetherInstallOnce() async throws {
            let brew = FakeHomebrewSystem()
            try await withCLT(FakeCLTSystem(installed: v("26.4.1"))) { _ in
                try await withHomebrew(brew) { _ in
                    async let first: Void = HomebrewInstaller.ensure(owner: "ops")
                    async let second: Void = HomebrewInstaller.ensure(owner: "ops")
                    _ = try await (first, second)
                }
            }
            #expect(brew.installs == ["ops"])
        }

        @Test func aRolloutStartedMidInstallWaitsThenFindsItHealthy() async throws {
            let brew = FakeHomebrewSystem()
            brew.hold(.runInstallScript)
            try await withCLT(FakeCLTSystem(installed: v("26.4.1"))) { _ in
                try await withHomebrew(brew) { _ in
                    let first = Task { try await HomebrewInstaller.ensure(owner: "ops") }
                    await eventually("installing") { brew.installs.count == 1 }
                    // `brew` already runs, but the install isn't done: the second must not trust it.
                    let second = Task { try await HomebrewInstaller.ensure(owner: "ops") }
                    await eventually("second checked") { brew.count(.brewVersion("ops")) == 1 }
                    let calls = brew.calls.count
                    await realSleep(.milliseconds(50))
                    #expect(brew.calls.count == calls, "the second waits on the lock")

                    brew.release(.runInstallScript)
                    try await first.value
                    try await second.value
                    #expect(brew.installs == ["ops"])
                    #expect(brew.changes == [.createPrefix, .reown("ops"), .runInstallScript("ops"), .addToPaths])
                }
            }
        }

        @Test func cancellingARolloutWaitingOnTheLockChangesNothing() async throws {
            let brew = FakeHomebrewSystem()
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { context in
                    try await context.lock.waitUnlessCancelled()
                    let rollout = Task { try await HomebrewInstaller.ensure(owner: "ops") }
                    await eventually("checked CLT") { clt.count(.installedVersion) == 1 }
                    await realSleep(.milliseconds(20))
                    rollout.cancel()
                    await #expect(throws: CancellationError.self) { try await rollout.value }
                    context.lock.signal()
                    #expect(brew.calls == [.owners])
                }
            }
        }
    }

    // MARK: - Engine

    @MainActor
    struct InEngine {
        @Test func aFreshMacGetsCLTThenHomebrew() async throws {
            let clt = FakeCLTSystem(catalog: [v("26.4.1")])
            let brew = FakeHomebrewSystem()
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: homebrewResourceTypes) { h in
                        // CLT first. Homebrew waits for the next `installed` read.
                        await eventually("CLT installed") { clt.installed == v("26.4.1") }
                        await h.settle()
                        #expect(h.diskRecord("homebrew") == nil)
                        #expect(brew.calls.isEmpty)

                        await h.advance(.seconds(60))
                        await eventually("Homebrew installed") { brew.ownersOnMac == ["ops"] }
                        await h.settle()
                        #expect(brew.installs == ["ops"])
                        #expect(h.diskRecord("homebrew")?.hash == hash("ops"))
                        #expect(h.diskRecord("commandLineTools") != nil)
                        let before = started(h)

                        // The next read sees it: one rollout, which changes nothing.
                        await h.advance(.seconds(60))
                        #expect(started(h) == before + 1)
                        #expect(h.diskRecord("homebrew")?.snapshot == .object([
                            "owner": .string("ops"), "owners": .array([.string("ops")]),
                        ]))
                        await h.advance(.seconds(60))
                        #expect(started(h) == before + 1)
                        #expect(brew.installs == ["ops"])
                        #expect(clt.installs == [v("26.4.1")])
                    }
                }
            }
        }

        @Test func withoutCommandLineToolsHomebrewIsNeverDeclared() async throws {
            let clt = FakeCLTSystem(catalog: [v("26.4.1")])
            let brew = FakeHomebrewSystem()
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(HomebrewOnlyApp.self, resourceTypes: homebrewResourceTypes) { h in
                        await h.advance(.seconds(60))
                        await h.advance(.seconds(60))
                        #expect(h.diskRecord("homebrew") == nil)
                        #expect(h.engine.lastPlan.actions.isEmpty)
                        #expect(brew.calls.isEmpty)
                        #expect(clt.installs.isEmpty)
                    }
                }
            }
        }

        @Test func aRestartWithBothInPlaceIsIdle() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: homebrewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord("homebrew") != nil }
                        await h.settle()
                        let before = started(h)

                        // A new launch starts over, with fresh contexts.
                        try await withCLT(clt) { _ in try await withHomebrew(brew) { _ in await h.restart() } }
                        #expect(started(h) == before)
                        #expect(brew.changes.isEmpty)
                        #expect(clt.installs.isEmpty)
                    }
                }
            }
        }

        @Test func aDeletedHomebrewIsInstalledAgain() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: homebrewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord("homebrew") != nil }
                        await h.settle()
                        let before = started(h)

                        brew.deleteBrew()
                        await h.advance(.seconds(60))
                        await eventually("installed again") { brew.ownersOnMac == ["ops"] }
                        await h.settle()
                        #expect(brew.installs == ["ops"])
                        #expect(started(h) == before + 1)
                        #expect(h.diskRecord("homebrew")?.hash == hash("ops"))

                        // The read after sees it back: exactly one more rollout, which does nothing.
                        await h.advance(.seconds(60))
                        #expect(started(h) == before + 2)
                        await h.advance(.seconds(60))
                        #expect(started(h) == before + 2)
                        #expect(brew.installs == ["ops"])
                    }
                }
            }
        }

        @Test func anotherAdminsFormulaIsGivenBack() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: homebrewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord("homebrew") != nil }
                        await h.settle()
                        let before = started(h)

                        brew.addFormula("jq", owner: "bob")
                        await h.advance(.seconds(60))
                        await eventually("given back") { brew.ownersOnMac == ["ops"] }
                        await h.settle()
                        #expect(brew.changes == [.reown("ops")])
                        #expect(started(h) == before + 1)

                        await h.advance(.seconds(60))
                        #expect(started(h) == before + 2)
                        #expect(brew.changes == [.reown("ops")])
                    }
                }
            }
        }

        @Test func aNewOwnerInBodyReownsAndDroppingItLeavesHomebrew() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(SwitchingOwnerApp.self, resourceTypes: homebrewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord("homebrew")?.hash == hash("ops") }
                        await h.settle()

                        h.state.tracked = 1
                        await eventually("owned by bob") { h.diskRecord("homebrew")?.hash == hash("bob") }
                        await h.settle()
                        #expect(brew.changes == [.reown("bob")])
                        #expect(brew.ownersOnMac == ["bob"])

                        // Dropped: removed from the records, and Homebrew is left alone.
                        h.state.tracked = 2
                        await eventually("record removed") { h.diskRecord("homebrew") == nil }
                        await h.settle()
                        #expect(brew.changes == [.reown("bob")])
                        #expect(brew.ownersOnMac == ["bob"])
                    }
                }
            }
        }

        @Test func aDeletedCLTClosesTheGateUntilItIsBack() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.4.1")])
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: homebrewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord("homebrew") != nil }
                        await h.settle()

                        // Undeclared, which removes nothing; CLT is installed again.
                        clt.deleteFiles()
                        await h.advance(.seconds(60))
                        await eventually("homebrew undeclared") { h.diskRecord("homebrew") == nil }
                        await eventually("CLT back") { clt.installed == v("26.4.1") }
                        await h.settle()
                        #expect(clt.installs == [v("26.4.1")])

                        // The next read reopens the gate, and Homebrew is healthy.
                        await h.advance(.seconds(60))
                        await eventually("homebrew declared") { h.diskRecord("homebrew")?.hash == hash("ops") }
                        await h.settle()
                        #expect(brew.changes.isEmpty)
                        #expect(brew.ownersOnMac == ["ops"])
                    }
                }
            }
        }

        // MARK: Dry run

        @Test func aDryRunShowsTheInstall() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem()
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, mode: .dryRun, resourceTypes: homebrewResourceTypes) { h in
                        let report = h.engine.dryRunReport(h.engine.lastPlan)
                        #expect(report.split(separator: "\n").contains("  rollout homebrew@\(hash("ops").prefix(12))"))
                        #expect(brew.changes.isEmpty)
                    }
                }
            }
        }

        @Test func aDryRunMarksARepairAsAMonitorRollout() async throws {
            let directory = try TemporaryDirectory()
            let store = RecordStore(url: directory.recordsURL)
            let cltHash = CommandLineToolsInstall.compute(CommandLineToolsInstall(minimum: nil))
            try store.set("commandLineTools", Record(kind: CommandLineToolsInstall.kind, hash: cltHash, snapshot: .object(["isInstalled": .bool(true)])))
            try store.set("homebrew", Record(kind: HomebrewInstall.kind, hash: hash("ops"), snapshot: .object([
                "owner": .string("ops"), "owners": .array([.string("ops")]),
            ])))
            // Deleted while the daemon was down.
            let brew = FakeHomebrewSystem()
            try await withCLT(FakeCLTSystem(installed: v("26.4.1"))) { _ in
                try await withHomebrew(brew) { _ in
                    let h = EngineHarness<FarmApp>(recordsURL: directory.recordsURL, mode: .dryRun, resourceTypes: homebrewResourceTypes)
                    await h.start()
                    let report = h.engine.dryRunReport(h.engine.lastPlan)
                    #expect(report.split(separator: "\n").contains("  rollout homebrew@\(hash("ops").prefix(12)) (monitor)"))
                    #expect(!report.contains("commandLineTools"))
                    #expect(brew.changes.isEmpty)
                    await h.stop()
                }
            }
        }
    }
}
