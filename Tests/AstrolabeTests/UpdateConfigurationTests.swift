import Foundation
import Testing
@testable import Astrolabe

// MARK: - Defaults

@Test func updateConfigurationDefaults() {
    let cfg = UpdateConfiguration(.gitHub("acme/mysetup"))
    #expect(cfg.interval == .seconds(3600))
    #expect(cfg.channel == .stable)
    if case .pkgSignatureRequired = cfg.verification {} else {
        #expect(Bool(false), "Expected default verification to be .pkgSignatureRequired")
    }
    #expect(cfg.allowDowngrade == false)
    #expect(cfg.githubToken == nil)
    #expect(cfg.preUpdate == nil)
    #expect(cfg.postUpdate == nil)
    #expect(cfg.onFail == nil)
}

// MARK: - Modifier chain

@Test func updateConfigurationInterval() {
    let cfg = UpdateConfiguration(.gitHub("a/b")).interval(.minutes(5))
    #expect(cfg.interval == .seconds(300))
}

@Test func updateConfigurationChannel() {
    let cfg = UpdateConfiguration(.gitHub("a/b")).channel(.prerelease)
    #expect(cfg.channel == .prerelease)
}

@Test func updateConfigurationVerifyTeamID() {
    let cfg = UpdateConfiguration(.gitHub("a/b")).verify(.codesignTeamID("ABCD123456"))
    if case .codesignTeamID(let id) = cfg.verification {
        #expect(id == "ABCD123456")
    } else {
        #expect(Bool(false), "Expected .codesignTeamID")
    }
}

@Test func updateConfigurationAllowDowngrade() {
    let cfg = UpdateConfiguration(.gitHub("a/b")).allowDowngrade()
    #expect(cfg.allowDowngrade == true)
    let cfg2 = cfg.allowDowngrade(false)
    #expect(cfg2.allowDowngrade == false)
}

@Test func updateConfigurationGitHubToken() {
    let cfg = UpdateConfiguration(.gitHub("a/b")).githubToken("ghp_x")
    #expect(cfg.githubToken == "ghp_x")
}

@Test func updateConfigurationCopyOnWrite() {
    let base = UpdateConfiguration(.gitHub("a/b"))
    _ = base.interval(.hours(2)).channel(.prerelease)
    // Original is untouched.
    #expect(base.interval == .seconds(3600))
    #expect(base.channel == .stable)
}

@Test func updateConfigurationHooksAreCaptured() async throws {
    let cfg = UpdateConfiguration(.gitHub("a/b"))
        .preUpdate  { _, _ in }
        .postUpdate { _ in }
        .onFail     { _ in }
    #expect(cfg.preUpdate != nil)
    #expect(cfg.postUpdate != nil)
    #expect(cfg.onFail != nil)
}

// MARK: - GitHubReleaseSource construction

@Test func gitHubReleaseSourceDotSyntax() {
    let source: GitHubReleaseSource = .gitHub("acme/mysetup")
    #expect(source.repo == "acme/mysetup")
    #expect(source.pin == .latest)
}

@Test func gitHubReleaseSourcePinnedTag() {
    let source: GitHubReleaseSource = .gitHub("acme/mysetup", version: .tag("v1.2.3"))
    if case .tag(let t) = source.pin {
        #expect(t == "v1.2.3")
    } else {
        #expect(Bool(false), "Expected .tag pin")
    }
}

// MARK: - Update status storage namespacing

@Test func updateStatusStorageUsesNamespacedKeys() {
    #expect(UpdateStatusStorage.Key.lastCheckedAt.hasPrefix("astrolabe.update."))
    #expect(UpdateStatusStorage.Key.lastSeenVersion.hasPrefix("astrolabe.update."))
    #expect(UpdateStatusStorage.Key.lastUpdatedAt.hasPrefix("astrolabe.update."))
    #expect(UpdateStatusStorage.Key.lastError.hasPrefix("astrolabe.update."))
}

// MARK: - Verification: Team ID extraction

@Test func verificationExtractsTeamID() {
    let sampleOutput = """
    Package "mysetup-1.0.0.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2024-01-15 12:34:56 +0000
       Certificate Chain:
        1. Developer ID Installer: Acme Inc. (ABCD123456)
           SHA1 fingerprint: 00 11 22 33 ...
    """
    let id = UpdateVerificationRunner.extractTeamID(from: sampleOutput)
    #expect(id == "ABCD123456")
}

@Test func verificationReturnsNilForUnsigned() {
    let sampleOutput = """
    Package "mysetup-1.0.0.pkg":
       Status: no signature
    """
    #expect(UpdateVerificationRunner.extractTeamID(from: sampleOutput) == nil)
}

@Test func verificationIgnoresTeamIDOutsideSignerLine() {
    // A stray 10-char identifier in the package filename should NOT be
    // picked up — only the one on a "Developer ID Installer" line.
    let sampleOutput = """
    Package "mysetup-1.0.0-(FAKE000000).pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Certificate Chain:
        1. Developer ID Installer: Acme Inc. (REALTEAMID)
           SHA1 fingerprint: 00 11 22 33 ...
    """
    #expect(UpdateVerificationRunner.extractTeamID(from: sampleOutput) == "REALTEAMID")
}

@Test func verificationAcceptsApplicationSigner() {
    let sampleOutput = """
    Package "embeddedapp.pkg":
       Certificate Chain:
        1. Developer ID Application: Foo LLC (APPTEAMID0)
    """
    #expect(UpdateVerificationRunner.extractTeamID(from: sampleOutput) == "APPTEAMID0")
}
