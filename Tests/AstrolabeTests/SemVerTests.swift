import Foundation
import Testing
@testable import Astrolabe

// MARK: - Parsing

@Test func semVerParsesBasic() {
    let v = SemVer("1.2.3")
    #expect(v?.major == 1)
    #expect(v?.minor == 2)
    #expect(v?.patch == 3)
    #expect(v?.preRelease == nil)
}

@Test func semVerStripsLeadingV() {
    #expect(SemVer("v1.2.3") == SemVer("1.2.3"))
    #expect(SemVer("V1.2.3") == SemVer("1.2.3"))
}

@Test func semVerParsesPrerelease() {
    let v = SemVer("1.2.3-beta.1")
    #expect(v?.major == 1)
    #expect(v?.preRelease == "beta.1")
}

@Test func semVerIgnoresBuildMetadata() {
    let v = SemVer("1.2.3+sha.abc123")
    #expect(v?.major == 1)
    #expect(v?.minor == 2)
    #expect(v?.patch == 3)
    #expect(v?.preRelease == nil)
}

@Test func semVerRejectsMalformed() {
    #expect(SemVer("") == nil)
    #expect(SemVer("1") == nil)
    #expect(SemVer("1.2") == nil)
    #expect(SemVer("1.2.x") == nil)
    #expect(SemVer("1.2.3-") == nil)
    #expect(SemVer("not.a.version") == nil)
}

// MARK: - Ordering

@Test func semVerOrdersPatch() {
    #expect(SemVer("1.2.3")! < SemVer("1.2.4")!)
    #expect(SemVer("1.2.10")! > SemVer("1.2.9")!)  // numeric, not lexicographic
}

@Test func semVerOrdersMinorBeforePatch() {
    #expect(SemVer("1.3.0")! > SemVer("1.2.99")!)
}

@Test func semVerOrdersMajorBeforeMinor() {
    #expect(SemVer("2.0.0")! > SemVer("1.99.99")!)
}

@Test func semVerEqualsItself() {
    #expect(SemVer("1.2.3")! == SemVer("1.2.3")!)
    #expect(!(SemVer("1.2.3")! < SemVer("1.2.3")!))
}

@Test func semVerReleaseGreaterThanPrerelease() {
    // §11.3 — release > any prerelease of same M.m.p
    #expect(SemVer("1.0.0")! > SemVer("1.0.0-beta.1")!)
    #expect(SemVer("1.0.0-beta.1")! < SemVer("1.0.0")!)
}

@Test func semVerPrereleaseOrdering() {
    // §11.4 — dot-separated, numeric < alphanumeric, same-type lex
    #expect(SemVer("1.0.0-alpha")! < SemVer("1.0.0-beta")!)
    #expect(SemVer("1.0.0-alpha.1")! < SemVer("1.0.0-alpha.2")!)
    #expect(SemVer("1.0.0-alpha.1")! < SemVer("1.0.0-alpha.beta")!)  // numeric < alphanum
    #expect(SemVer("1.0.0-alpha")! < SemVer("1.0.0-alpha.1")!)        // fewer fields < more
}

// MARK: - Description

@Test func semVerRoundtrips() {
    #expect(SemVer("1.2.3")!.description == "1.2.3")
    #expect(SemVer("1.2.3-beta.1")!.description == "1.2.3-beta.1")
}
