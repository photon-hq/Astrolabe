import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fixtures

/// Builds a throwaway Homebrew prefix so the installed-check can be exercised without a
/// real Homebrew. Mirrors the on-disk shape: `Cellar/<formula>/<version>/…` and
/// `Caskroom/<token>/<version>/…`.
private struct BrewPrefixFixture: ~Copyable {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrolabe-brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.path
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    /// Creates `<root>/<name>/<version>/` holding one file — the shape brew leaves behind.
    func installed(_ name: String, version: String, cask: Bool = false) throws {
        try writeKeg(prefix: path, name, version: version, cask: cask)
    }

    /// Points `opt/<name>` at a keg, the way `brew link` does for the current version.
    func linked(_ name: String, version: String) throws {
        try FileManager.default.createDirectory(atPath: "\(path)/opt", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: "\(path)/opt/\(name)",
            withDestinationPath: "../Cellar/\(name)/\(version)"
        )
    }

    /// Creates a directory but leaves it empty.
    func emptyDirectory(_ components: String...) throws {
        try FileManager.default.createDirectory(
            atPath: ([path] + components).joined(separator: "/"),
            withIntermediateDirectories: true
        )
    }
}

/// The keg writer behind `installed`, free-standing so a fake `brew upgrade` (an escaping
/// closure, which can't capture the non-copyable fixture) can call it with the prefix path.
private func writeKeg(prefix: String, _ name: String, version: String, cask: Bool = false) throws {
    let keg = "\(prefix)/\(cask ? "Caskroom" : "Cellar")/\(name)/\(version)"
    try FileManager.default.createDirectory(atPath: keg, withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: "\(keg)/INSTALL_RECEIPT.json"))
}

// MARK: - Installed

@Test func brewFormulaWithPopulatedKegIsInstalled() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("wget", version: "1.25.0")
    #expect(BrewHelper.isInstalled("wget", type: .formula, prefix: fixture.path))
}

@Test func brewCaskWithVersionDirectoryIsInstalled() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("ghostty", version: "1.2.3", cask: true)
    #expect(BrewHelper.isInstalled("ghostty", type: .cask, prefix: fixture.path))
}

/// The Cellar and Caskroom key on the bare token, so a tap-qualified declaration has to be
/// shortened before it can find its directory.
@Test func brewTapQualifiedNameResolvesToShortDirectory() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("cloudflared", version: "2024.8.2")
    #expect(BrewHelper.isInstalled("cloudflare/cloudflare/cloudflared", type: .formula, prefix: fixture.path))
}

// MARK: - Not installed

@Test func brewMissingPackageIsNotInstalled() throws {
    let fixture = try BrewPrefixFixture()
    #expect(!BrewHelper.isInstalled("wget", type: .formula, prefix: fixture.path))
}

/// Observed on a real machine: an interrupted uninstall left `Cellar/codex` behind with no
/// version inside. `brew list --formula codex` exits non-zero for it, so reporting it
/// installed would mean the loop never remediates a package that is genuinely gone.
@Test func brewEmptyCellarDirectoryIsNotInstalled() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.emptyDirectory("Cellar", "codex")
    #expect(!BrewHelper.isInstalled("codex", type: .formula, prefix: fixture.path))
}

/// A version directory with nothing in it is the same pathology one level down.
@Test func brewEmptyKegIsNotInstalled() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.emptyDirectory("Cellar", "wget", "1.25.0")
    #expect(!BrewHelper.isInstalled("wget", type: .formula, prefix: fixture.path))
}

/// `.metadata` holds a cask's install receipts and survives `brew uninstall`, so it is
/// bookkeeping rather than evidence of an installed version.
@Test func brewCaskWithOnlyMetadataIsNotInstalled() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.emptyDirectory("Caskroom", "ghostty", ".metadata", "1.2.3")
    #expect(!BrewHelper.isInstalled("ghostty", type: .cask, prefix: fixture.path))
}

/// Casks and formulas live in separate roots and must not satisfy each other's queries —
/// `codex` is a cask on the test machine while an empty `Cellar/codex` also exists.
@Test func brewCaskAndFormulaDoNotCrossMatch() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("codex", version: "0.143.0", cask: true)
    #expect(BrewHelper.isInstalled("codex", type: .cask, prefix: fixture.path))
    #expect(!BrewHelper.isInstalled("codex", type: .formula, prefix: fixture.path))
}

