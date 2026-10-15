import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fixtures

private func v(_ string: String) -> CLTVersion { CLTVersion(string)! }

private let wget = "brew:formula:wget"

private let brewResourceTypes: [any Resource.Type] =
    fakeResourceTypes + [CommandLineToolsInstall.self, HomebrewInstall.self, BrewPackage.self]

/// The record hash of `Brew(name, type:, version: .atLeast(minimum))`, or `.installed` without one.
private func hash(_ name: String, _ type: Brew.PackageType = .formula, minimum: String? = nil) -> String {
    BrewPackage.compute(BrewPackage(name: name, type: type, minimum: minimum))
}

/// A `BrewPackage` as a pass that read `satisfied` would build it, or as one built outside a
/// pass with `nil`.
private func package(
    _ name: String, _ type: Brew.PackageType = .formula, minimum: String? = nil, satisfied: Bool? = nil
) throws -> BrewPackage {
    var object: [String: JSONValue] = ["name": .string(name), "type": .string(type.rawValue)]
    if let minimum { object["minimum"] = .string(minimum) }
    if let satisfied { object["satisfied"] = .bool(satisfied) }
    return try JSONDecoder().decode(BrewPackage.self, from: JSONEncoder().encode(JSONValue.object(object)))
}

/// `BrewInstaller.ensure` on `brew`.
@MainActor
private func ensure(_ name: String, _ type: Brew.PackageType = .formula, minimum: String? = nil, on brew: FakeHomebrewSystem) async throws {
    try await withHomebrew(brew) { _ in try await BrewInstaller.ensure(name, type: type, minimum: minimum) }
}

/// `BrewInstaller.uninstall` on `brew`.
@MainActor
private func uninstall(_ name: String, _ type: Brew.PackageType = .formula, on brew: FakeHomebrewSystem) async throws {
    try await withHomebrew(brew) { _ in try await BrewInstaller.uninstall(name, type: type) }
}

/// CLT, Homebrew owned by `ops`, and wget, as a farm app declares them.
private struct FarmApp: Astrolabe {
    var body: some Component {
        CommandLineTools()
        Homebrew(owner: "ops")
        Brew("wget")
    }
}

/// wget without `Homebrew()`: it runs as whoever owns an existing Homebrew, or waits.
private struct NoHomebrewApp: Astrolabe {
    var body: some Component {
        CommandLineTools()
        Brew("wget")
    }
}

/// CLT and Homebrew, and no `Brew`.
private struct NoBrewApp: Astrolabe {
    var body: some Component {
        CommandLineTools()
        Homebrew(owner: "ops")
    }
}

/// wget while `test.tracked` is 0, at 2.0 or above at 1, tap-qualified at 2, and dropped after.
private struct SwitchingApp: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        CommandLineTools()
        Homebrew(owner: "ops")
        switch test.tracked {
        case 0: Brew("wget")
        case 1: Brew("wget", version: .atLeast("2.0"))
        case 2: Brew("homebrew/core/wget")
        default: EmptyComponent()
        }
    }
}

/// jq, plus wget from `test.tracked` 1, at 2.0 or above from 2.
private struct GrowingApp: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        CommandLineTools()
        Homebrew(owner: "ops")
        Brew("jq")
        switch test.tracked {
        case 0: EmptyComponent()
        case 1: Brew("wget")
        default: Brew("wget", version: .atLeast("2.0"))
        }
    }
}

@MainActor
private func started<App>(_ h: EngineHarness<App>) -> Int {
    h.logs("astrolabe.operation.started").count
}

/// A throwaway Homebrew prefix: `Cellar/<formula>/<version>/…`, `Caskroom/<token>/<version>/…`,
/// and `opt/<formula>` links.
private struct BrewPrefixFixture: ~Copyable {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabe-brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.path
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func packages() throws -> BrewPackages { try BrewScan.packages(prefix: path) }

    /// `<root>/<name>/<version>/` holding one file: the shape brew leaves behind.
    func installed(_ name: String, version: String, cask: Bool = false) throws {
        try file(cask ? "Caskroom" : "Cellar", name, version, "INSTALL_RECEIPT.json")
    }

    /// `opt/<name>` pointing at a keg, the way `brew link` does for the current version.
    func linked(_ name: String, version: String) throws {
        try emptyDirectory("opt")
        try FileManager.default.createSymbolicLink(atPath: "\(path)/opt/\(name)", withDestinationPath: "../Cellar/\(name)/\(version)")
    }

    func emptyDirectory(_ components: String...) throws {
        try FileManager.default.createDirectory(atPath: ([path] + components).joined(separator: "/"), withIntermediateDirectories: true)
    }

