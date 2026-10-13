import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fixtures

private func v(_ string: String) -> CLTVersion { CLTVersion(string)! }

private func product(_ version: String) -> CLTProduct {
    CLTProduct(label: "Command Line Tools for Xcode-\(version)", version: v(version))
}

/// The record hash of `CommandLineToolsInstall(minimum:)`.
private func hash(_ minimum: CLTVersion?) -> String {
    CommandLineToolsInstall.compute(CommandLineToolsInstall(minimum: minimum))
}

private let cltResourceTypes: [any Resource.Type] = fakeResourceTypes + [CommandLineToolsInstall.self]

private func readInstalled() async throws -> CLTVersion? {
    try await CommandLineToolsReads.installed()
}

private func readLatestAvailable() async throws -> CLTVersion? {
    try await CommandLineToolsReads.latestAvailable()
}

/// Runs `body` with a fresh `CommandLineToolsContext` over `fake`: what one launch of the daemon
/// shares. Tasks created inside inherit it.
@MainActor @discardableResult
private func withCLT<T>(
    _ fake: FakeCLTSystem,
    _ body: (CommandLineToolsContext) async throws -> T
) async throws -> T {
    let context = CommandLineToolsContext(system: fake)
    return try await CommandLineToolsContext.$current.withValue(context) {
        try await body(context)
    }
}

/// Holds a rollout mid-install, its receipt already written, and issues `read` then. The read
/// must wait for the install to finish, then report it.
@MainActor
private func readDuringAnInstall(_ read: @escaping @Sendable () async throws -> CLTVersion?) async throws {
    let fake = FakeCLTSystem(catalog: [v("26.4.1")])
    fake.hold(.install)
    try await withCLT(fake) { _ in
        let rollout = Task { try await CLTInstaller.ensure(minimum: nil) }
        await eventually("install started") { fake.installs == [v("26.4.1")] }
        // A read that didn't wait would report the half-finished 26.4.1 now.
        #expect(fake.installed == v("26.4.1"))
        let reads = fake.count(.installedVersion)
        let reading = Task { try await read() }
        await realSleep(.milliseconds(50))
        #expect(fake.count(.installedVersion) == reads, "the read waits out the install")

        fake.release(.install)
        try await rollout.value
        #expect(try await reading.value == v("26.4.1"))
        // It read the Mac once the rollout had verified and selected CLT, and not before.
        #expect(Array(fake.calls.drop { $0 != .ensureSelected }.dropFirst()) == [.installedVersion])
    }
}

private let macOS15Listing = """
    Software Update Tool

    Finding available software
    Software Update found the following new or updated software:
    * Label: Command Line Tools for Xcode-16.3
    \tTitle: Command Line Tools for Xcode, Version: 16.3, Size: 750012KiB, Recommended: YES,
    * Label: Command Line Tools for Xcode-16.4
    \tTitle: Command Line Tools for Xcode, Version: 16.4, Size: 751282KiB, Recommended: YES,
    * Label: macOS Sequoia 15.6-24G84
    \tTitle: macOS Sequoia, Version: 15.6, Size: 5242880KiB, Recommended: YES, Action: restart,
    """

/// Newest first, so v1's "last label" would pick 26.3. Includes a beta.
private let macOS26Listing = """
    Software Update Tool

    Finding available software
    Software Update found the following new or updated software:
    * Label: Command Line Tools for Xcode 26.4-26.4.1
    \tTitle: Command Line Tools for Xcode 26.4, Version: 26.4.1, Size: 920104KiB, Recommended: YES,
    * Label: Command Line Tools beta 2 for Xcode 26.5-26.5
    \tTitle: Command Line Tools beta 2 for Xcode 26.5, Version: 26.5, Size: 931840KiB, Recommended: YES,
    * Label: Command Line Tools for Xcode 26.3-26.3
    \tTitle: Command Line Tools for Xcode 26.3, Version: 26.3, Size: 911360KiB, Recommended: YES,
    """

/// `CommandLineTools()`: reads no fact.
private struct InstalledApp: Astrolabe {
    var body: some Component {
        CommandLineTools()
    }
}