// MARK: - Short name

@Test func brewShortNameStripsTapQualification() {
    #expect(BrewHelper.shortName("cloudflare/cloudflare/cloudflared") == "cloudflared")
    #expect(BrewHelper.shortName("wget") == "wget")
}

// MARK: - BrewVersion

@Test(arguments: [
    ("1.104.1", [1, 104, 1], 0),
    ("1.104.1_1", [1, 104, 1], 1),
    ("3.0", [3, 0], 0),
    ("2024.08.2", [2024, 8, 2], 0),
    ("1.2.3,456", [1, 2, 3, 456], 0),
])
func brewVersionParses(_ string: String, parts: [Int], revision: Int) throws {
    let version = try #require(BrewVersion(string))
    #expect(version.parts == parts)
    #expect(version.revision == revision)
    #expect(version.description == string)
}

/// A `HEAD-…` keg and a cask's `latest` have no order to compare, so they must not parse
/// into one by accident.
@Test(arguments: ["HEAD-abc1234", "latest", "", "1..2", "1.2.", "v1.2.3", "+1.2", "1.2_x"])
func brewVersionRejectsNonNumeric(_ string: String) {
    #expect(BrewVersion(string) == nil)
}

@Test func brewVersionOrdersNumericallyAndByRevision() throws {
    func v(_ string: String) throws -> BrewVersion { try #require(BrewVersion(string)) }
    // Numeric, not lexical: the 1.98 → 1.102 boundary is the one ENG-3621 depends on.
    #expect(try v("1.98.10") < v("1.102.0"))
    #expect(try v("1.102") == v("1.102.0"))
    #expect(try !(v("1.102") < v("1.102.0")) && !(v("1.102.0") < v("1.102")))
    #expect(try v("1.104.1_0") < v("1.104.1_1"))
    #expect(try v("1.104.1_9") < v("1.104.2"))
    #expect(try v("1.2.3,456") > v("1.2.3"))
}

// MARK: - Installed version

/// With two kegs side by side, `opt/<name>` is what brew runs — even when it isn't the
/// highest, as after a `brew switch` or an interrupted upgrade.
@Test func brewInstalledVersionFollowsOptLink() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("tailscale", version: "1.98.1")
    try fixture.installed("tailscale", version: "1.104.1")
    try fixture.linked("tailscale", version: "1.98.1")
    #expect(BrewHelper.installedVersion("tailscale", type: .formula, prefix: fixture.path) == "1.98.1")
}

@Test func brewInstalledVersionFallsBackToHighestKeg() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("tailscale", version: "1.98.10")
    try fixture.installed("tailscale", version: "1.102.0")
    try fixture.installed("tailscale", version: "1.100.0")
    #expect(BrewHelper.installedVersion("tailscale", type: .formula, prefix: fixture.path) == "1.102.0")
}

/// A dangling link (its keg was removed) must not report a version that isn't installed.
@Test func brewInstalledVersionIgnoresLinkToMissingKeg() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("tailscale", version: "1.104.1")
    try fixture.linked("tailscale", version: "1.98.1")
    #expect(BrewHelper.installedVersion("tailscale", type: .formula, prefix: fixture.path) == "1.104.1")
}

@Test func brewInstalledVersionIgnoresMetadataAndEmptyKegs() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("ghostty", version: "1.2.3", cask: true)
    try fixture.emptyDirectory("Caskroom", "ghostty", ".metadata", "9.9.9")
    try fixture.emptyDirectory("Caskroom", "ghostty", "2.0.0")
    #expect(BrewHelper.installedVersion("ghostty", type: .cask, prefix: fixture.path) == "1.2.3")
}

@Test func brewInstalledVersionReportsUnparseableKegWhenNothingElseParses() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("wget", version: "HEAD-abc1234")
    #expect(BrewHelper.installedVersion("wget", type: .formula, prefix: fixture.path) == "HEAD-abc1234")
}

