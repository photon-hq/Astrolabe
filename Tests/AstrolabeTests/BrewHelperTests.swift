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
        let keg = "\(path)/\(cask ? "Caskroom" : "Cellar")/\(name)/\(version)"
        try FileManager.default.createDirectory(atPath: keg, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: "\(keg)/INSTALL_RECEIPT.json"))
    }

    /// Creates a directory but leaves it empty.
    func emptyDirectory(_ components: String...) throws {
        try FileManager.default.createDirectory(
            atPath: ([path] + components).joined(separator: "/"),
            withIntermediateDirectories: true
        )
    }
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