/// `.latest` while `test.tracked` is 0, `.installed` at 1, and nothing after that.
private struct SwitchingApp: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        switch test.tracked {
        case 0: CommandLineTools(version: .latest)
        case 1: CommandLineTools()
        default: EmptyComponent()
        }
    }
}

/// A resource that redoes its work after a CLT update: the intended use of `installed`.
private struct DependentApp: Astrolabe {
    @Fact(\.commandLineTools.installed) var installed

    var body: some Component {
        CommandLineTools(version: .latest)
        RetryFake("dependent", installed?.description ?? "none")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CommandLineToolsTests {
    // MARK: - Listing

    @MainActor
    struct Listing {
        @Test func macOS15ProductsAreReadByLabelAndVersion() {
            #expect(SoftwareUpdateListing.commandLineTools(in: macOS15Listing) == [
                CLTProduct(label: "Command Line Tools for Xcode-16.3", version: v("16.3")),
                CLTProduct(label: "Command Line Tools for Xcode-16.4", version: v("16.4")),
            ])
        }

        @Test func macOS26ProductsAreReadByTheirVersionFieldWithoutBetas() {
            let products = SoftwareUpdateListing.commandLineTools(in: macOS26Listing)
            #expect(products == [
                CLTProduct(label: "Command Line Tools for Xcode 26.4-26.4.1", version: v("26.4.1")),
                CLTProduct(label: "Command Line Tools for Xcode 26.3-26.3", version: v("26.3")),
            ])
            #expect(products.map(\.version).max() == v("26.4.1"))
        }

        @Test func noNewSoftwareListsNothing() {
            let listing = "Software Update Tool\n\nFinding available software\nNo new software available.\n"
            #expect(SoftwareUpdateListing.commandLineTools(in: listing).isEmpty)
        }

        @Test func aLabelWithoutATitleIsSkipped() {
            let listing = """
                * Label: Command Line Tools for Xcode-16.2
                * Label: Command Line Tools for Xcode-16.4
                \tTitle: Command Line Tools for Xcode, Version: 16.4, Size: 751282KiB, Recommended: YES,
                """
            #expect(SoftwareUpdateListing.commandLineTools(in: listing) == [product("16.4")])
        }
    }

    // MARK: - CLTVersion

    struct Versions {
        @Test func everySourceNormalizesToMajorMinorPatch() {
            #expect(v("26.4.1.0.1.1745106510") == v("26.4.1"))
            #expect(v("26.4.1.0.1.1745106510").description == "26.4.1")
            #expect(v("16.4") == v("16.4.0"))
            #expect(v("16.4").description == "16.4.0")
            #expect(v("26").description == "26.0.0")
        }

        @Test func versionsCompareNumerically() {
            #expect(v("26.10") > v("26.9"))
            #expect(v("26.4.1") > v("26.4"))
            #expect(v("27.0") > v("26.99.99"))
        }

        @Test func nonNumericPartsAreRejected() {
            for string in ["", "beta", "26.x", "26..1", "-1.0", "+1.2", "26.4b"] {
                #expect(CLTVersion(string) == nil, "\(string)")
            }
        }

        @Test func itIsCodedAsItsDescription() throws {
            let data = try JSONEncoder().encode(v("26.4.1.0.1.1745106510"))
            #expect(String(decoding: data, as: UTF8.self) == "\"26.4.1\"")
            #expect(try JSONDecoder().decode(CLTVersion.self, from: Data("\"16.4\"".utf8)) == v("16.4.0"))
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(CLTVersion.self, from: Data("\"beta\"".utf8))
            }
        }

        @Test func theReceiptVersionIsReadFromPkgutil() {
            let pkgInfo = """
                package-id: com.apple.pkg.CLTools_Executables
                version: 26.4.1.0.1.1745106510
                volume: /
                location: /
                install-time: 1745200000
                """
            #expect(SoftwareUpdateCLT.receiptVersion(in: pkgInfo) == v("26.4.1"))
            #expect(SoftwareUpdateCLT.receiptVersion(in: "package-id: com.apple.pkg.CLTools_Executables\n") == nil)
        }
    }

    // MARK: - CatalogCheck

    struct Catalog {
        @Test func theFirstReadSinceLaunchNeverChecks() {
            var check = CatalogCheck()
            let start = ContinuousClock.now
            let checks = [check.begin(at: start), check.begin(at: start)]
            #expect(checks == [false, true])
        }

        @Test func aCheckIsDueSixHoursAfterTheLast() {
            var check = CatalogCheck()
            let start = ContinuousClock.now
            _ = check.begin(at: start)
            let first = check.begin(at: start)
            check.checked([product("26.4.1"), product("26.5")], at: start)
            let checks = [check.begin(at: start + .seconds(6 * 3600 - 1)), check.begin(at: start + .seconds(6 * 3600))]
            #expect(first)
            #expect(check.latestOffered == v("26.5"))
            #expect(checks == [false, true])
        }

        @Test func aCheckThatNeverFinishedStaysDue() {
            var check = CatalogCheck()
            let start = ContinuousClock.now
            let checks = [check.begin(at: start), check.begin(at: start), check.begin(at: start + .seconds(1))]
            #expect(checks == [false, true, true])
        }

        @Test func aListingWithoutCLTClearsTheLatestOffered() {
            var check = CatalogCheck()
            let start = ContinuousClock.now
            check.checked([product("26.5")], at: start)
            check.checked([], at: start + .seconds(6 * 3600))
            #expect(check.latestOffered == nil)
        }
    }

    // MARK: - installed

    @MainActor
    struct InstalledRead {
        @Test func itIsNilWithoutAReceipt() async throws {
            let installed = try await withCLT(FakeCLTSystem()) { _ in try await readInstalled() }
            #expect(installed == nil)
        }

        @Test func itIsNilWhenTheFilesAreGone() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"))
            fake.deleteFiles()
            let installed = try await withCLT(fake) { _ in try await readInstalled() }
            #expect(installed == nil)
        }

        @Test func itIsTheReceiptVersion() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.5")])
            let installed = try await withCLT(fake) { _ in try await readInstalled() }
            #expect(installed == v("26.4.1"))
            #expect(fake.calls == [.installedVersion])
        }

        @Test func aFailedReadThrowsRatherThanReadingAsMissing() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"))
            fake.fail(.installedVersion)
            try await withCLT(fake) { _ in
                await #expect(throws: FakeCLTSystem.FakeError.self) { try await readInstalled() }
            }
        }

        @Test func itWaitsOutAnInstall() async throws {
            try await readDuringAnInstall { try await readInstalled() }
        }
    }

    // MARK: - latestAvailable

    @MainActor
    struct LatestAvailableRead {
        @Test func theFirstReadNeverListsTheCatalog() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.5")])
            try await withCLT(fake) { _ in
                let launch = try await readLatestAvailable()
                #expect(launch == v("26.4.1"))
                #expect(fake.calls == [.installedVersion])

                // The next read checks: the newest listed beats the installed version.
                let checked = try await readLatestAvailable()
                #expect(checked == v("26.5"))
                #expect(fake.count(.list) == 1)
                #expect(!fake.triggerPlaced)

                // The one after uses that check.
                let cached = try await readLatestAvailable()
                #expect(cached == v("26.5"))
                #expect(fake.count(.list) == 1)
            }
        }

        @Test func onAFreshMacItIsNilUntilTheCatalogIsChecked() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            try await withCLT(fake) { _ in
                let launch = try await readLatestAvailable()
                let checked = try await readLatestAvailable()
                #expect(launch == nil)
                #expect(checked == v("26.4.1"))
            }
        }

        @Test func theValueIsTheSameBeforeAndAfterAnInstall() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.4.1"), v("26.5")])
            try await withCLT(fake) { _ in
                _ = try await readLatestAvailable()
                let listed = try await readLatestAvailable()
                try await CLTInstaller.ensure(minimum: v("26.5"))
                let installed = try await readLatestAvailable()
                #expect(listed == v("26.5"))
                #expect(fake.installed == v("26.5"))
                #expect(installed == v("26.5"))
            }
            // The next launch's check no longer lists CLT: the value is the installed 26.5.
            try await withCLT(fake) { _ in
                let launch = try await readLatestAvailable()
                let checked = try await readLatestAvailable()
                #expect(launch == v("26.5"))
                #expect(checked == v("26.5"))
                #expect(fake.count(.list) == 3)
            }
        }

        @Test func aFailedListingThrowsAndStaysDue() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.5")])
            fake.fail(.list)
            try await withCLT(fake) { _ in
                _ = try await readLatestAvailable()
                await #expect(throws: FakeCLTSystem.FakeError.self) { try await readLatestAvailable() }
                #expect(!fake.triggerPlaced)
                let retried = try await readLatestAvailable()
                #expect(retried == v("26.5"))
                #expect(fake.count(.list) == 2)
            }
        }

        @Test func itNeverDropsBelowWhatIsInstalled() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.5")])
            try await withCLT(fake) { _ in
                _ = try await readLatestAvailable()
                let checked = try await readLatestAvailable()
                // Updated by hand past the last check.
                fake.setInstalled(v("26.6"))
                let cached = try await readLatestAvailable()
                #expect(checked == v("26.5"))
                #expect(cached == v("26.6"))
                #expect(fake.count(.list) == 1)
            }
        }

        @Test func itWaitsOutAnInstall() async throws {
            try await readDuringAnInstall { try await readLatestAvailable() }
        }
    }

    // MARK: - Rollout

    @MainActor
    struct Rollout {
        @Test func whenSatisfiedItTakesNoLockAndListsNothing() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.5")])
            try await withCLT(fake) { context in
                try await context.lock.waitUnlessCancelled()  // held throughout: waiting on it would hang
                let rollout = Task {
                    try await CLTInstaller.ensure(minimum: nil)
                    try await CLTInstaller.ensure(minimum: v("26.4"))
                }
                await eventually("both returned") { fake.count(.ensureSelected) == 2 }
                rollout.cancel()
                _ = await rollout.result
                context.lock.signal()
                #expect(fake.calls == [.installedVersion, .ensureSelected, .installedVersion, .ensureSelected])
            }
        }

        @Test func aFreshMacGetsTheNewestOffered() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.3"), v("26.4.1")])
            try await withCLT(fake) { _ in try await CLTInstaller.ensure(minimum: nil) }
            #expect(fake.installed == v("26.4.1"))
            #expect(fake.calls == [
                .installedVersion,  // the Mac first, without the lock
                .installedVersion,  // again under it
                .forgetStaleReceipts,
                .placeTrigger, .list, .install(v("26.4.1")), .removeTrigger,
                .installedVersion,  // verify
                .ensureSelected,
            ])
        }

        @Test func anUpdatePicksTheNewestAtOrAboveTheMinimum() async throws {
            let fake = FakeCLTSystem(installed: v("26.3"), catalog: [v("26.3.1"), v("26.4.1"), v("26.4")])
            try await withCLT(fake) { _ in try await CLTInstaller.ensure(minimum: v("26.4")) }
            #expect(fake.installs == [v("26.4.1")])
            #expect(fake.installed == v("26.4.1"))
        }

        @Test func nothingOfferedAtTheMinimumThrows() async throws {
            let fake = FakeCLTSystem(installed: v("26.3"), catalog: [v("26.4.1")])
            try await withCLT(fake) { _ in
                let error = await #expect(throws: CLTError.self) { try await CLTInstaller.ensure(minimum: v("26.5")) }
                guard case .notOffered(let minimum, let offered)? = error else {
                    Issue.record("expected .notOffered, got \(String(describing: error))")
                    return
                }
                #expect(minimum == v("26.5"))
                #expect(offered == [v("26.4.1")])
            }
            #expect(fake.installs.isEmpty)
            #expect(!fake.triggerPlaced)
        }

        @Test func anInstallThatDidNotTakeThrows() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            fake.installDoesNotTake()
            try await withCLT(fake) { _ in
                let error = await #expect(throws: CLTError.self) { try await CLTInstaller.ensure(minimum: nil) }
                guard case .didNotTake(let expected, let installed)? = error else {
                    Issue.record("expected .didNotTake, got \(String(describing: error))")
                    return
                }
                #expect(expected == v("26.4.1"))
                #expect(installed == nil)
            }
            #expect(fake.count(.ensureSelected) == 0)
        }

        @Test func aStaleReceiptIsForgottenBeforeListing() async throws {
            // softwareupdate offers nothing while the receipt says 26.4.1 is there.
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.4.1")])
            fake.deleteFiles()
            try await withCLT(fake) { _ in try await CLTInstaller.ensure(minimum: nil) }
            #expect(fake.installed == v("26.4.1"))
            let calls = fake.calls
            let forgot = try #require(calls.firstIndex(of: .forgetStaleReceipts))
            let listed = try #require(calls.firstIndex(of: .list))
            #expect(forgot < listed)
        }

        @Test func theTriggerIsRemovedWhenTheInstallThrows() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            fake.fail(.install)
            try await withCLT(fake) { _ in
                await #expect(throws: FakeCLTSystem.FakeError.self) { try await CLTInstaller.ensure(minimum: nil) }
            }
            #expect(fake.count(.placeTrigger) == 1)
            #expect(!fake.triggerPlaced)
        }

        @Test func theTriggerIsRemovedWhenTheRolloutIsCancelled() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            fake.hold(.install)
            try await withCLT(fake) { context in
                let rollout = Task { try await CLTInstaller.ensure(minimum: nil) }
                await eventually("installing") { fake.installs.count == 1 }
                #expect(fake.triggerPlaced)
                rollout.cancel()
                await #expect(throws: CancellationError.self) { try await rollout.value }
                #expect(!fake.triggerPlaced)
                #expect(!context.installing.withLock { $0 })
            }
        }

        @Test func ensureSelectedRunsInsideTheLock() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            fake.hold(.ensureSelected)
            try await withCLT(fake) { _ in
                let rollout = Task { try await CLTInstaller.ensure(minimum: nil) }
                await eventually("selecting") { fake.count(.ensureSelected) == 1 }
                let reads = fake.count(.installedVersion)
                let reading = Task { try await readInstalled() }
                await realSleep(.milliseconds(50))
                #expect(fake.count(.installedVersion) == reads, "the read waits for ensureSelected")
                fake.release(.ensureSelected)
                try await rollout.value
                #expect(try await reading.value == v("26.4.1"))
            }
        }
    }

    // MARK: - Lock

    @MainActor
    struct Lock {
        @Test func twoRolloutsStartedTogetherInstallOnce() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            try await withCLT(fake) { _ in
                async let first: Void = CLTInstaller.ensure(minimum: nil)
                async let second: Void = CLTInstaller.ensure(minimum: nil)
                _ = try await (first, second)
            }
            #expect(fake.installs == [v("26.4.1")])
            #expect(fake.count(.ensureSelected) == 2)
        }

        @Test func aRolloutStartedMidInstallWaitsForIt() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            fake.hold(.install)
            try await withCLT(fake) { _ in
                let first = Task { try await CLTInstaller.ensure(minimum: nil) }
                await eventually("installing") { fake.installs.count == 1 }
                // The receipt already shows 26.4.1, but the install isn't done: Homebrew's
                // `ensure` must not go ahead on it.
                let second = Task { try await CLTInstaller.ensure(minimum: nil) }
                await realSleep(.milliseconds(50))
                #expect(fake.count(.ensureSelected) == 0)

                fake.release(.install)
                try await first.value
                try await second.value
                #expect(fake.installs == [v("26.4.1")])
                #expect(fake.count(.ensureSelected) == 2)
            }
        }

        @Test func cancellingARolloutWaitingOnTheLockInstallsNothing() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            try await withCLT(fake) { context in
                try await context.lock.waitUnlessCancelled()
                let rollout = Task { try await CLTInstaller.ensure(minimum: nil) }
                await eventually("checked the Mac") { fake.count(.installedVersion) == 1 }
                await realSleep(.milliseconds(20))
                rollout.cancel()
                await #expect(throws: CancellationError.self) { try await rollout.value }
                context.lock.signal()
                #expect(fake.calls == [.installedVersion])
            }
        }
    }

    // MARK: - Resource

    @MainActor
    struct InstallResource {
        @Test func thereIsOnePerMac() {
            #expect(CommandLineToolsInstall(minimum: nil).id == "commandLineTools")
            #expect(CommandLineToolsInstall(minimum: v("26.4.1")).id == "commandLineTools")
        }

        @Test func theHashMovesOnlyWithTheMinimum() {
            #expect(hash(nil) == hash(nil))
            #expect(hash(v("26.4.1")) == hash(v("26.4.1.0.1.1745106510")))
            #expect(hash(v("26.4.1")) != hash(nil))
            #expect(hash(v("26.4.1")) != hash(v("26.5")))
        }

        @Test func theSnapshotRecordsTheMinimumAsAString() throws {
            #expect(try AnyResource(CommandLineToolsInstall(minimum: v("26.4.1.0.1"))).encode() == .object(["minimum": .string("26.4.1")]))
            #expect(try AnyResource(CommandLineToolsInstall(minimum: nil)).encode() == .object([:]))
        }

        @Test func removeLeavesCLTAlone() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"))
            try await withCLT(fake) { _ in try await CommandLineToolsInstall.remove(CommandLineToolsInstall(minimum: v("26.4.1"))) }
            #expect(fake.calls.isEmpty)
        }
    }

    // MARK: - Engine

    @MainActor
    struct InEngine {
        @Test func installedInstallsOnAFreshMacAndReadsNoFact() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            try await withCLT(fake) { _ in
                try await withEngine(InstalledApp.self, resourceTypes: cltResourceTypes) { h in
                    await eventually("installed") { fake.installed == v("26.4.1") }
                    await h.settle()
                    #expect(fake.installs == [v("26.4.1")])
                    #expect(h.diskRecord("commandLineTools")?.hash == hash(nil))
                    #expect(h.facts.lastRead.isEmpty)

                    // No fact loop reads the Mac, however long it runs.
                    let calls = fake.calls.count
                    await h.advance(.seconds(7 * 3600))
                    #expect(fake.calls.count == calls)
                }
            }
        }

        @Test func latestInstallsOnAFreshMacThenChecksTheCatalog() async throws {
            let fake = FakeCLTSystem(catalog: [v("26.4.1")])
            try await withCLT(fake) { _ in
                try await withEngine(SwitchingApp.self, resourceTypes: cltResourceTypes) { h in
                    // The first read skips the catalog and reads nil: any CLT will do, so the
                    // newest is installed.
                    await eventually("installed") { fake.installed == v("26.4.1") }
                    await h.settle()
                    #expect(h.diskRecord("commandLineTools")?.hash == hash(nil))
                    #expect(fake.count(.list) == 1)  // the rollout's own

                    // 15 minutes on, the first catalog check. CLT is current, so it lists
                    // nothing and the value is the installed version: one rollout that does nothing.
                    let started = h.logs("astrolabe.operation.started").count
                    await h.advance(.seconds(15 * 60))
                    await eventually("moved to 26.4.1") { h.diskRecord("commandLineTools")?.hash == hash(v("26.4.1")) }
                    await h.settle()
                    #expect(fake.count(.list) == 2)
                    #expect(h.logs("astrolabe.operation.started").count == started + 1)
                    #expect(fake.installs == [v("26.4.1")])

                    // An equal value runs no pass.
                    let passes = h.engine.passCount
                    await h.advance(.seconds(15 * 60))
                    #expect(h.engine.passCount == passes)

                    // `.installed` changes the hash: one rollout, which does nothing.
                    h.state.tracked = 1
                    await eventually("moved to .installed") { h.diskRecord("commandLineTools")?.hash == hash(nil) }
                    await h.settle()
                    #expect(fake.installs == [v("26.4.1")])

                    // Dropped: removed from the records, and CLT is left alone.
                    let calls = fake.calls.count
                    h.state.tracked = 2
                    await eventually("record removed") { h.diskRecord("commandLineTools") == nil }
                    await h.settle()
                    #expect(fake.calls.count == calls)
                    #expect(fake.installed == v("26.4.1"))
                }
            }
        }

        @Test func latestUpdatesWhenAppleShipsANewerCLT() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.4.1")])
            try await withCLT(fake) { _ in
                try await withEngine(SwitchingApp.self, resourceTypes: cltResourceTypes) { h in
                    await eventually("on record") { h.diskRecord("commandLineTools")?.hash == hash(v("26.4.1")) }
                    await h.settle()
                    #expect(fake.count(.list) == 0)

                    // Apple ships 26.5, but the catalog can't be reached: the last value stays.
                    fake.catalog = [v("26.4.1"), v("26.5")]
                    fake.fail(.list)
                    await h.advance(.seconds(15 * 60))
                    #expect(h.logs("astrolabe.fact.read_failed").count == 1)
                    #expect(fake.installs.isEmpty)

                    // The retry, after the backoff, finds it, and the rollout installs it.
                    await h.advance(.seconds(15))
                    await eventually("26.5 installed") { h.diskRecord("commandLineTools")?.hash == hash(v("26.5")) }
                    await h.settle()
                    #expect(fake.installs == [v("26.5")])
                    #expect(fake.installed == v("26.5"))

                    // Afterwards the value stays 26.5: nothing more to do.
                    let passes = h.engine.passCount
                    await h.advance(.seconds(15 * 60))
                    #expect(h.engine.passCount == passes)
                }
            }
        }

        @Test func aRestartWithCLTInPlaceIsIdleAndNeverWaitsOnApple() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.4.1")])
            try await withCLT(fake) { _ in
                try await withEngine(SwitchingApp.self, resourceTypes: cltResourceTypes) { h in
                    await eventually("on record") { h.diskRecord("commandLineTools")?.hash == hash(v("26.4.1")) }
                    await h.settle()
                    let started = h.logs("astrolabe.operation.started").count

                    // A new launch starts over: a fresh context, so its first read is fast again.
                    try await withCLT(fake) { _ in await h.restart() }
                    #expect(h.logs("astrolabe.operation.started").count == started)
                    #expect(fake.count(.list) == 0)
                }
            }
        }

        @Test func aResourceHashingInstalledRedoesItsWorkOnlyOnceTheUpdateIsDone() async throws {
            let fake = FakeCLTSystem(installed: v("26.4.1"), catalog: [v("26.4.1")])
            try await withCLT(fake) { _ in
                try await withEngine(DependentApp.self, resourceTypes: cltResourceTypes) { h in
                    await eventually("dependent on 26.4.1") { h.machine.state["fake:dependent"] == "26.4.1" }
                    await h.settle()

                    // Apple ships 26.5, and its install is held after the receipt is written.
                    // No `settle` until it's released: reads wait on the lock meanwhile.
                    fake.catalog = [v("26.4.1"), v("26.5")]
                    fake.hold(.install)
                    h.clock.advance(by: .seconds(15 * 60))
                    await eventually("installing 26.5") { fake.installs == [v("26.5")] }
                    #expect(fake.installed == v("26.5"))

                    // The next reads come due mid-install and wait it out.
                    h.clock.advance(by: .seconds(15 * 60))
                    await eventually("reads waiting") { h.facts.reading.count == 2 }
                    await realSleep(.milliseconds(50))
                    #expect(h.machine.calls("fake:dependent").map(\.value) == ["26.4.1"])

                    fake.release(.install)
                    await eventually("dependent on 26.5") { h.machine.state["fake:dependent"] == "26.5.0" }
                    await h.settle()
                    #expect(h.machine.calls("fake:dependent").map(\.value) == ["26.4.1", "26.5.0"])
                    #expect(h.diskRecord("commandLineTools")?.hash == hash(v("26.5")))
                }
            }
        }
    }
}