@Test func brewInstalledVersionIsNilWhenNotInstalled() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.emptyDirectory("Cellar", "wget")
    #expect(BrewHelper.installedVersion("wget", type: .formula, prefix: fixture.path) == nil)
}

// MARK: - Version check

@Test func brewCheckInstalledPolicy() throws {
    let fixture = try BrewPrefixFixture()
    #expect(BrewHelper.check("wget", type: .formula, version: .installed, prefix: fixture.path) == .notInstalled)
    try fixture.installed("wget", version: "1.0")
    #expect(BrewHelper.check("wget", type: .formula, version: .installed, prefix: fixture.path) == .satisfied)
}

@Test func brewCheckAtLeastPolicy() throws {
    let fixture = try BrewPrefixFixture()
    let policy = Brew.Version.atLeast("1.102.0")
    #expect(BrewHelper.check("tailscale", type: .formula, version: policy, prefix: fixture.path) == .notInstalled)

    try fixture.installed("tailscale", version: "1.98.1")
    #expect(BrewHelper.check("tailscale", type: .formula, version: policy, prefix: fixture.path)
        == .below(installed: "1.98.1", minimum: "1.102.0"))

    try fixture.installed("tailscale", version: "1.102.0")
    #expect(BrewHelper.check("tailscale", type: .formula, version: policy, prefix: fixture.path) == .satisfied)

    try fixture.installed("tailscale", version: "1.104.1_1")
    #expect(BrewHelper.check("tailscale", type: .formula, version: policy, prefix: fixture.path) == .satisfied)
}

@Test func brewCheckAtLeastUncomparable() throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("wget", version: "HEAD-abc1234")
    #expect(BrewHelper.check("wget", type: .formula, version: .atLeast("1.0"), prefix: fixture.path)
        == .uncomparable(installed: "HEAD-abc1234", minimum: "1.0"))

    try fixture.installed("tailscale", version: "1.104.1")
    #expect(BrewHelper.check("tailscale", type: .formula, version: .atLeast("v1.102"), prefix: fixture.path)
        == .uncomparable(installed: "1.104.1", minimum: "v1.102"))
}

/// The check time is process-wide, so each `.latest` test uses its own package name.
@Test func brewCheckLatestPolicy() async throws {
    let fixture = try BrewPrefixFixture()
    let name = "htop-\(UUID().uuidString)"
    let policy = Brew.Version.latest(checkEvery: .hours(24))
    try fixture.installed(name, version: "3.3.0")
    let start = ContinuousClock.now

    // Never checked in this process: due, which is what makes a daemon start re-check.
    #expect(BrewHelper.check(name, type: .formula, version: policy, prefix: fixture.path, now: start) == .updateDue)

    try await BrewHelper.$commandOverride.withValue({ _, _ in }) {
        try await BrewHelper.upgradeIfDue(name, type: .formula, every: .hours(24), user: nil, prefix: fixture.path, now: start)
    }
    #expect(BrewHelper.check(name, type: .formula, version: policy, prefix: fixture.path, now: start + .hours(23)) == .satisfied)
    #expect(BrewHelper.check(name, type: .formula, version: policy, prefix: fixture.path, now: start + .hours(24)) == .updateDue)
}

// MARK: - Upgrades

/// Records each argv a fake `brew` receives.
private actor BrewCalls {
    private(set) var argv: [[String]] = []
    func record(_ arguments: [String]) { argv.append(arguments) }
}

@Test func brewUpgradeIfBelowRunsUpgradeAndVerifies() async throws {
    let fixture = try BrewPrefixFixture()
    let prefix = fixture.path
    try fixture.installed("tailscale", version: "1.98.1")
    let calls = BrewCalls()

    try await BrewHelper.$commandOverride.withValue({ arguments, _ in
        await calls.record(arguments)
        try writeKeg(prefix: prefix, "tailscale", version: "1.104.1")
    }) {
        try await BrewHelper.upgradeIfBelow("tailscale", type: .formula, version: .atLeast("1.102.0"), user: nil, prefix: prefix)
    }

    #expect(await calls.argv == [["upgrade", "tailscale"]])
    #expect(BrewHelper.installedVersion("tailscale", type: .formula, prefix: prefix) == "1.104.1")
}