    /// An empty file, with the directories above it.
    func file(_ components: String...) throws {
        let file = ([path] + components).joined(separator: "/")
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: file))
    }

    /// `chmod` of a directory under the prefix.
    func setMode(_ mode: mode_t, _ components: String...) {
        chmod(([path] + components).joined(separator: "/"), mode)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct BrewTests {
    // MARK: - Resource

    @MainActor
    struct PackageResource {
        @Test func theIdIsTheTypeAndTheShortName() {
            #expect(BrewPackage(name: "wget", type: .formula, minimum: nil).id == "brew:formula:wget")
            #expect(BrewPackage(name: "firefox", type: .cask, minimum: nil).id == "brew:cask:firefox")
            #expect(BrewPackage(name: "cloudflare/cloudflare/cloudflared", type: .formula, minimum: nil).id == "brew:formula:cloudflared")
        }

        @Test func tapQualifyingKeepsTheIdAndMovesTheHash() {
            let short = BrewPackage(name: "cloudflared", type: .formula, minimum: nil)
            let qualified = BrewPackage(name: "cloudflare/cloudflare/cloudflared", type: .formula, minimum: nil)
            #expect(short.id == qualified.id)
            #expect(hash("cloudflared") != hash("cloudflare/cloudflare/cloudflared"))
        }

        @Test func theMinimumMovesTheHashNotTheId() {
            #expect(BrewPackage(name: "wget", type: .formula, minimum: "1.25").id == wget)
            #expect(hash("wget") != hash("wget", minimum: "1.25"))
            #expect(hash("wget", minimum: "1.25") != hash("wget", minimum: "1.26"))
            #expect(hash("wget", minimum: "1.25") == hash("wget", minimum: "1.25"))
        }

        @Test func aFormulaAndACaskAreDifferentIds() {
            let formula = BrewPackage(name: "codex", type: .formula, minimum: nil)
            let cask = BrewPackage(name: "codex", type: .cask, minimum: nil)
            #expect(formula.id != cask.id)
            #expect(hash("codex", .formula) != hash("codex", .cask))
        }

        @Test func theMonitorStaysOutOfTheHash() throws {
            #expect(BrewPackage.compute(try package("wget", satisfied: true)) == hash("wget"))
            #expect(BrewPackage.compute(try package("wget", satisfied: false)) == hash("wget"))
        }

        @Test func theSnapshotRoundTripsAndLeavesAnUnreadMonitorOut() throws {
            let snapshot = try AnyResource(package("tailscale", minimum: "1.102.0", satisfied: false)).encode()
            #expect(snapshot == .object([
                "name": .string("tailscale"), "type": .string("formula"), "minimum": .string("1.102.0"), "satisfied": .bool(false),
            ]))
            let registry = try ResourceRegistry([BrewPackage.self])
            let decoded = try AnyResource.decode(kind: BrewPackage.kind, snapshot, registry: registry)
            #expect(try decoded.encode() == snapshot)
            #expect(decoded.hash() == hash("tailscale", minimum: "1.102.0"))

            // Unread: left out, so it stays apart from a read `false`.
            #expect(try AnyResource(BrewPackage(name: "firefox", type: .cask, minimum: nil)).encode() == .object([
                "name": .string("firefox"), "type": .string("cask"),
            ]))
        }

        @Test func inAPassTheMonitorReadsPackages() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            try await withHomebrew(brew) { _ in
                let store = FactStore(wake: Wake(), clock: EngineClock(ManualClock()), telemetry: NoopAstrolabeTelemetry())
                defer { store.stopAll() }
                store.inject(\.homebrew.packages, brew.packagesOnMac)

                let (installed, atDefault) = store.tracking { BrewPackage(name: "wget", type: .formula, minimum: nil) }
                #expect(installed.satisfied == true)
                #expect(atDefault.isEmpty)
                #expect(store.lastRead.count == 1, "packages, and nothing else")
                let (missing, _) = store.tracking { BrewPackage(name: "jq", type: .formula, minimum: nil) }
                #expect(missing.satisfied == false)
            }
        }
    }

    // MARK: - Names

    struct Names {
        @Test func aTapQualifiedNameIsShortened() {
            #expect(BrewName.short("cloudflare/cloudflare/cloudflared") == "cloudflared")
            #expect(BrewName.short("wget") == "wget")
            #expect(BrewName.short(BrewName.short("cloudflare/cloudflare/cloudflared")) == "cloudflared")
        }

        @Test func everyCommandNamesTheType() {
            #expect(Brew.PackageType.formula.flag == "--formula")
            #expect(Brew.PackageType.cask.flag == "--cask")
        }

        @Test func aVersionsFloorIsItsMinimum() {
            #expect(Brew.Version.installed.minimum == nil)
            #expect(Brew.Version.atLeast("1.102.0").minimum == "1.102.0")
        }
    }

    // MARK: - Scan

    struct Scan {
        @Test func populatedKegsCount() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.installed("wget", version: "1.25.0")
            try prefix.installed("ghostty", version: "1.2.3", cask: true)
            #expect(try prefix.packages() == BrewPackages(formulae: ["wget": "1.25.0"], casks: ["ghostty": "1.2.3"]))
        }

        /// An interrupted uninstall leaves `Cellar/<name>` behind with no version, and `brew list`
        /// says it isn't installed. An empty keg is the same one level down.
        @Test func anEmptyCellarEntryOrKegDoesNotCount() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.emptyDirectory("Cellar", "codex")
            try prefix.emptyDirectory("Cellar", "wget", "1.25.0")
            #expect(try prefix.packages() == BrewPackages())
        }

        /// `.metadata` holds a cask's install receipts and outlives `brew uninstall`.
        @Test func aCaskWithOnlyMetadataDoesNotCount() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.file("Caskroom", "ghostty", ".metadata", "1.2.3", "receipt.json")
            #expect(try prefix.packages() == BrewPackages())
        }

        @Test func aStrayFileAtAnyLevelIsSkipped() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.installed("wget", version: "1.25.0")
            try prefix.file("Cellar", ".DS_Store")
            try prefix.file("Cellar", "README")
            try prefix.file("Cellar", "wget", "notes")
            try prefix.file("Cellar", "jq", "1.7")
            try prefix.file("Caskroom", "stray")
            #expect(try prefix.packages() == BrewPackages(formulae: ["wget": "1.25.0"]))
        }

        /// With two kegs side by side, `opt/<name>` is what brew runs, even when it isn't the
        /// highest, as after an interrupted upgrade.
        @Test func theOptLinkWinsOverTheHighestKeg() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.installed("tailscale", version: "1.98.1")
            try prefix.installed("tailscale", version: "1.104.1")
            try prefix.linked("tailscale", version: "1.98.1")
            #expect(try prefix.packages().version(of: "tailscale", type: .formula) == "1.98.1")
        }

        @Test func withoutALinkTheHighestKegWins() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.installed("tailscale", version: "1.98.10")
            try prefix.installed("tailscale", version: "1.102.0")
            try prefix.installed("tailscale", version: "1.100.0")
            #expect(try prefix.packages().version(of: "tailscale", type: .formula) == "1.102.0")
        }

        /// A link to a keg that was removed must not report a version that isn't installed.
        @Test func aDanglingLinkFallsBackToTheHighestKeg() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.installed("tailscale", version: "1.104.1")
            try prefix.linked("tailscale", version: "1.98.1")
            #expect(try prefix.packages().version(of: "tailscale", type: .formula) == "1.104.1")
        }

        @Test func anUnparseableKegIsReportedOnlyWhenNothingParses() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.installed("wget", version: "HEAD-abc1234")
            try prefix.installed("jq", version: "HEAD-def5678")
            try prefix.installed("jq", version: "1.7")
            try prefix.installed("chrome", version: "latest", cask: true)
            #expect(try prefix.packages() == BrewPackages(
                formulae: ["wget": "HEAD-abc1234", "jq": "1.7"], casks: ["chrome": "latest"]
            ))
        }

        @Test func casksAndFormulaeDoNotCrossMatch() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.installed("codex", version: "0.143.0", cask: true)
            try prefix.emptyDirectory("Cellar", "codex")
            let packages = try prefix.packages()
            #expect(packages.version(of: "codex", type: .cask) == "0.143.0")
            #expect(packages.version(of: "codex", type: .formula) == nil)
        }

        @Test func aMissingPrefixCellarOrCaskroomIsEmpty() throws {
            #expect(try BrewScan.packages(prefix: "/nonexistent-\(UUID().uuidString)") == BrewPackages())
            let prefix = try BrewPrefixFixture()
            #expect(try prefix.packages() == BrewPackages())
            try prefix.installed("wget", version: "1.25.0")
            #expect(try prefix.packages() == BrewPackages(formulae: ["wget": "1.25.0"]))
        }

        /// Never "nothing installed" for a read that failed. Root reads anything.
        @Test(.enabled(if: getuid() != 0)) func anUnreadableDirectoryThrows() throws {
            let prefix = try BrewPrefixFixture()
            try prefix.installed("wget", version: "1.25.0")
            prefix.setMode(0, "Cellar", "wget")
            defer { prefix.setMode(0o755, "Cellar", "wget") }
            #expect(throws: POSIXError.self) { try prefix.packages() }

            prefix.setMode(0o755, "Cellar", "wget")
            prefix.setMode(0, "Cellar")
            defer { prefix.setMode(0o755, "Cellar") }
            #expect(throws: POSIXError.self) { try prefix.packages() }
        }
    }

    // MARK: - BrewVersion

    struct Versions {
        @Test(arguments: [
            ("1.104.1", [1, 104, 1], 0),
            ("1.104.1_1", [1, 104, 1], 1),
            ("3.0", [3, 0], 0),
            ("2024.08.2", [2024, 8, 2], 0),
            ("1.2.3,456", [1, 2, 3, 456], 0),
        ])
        func parses(_ string: String, parts: [Int], revision: Int) throws {
            let version = try #require(BrewVersion(string))
            #expect(version.parts == parts)
            #expect(version.revision == revision)
            #expect(version.description == string)
        }

        /// A `HEAD-…` keg and a cask's `latest` have no order to compare, so they must not parse
        /// into one by accident.
        @Test(arguments: ["HEAD-abc1234", "latest", "", "1..2", "1.2.", "v1.2.3", "+1.2", "1.2_x"])
        func rejectsNonNumeric(_ string: String) {
            #expect(BrewVersion(string) == nil)
        }

        @Test func ordersNumericallyAndByRevision() throws {
            func v(_ string: String) throws -> BrewVersion { try #require(BrewVersion(string)) }
            // Numeric, not lexical: the 1.98 → 1.102 boundary is the one ENG-3621 depends on.
            #expect(try v("1.98.10") < v("1.102.0"))
            #expect(try v("1.102") == v("1.102.0"))
            #expect(try !(v("1.102") < v("1.102.0")) && !(v("1.102.0") < v("1.102")))
            #expect(try v("1.104.1_0") < v("1.104.1_1"))
            #expect(try v("1.104.1_9") < v("1.104.2"))
            #expect(try v("1.2.3,456") > v("1.2.3"))
        }
    }

    // MARK: - check

    struct Check {
        static let packages = BrewPackages(
            formulae: ["wget": "1.25.0", "tailscale": "1.98.1", "revised": "1.104.1_1", "head": "HEAD-abc1234"],
            casks: ["firefox": "130.0"]
        )

        private func check(_ name: String, _ type: Brew.PackageType = .formula, minimum: String? = nil) -> BrewCheck {
            BrewInstaller.check(Self.packages, name, type: type, minimum: minimum)
        }

        @Test func missingIsNotInstalled() {
            #expect(check("jq") == .notInstalled)
            #expect(check("jq", minimum: "1.0") == .notInstalled)
            #expect(check("wget", .cask) == .notInstalled, "a formula never satisfies a cask")
            #expect(check("firefox") == .notInstalled, "a cask never satisfies a formula")
        }

        @Test func anyVersionSatisfiesNoMinimum() {
            #expect(check("wget") == .satisfied)
            #expect(check("head") == .satisfied)
            #expect(check("firefox", .cask) == .satisfied)
        }

        @Test func aMinimumComparesNumerically() {
            #expect(check("tailscale", minimum: "1.102.0") == .below(installed: "1.98.1", minimum: "1.102.0"))
            #expect(check("tailscale", minimum: "1.98.1") == .satisfied)
            #expect(check("tailscale", minimum: "1.98") == .satisfied)
            #expect(check("firefox", .cask, minimum: "131") == .below(installed: "130.0", minimum: "131"))
        }

        @Test func theRevisionBreaksTies() {
            #expect(check("revised", minimum: "1.104.1") == .satisfied)
            #expect(check("revised", minimum: "1.104.1_1") == .satisfied)
            #expect(check("revised", minimum: "1.104.1_2") == .below(installed: "1.104.1_1", minimum: "1.104.1_2"))
        }

        @Test func anUnparseableSideIsUncomparable() {
            #expect(check("head", minimum: "1.0") == .uncomparable(installed: "HEAD-abc1234", minimum: "1.0"))
            #expect(check("wget", minimum: "v1.2") == .uncomparable(installed: "1.25.0", minimum: "v1.2"))
        }

        @Test func aTapQualifiedNameChecksItsShortName() {
            #expect(check("homebrew/core/wget") == .satisfied)
            #expect(check("tailscale/tailscale/tailscale", minimum: "1.102.0") == .below(installed: "1.98.1", minimum: "1.102.0"))
        }

        @MainActor
        @Test func theSubscriptAgreesWithCheck() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            for (name, version) in Self.packages.formulae { brew.setPackage(name, version: version, owner: "ops") }
            for (name, version) in Self.packages.casks { brew.setPackage(name, type: .cask, version: version, owner: "ops") }
            let cases: [(String, Brew.PackageType, String?)] = [
                ("jq", .formula, nil), ("wget", .formula, nil), ("wget", .cask, nil), ("homebrew/core/wget", .formula, nil),
                ("tailscale", .formula, "1.102.0"), ("tailscale", .formula, "1.98"), ("head", .formula, "1.0"),
                ("firefox", .cask, "130"),
            ]
            try await withHomebrew(brew) { _ in
                let store = FactStore(wake: Wake(), clock: EngineClock(ManualClock()), telemetry: NoopAstrolabeTelemetry())
                defer { store.stopAll() }
                store.inject(\.homebrew.packages, brew.packagesOnMac)
                for (name, type, minimum) in cases {
                    let (satisfied, atDefault) = store.tracking { Facts(store: store).homebrew[satisfies: name, type, minimum] }
                    #expect(satisfied == (check(name, type, minimum: minimum) == .satisfied), "\(name) \(type) \(minimum ?? "-")")
                    #expect(atDefault.isEmpty)
                }
            }
        }
    }

    // MARK: - ensure

    @MainActor
    struct Ensure {
        @Test func aMissingFormulaIsInstalledAsTheOwner() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            try await ensure("wget", on: brew)
            #expect(brew.version("wget") == "1.0")
            #expect(brew.calls == [
                .packages,  // the Mac first, without the lock
                .packages,  // again under it
                .owners,
                .brew(["install", "--formula", "wget"], "ops"),
                .packages,  // verify
            ])
        }

        @Test func whenSatisfiedItRunsNoBrewAndTakesNoLock() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            try await withHomebrew(brew) { context in
                try await context.lock.waitUnlessCancelled()  // held throughout: waiting on it would hang
                let rollout = Task { try await BrewInstaller.ensure("wget", type: .formula, minimum: nil) }
                await eventually("checked") { brew.count(.packages) == 1 }
                await realSleep(.milliseconds(20))
                rollout.cancel()
                let result = await rollout.result
                context.lock.signal()
                #expect((try? result.get()) != nil, "returned without waiting on the lock")
            }
            #expect(brew.calls == [.packages])
        }

        @Test func belowTheMinimumItUpgrades() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.setPackage("tailscale", version: "1.98.1", owner: "ops")
            brew.setLatest("tailscale", version: "1.104.1")
            try await ensure("tailscale", minimum: "1.102.0", on: brew)
            #expect(brew.brews == [["upgrade", "--formula", "tailscale"]])
            #expect(brew.version("tailscale") == "1.104.1")
        }

        @Test func stillBelowAfterTheUpgradeThrows() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.setPackage("tailscale", version: "1.98.1", owner: "ops")
            brew.setLatest("tailscale", version: "1.100.0")
            await #expect(throws: BrewError.minimumUnavailable(name: "tailscale", installed: "1.100.0", minimum: "1.102.0")) {
                try await ensure("tailscale", minimum: "1.102.0", on: brew)
            }
        }

        @Test func aMissingPackageBelowTheMinimumIsInstalledThenChecked() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.setLatest("tailscale", version: "1.104.1")
            try await ensure("tailscale", minimum: "1.102.0", on: brew)
            #expect(brew.brews == [["install", "--formula", "tailscale"]])
        }

        @Test func anUncomparableVersionThrowsWithoutTheLockOrABrew() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.setPackage("wget", version: "HEAD-abc1234", owner: "ops")
            await #expect(throws: BrewError.uncomparableVersion(name: "wget", installed: "HEAD-abc1234", minimum: "1.0")) {
                try await ensure("wget", minimum: "1.0", on: brew)
            }
            #expect(brew.calls == [.packages])
        }

        @Test func withoutHomebrewItThrows() async throws {
            let brew = FakeHomebrewSystem()
            await #expect(throws: BrewError.homebrewMissing) { try await ensure("wget", on: brew) }
            #expect(brew.brews.isEmpty)
        }

        @Test(arguments: [["bob", "ops"], ["#501"], ["root"]])
        func withoutOneOwnerItWaitsForHomebrew(_ owners: [String]) async throws {
            let brew = FakeHomebrewSystem(owner: owners[0])
            for (index, owner) in owners.dropFirst().enumerated() { brew.addFormula("other\(index)", owner: owner) }
            #expect(brew.ownersOnMac == owners)
            await #expect(throws: BrewError.homebrewNotReady(owners: owners)) { try await ensure("wget", on: brew) }
            #expect(brew.brews.isEmpty)
        }

        @Test func aFailedBrewThrows() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.fail(.brew)
            await #expect(throws: FakeHomebrewSystem.FakeError.self) { try await ensure("wget", on: brew) }
            #expect(brew.version("wget") == nil)
        }

        @Test func aBrewThatDidNotTakeThrows() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.brewDoesNotTake()
            await #expect(throws: BrewError.didNotInstall(name: "wget")) { try await ensure("wget", on: brew) }
            #expect(brew.brews == [["install", "--formula", "wget"]])
        }

        @Test func aCaskIsInstalledAsACask() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            try await ensure("firefox", .cask, on: brew)
            #expect(brew.brews == [["install", "--cask", "firefox"]])
            #expect(brew.version("firefox", type: .cask) == "1.0")
            #expect(brew.version("firefox") == nil)
        }

        @Test func aTapQualifiedNameIsInstalledWhole() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            try await ensure("cloudflare/cloudflare/cloudflared", on: brew)
            #expect(brew.brews == [["install", "--formula", "cloudflare/cloudflare/cloudflared"]])
            #expect(brew.version("cloudflared") == "1.0")
        }

        @Test func cancelledWhileWaitingForTheLockItRunsNoBrew() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withHomebrew(brew) { context in
                try await context.lock.waitUnlessCancelled()
                let rollout = Task { try await BrewInstaller.ensure("wget", type: .formula, minimum: nil) }
                await eventually("checked") { brew.count(.packages) == 1 }
                await realSleep(.milliseconds(20))
                rollout.cancel()
                await #expect(throws: CancellationError.self) { try await rollout.value }
                context.lock.signal()
            }
            #expect(brew.calls == [.packages])
        }

        @Test func twoPackagesNeverRunBrewAtOnce() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withHomebrew(brew) { _ in
                async let wget: Void = BrewInstaller.ensure("wget", type: .formula, minimum: nil)
                async let jq: Void = BrewInstaller.ensure("jq", type: .formula, minimum: nil)
                async let firefox: Void = BrewInstaller.ensure("firefox", type: .cask, minimum: nil)
                _ = try await (wget, jq, firefox)
            }
            #expect(brew.brews.count == 3)
            #expect(brew.maxRunning == 1)
        }
    }

    // MARK: - uninstall

    @MainActor
    struct Uninstall {
        @Test func notInstalledIsANoOpWithoutTheLock() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withHomebrew(brew) { context in
                try await context.lock.waitUnlessCancelled()  // held throughout: waiting on it would hang
                let removal = Task { try await BrewInstaller.uninstall("wget", type: .formula) }
                await eventually("checked") { brew.count(.packages) == 1 }
                await realSleep(.milliseconds(20))
                removal.cancel()
                let result = await removal.result
                context.lock.signal()
                #expect((try? result.get()) != nil, "returned without waiting on the lock")
            }
            #expect(brew.calls == [.packages])
        }

        @Test func itUninstallsTheShortNameAsTheOwner() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            try await uninstall("homebrew/core/wget", on: brew)
            #expect(brew.version("wget") == nil)
            #expect(brew.calls == [
                .packages, .packages, .owners,
                .brew(["uninstall", "--formula", "wget"], "ops"),
                .packages,
            ])
        }

        @Test func aCaskIsUninstalledAsACask() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.setPackage("codex", type: .cask, version: "0.143.0", owner: "ops")
            brew.setPackage("codex", version: "1.0", owner: "ops")
            try await uninstall("codex", .cask, on: brew)
            #expect(brew.brews == [["uninstall", "--cask", "codex"]])
            #expect(brew.version("codex", type: .cask) == nil)
            #expect(brew.version("codex") == "1.0", "the formula stays")
        }

        @Test func stillThereAfterwardsThrows() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            brew.brewDoesNotTake()
            await #expect(throws: BrewError.didNotUninstall(name: "wget")) { try await uninstall("wget", on: brew) }
        }

        @Test func installedWithoutBrewThrows() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            brew.deleteBrewCommand()
            await #expect(throws: BrewError.homebrewMissing) { try await uninstall("wget", on: brew) }
            #expect(brew.brews.isEmpty)
        }

        @Test func cancelledWhileWaitingForTheLockItRunsNoBrew() async throws {
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            try await withHomebrew(brew) { context in
                try await context.lock.waitUnlessCancelled()
                let removal = Task { try await BrewInstaller.uninstall("wget", type: .formula) }
                await eventually("checked") { brew.count(.packages) == 1 }
                await realSleep(.milliseconds(20))
                removal.cancel()
                await #expect(throws: CancellationError.self) { try await removal.value }
                context.lock.signal()
            }
            #expect(brew.calls == [.packages])
            #expect(brew.version("wget") == "1.0")
        }
    }

    // MARK: - Engine

    @MainActor
    struct InEngine {
        @Test func aFreshMacGetsCLTThenHomebrewThenBrew() async throws {
            let clt = FakeCLTSystem(catalog: [v("26.4.1")])
            let brew = FakeHomebrewSystem()
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: brewResourceTypes) { h in
                        // CLT first. Homebrew waits for the next `installed` read.
                        await eventually("CLT installed") { clt.installed == v("26.4.1") }
                        await h.settle()
                        // `Brew` reads `owners` from the first pass, and changes nothing.
                        #expect(brew.changes.isEmpty)

                        // Homebrew next. Brew waits for the next `owners` read.
                        await h.advance(.seconds(60))
                        await eventually("Homebrew installed") { brew.ownersOnMac == ["ops"] }
                        await h.settle()
                        #expect(brew.brews.isEmpty)
                        #expect(h.diskRecord(wget) == nil)

                        await h.advance(.seconds(60))
                        await eventually("wget installed") { brew.version("wget") != nil }
                        await h.settle()
                        #expect(brew.calls.contains(.brew(["install", "--formula", "wget"], "ops")))
                        #expect(brew.brews == [["install", "--formula", "wget"]])
                        #expect(h.diskRecord(wget)?.hash == hash("wget"))
                        #expect(h.logs("astrolabe.operation.failed").isEmpty, "each layer waits on a fact")
                    }
                }
            }
        }

        @Test func withoutHomebrewOnACleanMacBrewWaits() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem()
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(NoHomebrewApp.self, resourceTypes: brewResourceTypes) { h in
                        await h.advance(.seconds(60))
                        await h.advance(.seconds(60))
                        #expect(h.diskRecord(wget) == nil)
                        #expect(brew.changes.isEmpty)
                        #expect(h.logs("astrolabe.operation.failed").isEmpty)
                    }
                }
            }
        }

        @Test func withoutHomebrewBrewRunsAsTheExistingOwner() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(NoHomebrewApp.self, resourceTypes: brewResourceTypes) { h in
                        await eventually("wget installed") { brew.version("wget") != nil }
                        await h.settle()
                        #expect(brew.changes == [.brew(["install", "--formula", "wget"], "ops")])
                        #expect(h.diskRecord(wget)?.hash == hash("wget"))
                    }
                }
            }
        }

        @Test func aHandRunUninstallIsUndoneWithinAMinute() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: brewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord(wget) != nil }
                        // The next read sees the install: one rollout, which runs no brew.
                        await h.advance(.seconds(60))
                        #expect(h.diskRecord(wget)?.snapshot == .object([
                            "name": .string("wget"), "type": .string("formula"), "satisfied": .bool(true),
                        ]))
                        let before = started(h)

                        brew.uninstallByHand("wget")
                        await h.advance(.seconds(60))
                        await eventually("installed again") { brew.version("wget") != nil }
                        await h.settle()
                        #expect(brew.brews == [["install", "--formula", "wget"], ["install", "--formula", "wget"]])
                        #expect(started(h) == before + 1)

                        // The read after sees it back: exactly one more rollout, which runs no brew.
                        await h.advance(.seconds(60))
                        #expect(started(h) == before + 2)
                        await h.advance(.seconds(60))
                        #expect(started(h) == before + 2)
                        #expect(brew.brews.count == 2)
                    }
                }
            }
        }

        @Test func droppedFromBodyItIsUninstalledByItsShortName() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(
                        SwitchingApp.self, resourceTypes: brewResourceTypes,
                        before: { $0.fakeFacts.set(TestValuesKey.self, TestValues(tracked: 2)) }
                    ) { h in
                        await eventually("installed") { brew.version("wget") != nil }
                        await h.settle()
                        #expect(brew.brews == [["install", "--formula", "homebrew/core/wget"]])

                        h.state.tracked = 3
                        await eventually("record removed") { h.diskRecord(wget) == nil }
                        await h.settle()
                        #expect(brew.brews.last == ["uninstall", "--formula", "wget"])
                        #expect(brew.version("wget") == nil)
                    }
                }
            }
        }

        @Test func droppedWhileTheDaemonWasDownItIsUninstalled() async throws {
            let directory = try TemporaryDirectory()
            let store = RecordStore(url: directory.recordsURL)
            try store.set(wget, Record(kind: BrewPackage.kind, hash: hash("wget"), snapshot: .object([
                "name": .string("wget"), "type": .string("formula"), "satisfied": .bool(true),
            ])))
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            try await withCLT(FakeCLTSystem(installed: v("26.4.1"))) { _ in
                try await withHomebrew(brew) { _ in
                    let h = EngineHarness<NoBrewApp>(recordsURL: directory.recordsURL, resourceTypes: brewResourceTypes)
                    await h.start()
                    await eventually("record removed") { h.diskRecord(wget) == nil }
                    await h.settle()
                    #expect(brew.brews == [["uninstall", "--formula", "wget"]])
                    #expect(brew.version("wget") == nil)
                    await h.stop()
                }
            }
        }

        @Test func aNewMinimumUpgradesAndNeverUninstalls() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(SwitchingApp.self, resourceTypes: brewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord(wget)?.hash == hash("wget") }
                        await h.settle()

                        brew.setLatest("wget", version: "2.1")
                        h.state.tracked = 1
                        await eventually("upgraded") { h.diskRecord(wget)?.hash == hash("wget", minimum: "2.0") }
                        await h.settle()
                        #expect(brew.brews == [["install", "--formula", "wget"], ["upgrade", "--formula", "wget"]])
                        #expect(brew.version("wget") == "2.1")
                    }
                }
            }
        }

        @Test func tapQualifyingANameRunsNoBrew() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(SwitchingApp.self, resourceTypes: brewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord(wget)?.hash == hash("wget") }
                        await h.settle()

                        h.state.tracked = 2
                        await eventually("rolled out") { h.diskRecord(wget)?.hash == hash("homebrew/core/wget") }
                        await h.settle()
                        #expect(brew.brews.isEmpty)
                        #expect(brew.version("wget") == "1.0")
                    }
                }
            }
        }

        @Test func mixedOwnersAreReownedAndNothingIsUninstalled() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: brewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord(wget) != nil }
                        await h.settle()

                        brew.addFormula("jq", owner: "bob")
                        await h.advance(.seconds(60))
                        await eventually("given back") { brew.ownersOnMac == ["ops"] }
                        await h.settle()
                        #expect(brew.changes == [.brew(["install", "--formula", "wget"], "ops"), .reown("ops")])
                        #expect(h.diskRecord(wget)?.hash == hash("wget"))
                        #expect(brew.version("wget") != nil)
                    }
                }
            }
        }

        @Test func aDeletedHomebrewUninstallsNothingAndEverythingComesBack() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, resourceTypes: brewResourceTypes) { h in
                        await eventually("on record") { h.diskRecord(wget) != nil }
                        await h.settle()

                        // Undeclared, which finds nothing to remove; Homebrew is installed again.
                        brew.deleteBrew()
                        await h.advance(.seconds(60))
                        await eventually("wget undeclared") { h.diskRecord(wget) == nil }
                        await eventually("Homebrew back") { brew.ownersOnMac == ["ops"] }
                        await h.settle()
                        #expect(brew.installs == ["ops"])

                        // The next `owners` read reopens the gate.
                        await h.advance(.seconds(60))
                        await eventually("wget back") { brew.version("wget") != nil }
                        await eventually("on record again") { h.diskRecord(wget)?.hash == hash("wget") }
                        await h.settle()
                        #expect(!brew.brews.contains { $0.first == "uninstall" })
                    }
                }
            }
        }

        @Test func aRolloutSupersededWhileWaitingForTheLockRunsNoBrew() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.setLatest("wget", version: "2.1")
            // Never advance the clock while a brew is held: the `owners` read would wait on the
            // lock, and the engine would never settle.
            brew.hold(.brew)
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(GrowingApp.self, resourceTypes: brewResourceTypes) { h in
                        await eventually("jq installing") { brew.brews == [["install", "--formula", "jq"]] }
                        let reads = brew.count(.packages)

                        // Declared once jq holds the lock, so wget waits behind it.
                        h.state.tracked = 1
                        await eventually("wget checked") { brew.count(.packages) == reads + 1 }
                        await realSleep(.milliseconds(20))

                        h.state.tracked = 2
                        await eventually("wget cancelled") { h.logs("astrolabe.operation.cancelled").count == 1 }
                        await eventually("the replacement checked") { brew.count(.packages) == reads + 2 }
                        await realSleep(.milliseconds(20))
                        #expect(brew.brews == [["install", "--formula", "jq"]])

                        brew.release(.brew)
                        await eventually("wget installed") { h.diskRecord(wget)?.hash == hash("wget", minimum: "2.0") }
                        await h.settle()
                        #expect(brew.brews == [["install", "--formula", "jq"], ["install", "--formula", "wget"]])
                        #expect(brew.version("wget") == "2.1")
                        #expect(brew.maxRunning == 1)
                    }
                }
            }
        }

        // MARK: Dry run

        @Test func aDryRunShowsTheRolloutAndChangesNothing() async throws {
            let clt = FakeCLTSystem(installed: v("26.4.1"))
            let brew = FakeHomebrewSystem(owner: "ops")
            brew.addFormula("wget", owner: "ops")
            try await withCLT(clt) { _ in
                try await withHomebrew(brew) { _ in
                    try await withEngine(FarmApp.self, mode: .dryRun, resourceTypes: brewResourceTypes) { h in
                        let report = h.engine.dryRunReport(h.engine.lastPlan)
                        // Against `records.json`, not the Mac: wget is already installed.
                        #expect(report.split(separator: "\n").contains("  rollout \(wget)@\(hash("wget").prefix(12))"))
                        #expect(brew.changes.isEmpty)
                    }
                }
            }
        }
    }
}