@Test func brewUpgradeIfBelowSkipsWhenSatisfied() async throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("tailscale", version: "1.104.1")
    let calls = BrewCalls()

    try await BrewHelper.$commandOverride.withValue({ arguments, _ in await calls.record(arguments) }) {
        try await BrewHelper.upgradeIfBelow("tailscale", type: .formula, version: .atLeast("1.102.0"), user: nil, prefix: fixture.path)
    }

    #expect(await calls.argv.isEmpty)
}

/// A floor Homebrew hasn't shipped (or a typo) must fail the mount, not pass silently.
@Test func brewUpgradeIfBelowThrowsWhenLatestIsStillBelow() async throws {
    let fixture = try BrewPrefixFixture()
    let prefix = fixture.path
    try fixture.installed("tailscale", version: "1.98.1")

    await #expect(throws: BrewError.self) {
        try await BrewHelper.$commandOverride.withValue({ _, _ in
            try writeKeg(prefix: prefix, "tailscale", version: "1.100.0")
        }) {
            try await BrewHelper.upgradeIfBelow("tailscale", type: .formula, version: .atLeast("1.102.0"), user: nil, prefix: prefix)
        }
    }
}

@Test func brewUpgradeIfBelowThrowsWithoutUpgradingWhenUncomparable() async throws {
    let fixture = try BrewPrefixFixture()
    try fixture.installed("wget", version: "HEAD-abc1234")
    let calls = BrewCalls()

    await #expect(throws: BrewError.self) {
        try await BrewHelper.$commandOverride.withValue({ arguments, _ in await calls.record(arguments) }) {
            try await BrewHelper.upgradeIfBelow("wget", type: .formula, version: .atLeast("1.0"), user: nil, prefix: fixture.path)
        }
    }
    #expect(await calls.argv.isEmpty)
}

@Test func brewUpgradeIfDueUpgradesCaskOnceWithinInterval() async throws {
    let fixture = try BrewPrefixFixture()
    let name = "ghostty-\(UUID().uuidString)"
    try fixture.installed(name, version: "1.2.3", cask: true)
    let calls = BrewCalls()
    let start = ContinuousClock.now

    try await BrewHelper.$commandOverride.withValue({ arguments, _ in await calls.record(arguments) }) {
        try await BrewHelper.upgradeIfDue(name, type: .cask, every: .hours(24), user: nil, prefix: fixture.path, now: start)
        try await BrewHelper.upgradeIfDue(name, type: .cask, every: .hours(24), user: nil, prefix: fixture.path, now: start + .hours(1))
    }

    #expect(await calls.argv == [["upgrade", "--cask", name]])
}

/// A failed upgrade (say, no network) must stay due so the drift loop retries it, rather
/// than waiting out another full interval.
@Test func brewUpgradeIfDueRecordsCheckOnlyOnSuccess() async throws {
    let fixture = try BrewPrefixFixture()
    let name = "htop-\(UUID().uuidString)"
    try fixture.installed(name, version: "3.3.0")
    let start = ContinuousClock.now

    struct Offline: Error {}
    await #expect(throws: Offline.self) {
        try await BrewHelper.$commandOverride.withValue({ _, _ in throw Offline() }) {
            try await BrewHelper.upgradeIfDue(name, type: .formula, every: .hours(24), user: nil, prefix: fixture.path, now: start)
        }
    }

    #expect(BrewHelper.check(name, type: .formula, version: .latest(), prefix: fixture.path, now: start + .seconds(15)) == .updateDue)
}

// MARK: - Identity

/// Changing the policy must not change the identity: a new identity unmounts the old node,
/// and unmounting a `Brew` runs `brew uninstall`.
@Test(arguments: [Brew.Version.installed, .atLeast("1.102.0"), .latest()])
func brewVersionPolicyKeepsIdentity(_ policy: Brew.Version) throws {
    let tree = TreeBuilder.build(Brew("tailscale", version: policy))
    #expect(tree.identity.path == [.named("brew:formula:tailscale")])
    guard case .leaf(let node) = tree.kind else {
        Issue.record("Expected .leaf kind")
        return
    }
    let info = try #require(node as? BrewInfo)
    #expect(info.version == policy)
}
