import Foundation
import Testing
@testable import Astrolabe

// MARK: - Fixtures

private let pkgResourceTypes: [any Resource.Type] = fakeResourceTypes + [PkgInstall.self]

private let v1 = URL(string: "https://example.com/tool-1.0.pkg")!
private let v2 = URL(string: "https://example.com/tool-2.0.pkg")!
private let toolID = "pkg:tool"
private let receipt = "com.example.tool"

/// What `com.example.tool` lists: a binary, a daemon, and its directories, `/usr/local` among them.
private let toolPaths = ReceiptPaths(
    files: ["/usr/local/tool/bin/tool", "/Library/LaunchDaemons/com.example.tool.plist"],
    directories: ["/usr/local", "/usr/local/tool", "/usr/local/tool/bin", "/Library/LaunchDaemons"]
)

private let toolPackage = FakePkgSystem.Package(identifiers: [receipt], installs: [receipt: toolPaths])

private func source(_ url: URL = v1, sha256: String? = nil) -> PkgSource {
    .url(url, name: "tool", sha256: sha256)
}

private func hash(_ source: PkgSource, allowUntrusted: Bool = false) -> String {
    PkgInstall.compute(PkgInstall(source: source, allowUntrusted: allowUntrusted))
}

/// `PkgInstall.rollout` on `fake`, as the engine runs it.
@MainActor
private func install(_ source: PkgSource, allowUntrusted: Bool = false, on fake: FakePkgSystem) async throws {
    try await withPkg(fake) { _ in try await PkgInstall.rollout(PkgInstall(source: source, allowUntrusted: allowUntrusted)) }
}

/// `PkgInstaller.uninstall` on `fake`.
@MainActor
private func uninstall(_ key: String = "tool", on fake: FakePkgSystem) async throws {
    try await withPkg(fake) { _ in try await PkgInstaller.uninstall(key: key) }
}

/// A fake with `toolPackage` served at `v1`.
private func serving(_ package: FakePkgSystem.Package = toolPackage, at url: URL = v1) -> FakePkgSystem {
    let fake = FakePkgSystem()
    fake.serve(url, package)
    return fake
}

/// The tool at `v1` while `test.tracked` is 0, at `v2` at 1, and dropped after.
private struct SwitchingPkgApp: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        switch test.tracked {
        case 0: Pkg(source(v1))
        case 1: Pkg(source(v2))
        default: EmptyComponent()
        }
    }
}

private struct NoPkgApp: Astrolabe {
    var body: some Component { EmptyComponent() }
}

/// `org/tool` v1 from GitHub, with a token from `PkgTokenFile.path`.
private struct GitHubPkgApp: Astrolabe {
    var body: some Component {
        Pkg(.gitHub("org/tool", tag: "v1", token: .file(PkgTokenFile.path)))
    }
}

/// `org/tool` at its latest release.
private struct LatestPkgApp: Astrolabe {
    var body: some Component {
        Pkg(.gitHub("org/tool", tag: .latest))
    }
}

/// `org/tool` pinned at v1 while `test.tracked` is 0, at its latest release after.
private struct PinnedThenLatestPkgApp: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        if test.tracked == 0 {
            Pkg(.gitHub("org/tool", tag: "v1"))
        } else {
            Pkg(.gitHub("org/tool", tag: .latest))
        }
    }
}

/// `PinnedThenLatestPkgApp`, plus `org/other` at a latest release that never resolves: its
/// pass reads `marked` at launch, so `org/tool`'s flip sees a value from before its marker.
private struct WarmMarkedPkgApp: Astrolabe {
    @Fact(\.test) var test

    var body: some Component {
        Pkg(.gitHub("org/other", tag: .latest))
        if test.tracked == 0 {
            Pkg(.gitHub("org/tool", tag: "v1"))
        } else {
            Pkg(.gitHub("org/tool", tag: .latest))
        }
    }
}

private let toolLatest = LatestTagQuery(repo: "org/tool", token: nil, options: GitHubReleases.Options(asset: .pkg))

private enum PkgTokenFile {
    static let path = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabe-pkg-token-\(UUID().uuidString)").path
    static let secret = "ghp_s3cretTOKENvalue"
}

private func release(
    _ id: Int, _ tag: String, prerelease: Bool = false, draft: Bool = false, published: String? = nil, assets: [String] = ["tool.pkg"]
) -> GitHubRelease {
    GitHubRelease(
        id: id, tagName: tag,
        assets: assets.map {
            GitHubAsset(name: $0, apiURL: URL(string: "https://api.example.com/\($0)")!, downloadURL: URL(string: "https://example.com/\($0)")!)
        },
        prerelease: prerelease, draft: draft,
        createdAt: published ?? String(format: "2026-01-%02dT00:00:00Z", id), publishedAt: published
    )
}

@Suite(.timeLimit(.minutes(1)))
struct PkgTests {
    // MARK: - Resource

    @MainActor
    struct PkgResource {
        @Test func aNewTagKeepsTheIdAndMovesTheHash() {
            let old = PkgInstall(source: .gitHub("org/tool", tag: "v1.4.0"), allowUntrusted: false)
            let new = PkgInstall(source: .gitHub("org/tool", tag: "v1.5.0"), allowUntrusted: false)
            #expect(old.id == "pkg:org/tool")
            #expect(old.id == new.id)
            #expect(PkgInstall.compute(old) != PkgInstall.compute(new))
        }

        @Test func theTokenChangesNothing() {
            let none = PkgSource.gitHub("org/tool", tag: "v1")
            let file = PkgSource.gitHub("org/tool", tag: "v1", token: .file("/etc/astrolabe/github-token"))
            let environment = PkgSource.gitHub("org/tool", tag: "v1", token: .environment("GITHUB_TOKEN"))
            #expect(hash(none) == hash(file))
            #expect(hash(none) == hash(environment))
            #expect(PkgInstall(source: file, allowUntrusted: false).id == PkgInstall(source: none, allowUntrusted: false).id)
        }

        @Test func theAssetAndAllowUntrustedMoveTheHash() {
            #expect(hash(.gitHub("org/tool", tag: "v1")) != hash(.gitHub("org/tool", tag: "v1", asset: .regex("arm64"))))
            #expect(hash(.gitHub("org/tool", tag: "v1", asset: .filename("a.pkg"))) != hash(.gitHub("org/tool", tag: "v1", asset: .regex("a.pkg"))))
            #expect(hash(source()) != hash(source(), allowUntrusted: true))
        }

        @Test func theURLSourcesIdComesFromItsName() {
            #expect(PkgInstall(source: source(v1), allowUntrusted: false).id == toolID)
            #expect(PkgInstall(source: source(v2), allowUntrusted: false).id == toolID)
            #expect(hash(source(v1)) != hash(source(v2)))
            #expect(hash(source(v1)) != hash(source(v1, sha256: "ab")))
            #expect(hash(source(v1, sha256: "AB")) == hash(source(v1, sha256: "ab")))
        }

        @Test func theMonitorStaysOutOfTheHash() throws {
            let snapshot = try AnyResource(PkgInstall(source: source(), allowUntrusted: false)).encode()
            guard case .object(var object) = snapshot else { Issue.record("not an object"); return }
            object["installed"] = .bool(true)
            let read = try JSONDecoder().decode(PkgInstall.self, from: JSONEncoder().encode(JSONValue.object(object)))
            #expect(read.installed == true)
            #expect(PkgInstall.compute(read) == hash(source()))
        }

        @Test func theSnapshotRoundTripsAndHoldsOnlyTheTokensPath() throws {
            let pkg = PkgInstall(
                source: .gitHub("org/tool", tag: "v1", asset: .regex(#"arm64\.pkg$"#), token: .file("/etc/astrolabe/github-token")),
                allowUntrusted: false
            )
            let snapshot = try AnyResource(pkg).encode()
            #expect(snapshot == .object([
                "source": .object(["gitHub": .object([
                    "repo": .string("org/tool"), "tag": .string("v1"),
                    "asset": .object(["regex": .object(["pattern": .string(#"arm64\.pkg$"#)])]),
                    "token": .object(["file": .object(["path": .string("/etc/astrolabe/github-token")])]),
                ])]),
                "allowUntrusted": .bool(false),
            ]))
            let registry = try ResourceRegistry([PkgInstall.self])
            let decoded = try AnyResource.decode(kind: PkgInstall.kind, snapshot, registry: registry)
            #expect(try decoded.encode() == snapshot)
            #expect(decoded.hash() == PkgInstall.compute(pkg))

            let url = try AnyResource(PkgInstall(source: source(sha256: "ab"), allowUntrusted: true)).encode()
            #expect(url == .object([
                "source": .object(["url": .object([
                    "url": .string(v1.absoluteString), "name": .string("tool"), "sha256": .string("ab"),
                ])]),
                "allowUntrusted": .bool(true),
            ]))
        }

        @Test func aNamedTagIsAStringInTheSnapshotAndLatestRoundTrips() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            #expect(String(decoding: try encoder.encode(GitHubTag("v1")), as: UTF8.self) == #""v1""#)
            #expect(try JSONDecoder().decode(GitHubTag.self, from: Data(#""v1""#.utf8)) == .named("v1"))
            for tag in [GitHubTag.latest, .latest(prereleases: true, matching: "^v2", asset: .regex("arm64"), order: .version)] {
                #expect(try JSONDecoder().decode(GitHubTag.self, from: encoder.encode(tag)) == tag)
            }
        }

        @Test func aNamedTagHashesAsItsString() {
            #expect(hash(.gitHub("org/tool", tag: "v1")) == hash(.gitHub("org/tool", tag: .named("v1"))))
            #expect(hash(.gitHub("org/tool", tag: "v1")) == PkgInstall.compute(PkgInstall(source: .gitHub("org/tool", tag: "v1"), allowUntrusted: false)))
            #expect(hash(.gitHub("org/tool", tag: "v1")) == Hash.of(PkgInstall.kind, "gitHub", "org/tool", "v1", "pkg", false))
        }

        @Test func inAPassTheMonitorReadsInstalled() async throws {
            let store = FactStore(wake: Wake(), clock: EngineClock(ManualClock()), telemetry: NoopAstrolabeTelemetry())
            defer { store.stopAll() }
            store.inject(\.pkgs.installed, ["tool"])

            let (installed, atDefault) = store.tracking { PkgInstall(source: source(), allowUntrusted: false) }
            #expect(installed.installed == true)
            #expect(atDefault.isEmpty)
            let (missing, _) = store.tracking { PkgInstall(source: .gitHub("org/other", tag: "v1"), allowUntrusted: false) }
            #expect(missing.installed == false)
        }
    }

    // MARK: - Install

    @MainActor
    struct Install {
        @Test func itInfersTheReceiptsAndWritesTheMarker() async throws {
            let fake = serving()
            try await install(source(), on: fake)
            #expect(fake.calls == [
                .download(v1), .componentIdentifiers, .checkSignature, .install(allowUntrusted: false),
                .writeMarker("tool", hash: hash(source()), receipts: [receipt]),
            ])
            #expect(fake.markerOnMac("tool")?.receipts == [receipt])
            #expect(fake.receiptIDs == [receipt])
            #expect(fake.workDirectories.count == 1)
            #expect(fake.workDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }

        @Test func whenTheMarkerMatchesItSkips() async throws {
            let fake = serving()
            try await install(source(), on: fake)
            let calls = fake.calls.count
            try await install(source(), on: fake)
            #expect(fake.calls.count == calls)
        }

        @Test func aForgottenReceiptIsInstalledAgain() async throws {
            let fake = serving()
            try await install(source(), on: fake)
            fake.forgetByHand(receipt)
            try await install(source(), on: fake)
            #expect(fake.installs == 2)
            #expect(fake.receiptIDs == [receipt])
        }

        @Test func itKeepsOnlyTheInferredReceiptsInstallerWrote() async throws {
            // An optional choice, `extras`, isn't installed. `com.other` was there before.
            let fake = serving(.init(identifiers: [receipt, "com.example.extras"], installs: [receipt: toolPaths]))
            fake.preinstall("com.other", ReceiptPaths(files: ["/usr/local/other"]))
            try await install(source(), on: fake)
            #expect(fake.markerOnMac("tool")?.receipts == [receipt])
        }

        @Test func withNoInferredReceiptWrittenItKeepsTheNewOnes() async throws {
            let fake = serving(.init(identifiers: ["com.example.wrong"], installs: [receipt: toolPaths]))
            fake.preinstall("com.other", ReceiptPaths(files: ["/usr/local/other"]))
            try await install(source(), on: fake)
            #expect(fake.markerOnMac("tool")?.receipts == [receipt])
        }

        @Test func aPackageThatWritesNoReceiptRecordsNone() async throws {
            let fake = serving(.init(identifiers: [], installs: [:]))
            try await install(source(), on: fake)
            #expect(fake.markerOnMac("tool")?.receipts == [])
            try await install(source(), on: fake)
            #expect(fake.installs == 1, "an empty marker still matches")
        }

        @Test func thePureReceiptChoice() {
            func d(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
            func receipts(_ inferred: [String], owned: [String] = [], _ before: [String: Date], _ after: [String: Date]) -> Set<String> {
                PkgInstaller.receipts(inferred: inferred, owned: owned, before: before, after: after)
            }
            #expect(receipts(["a", "b"], ["x": d(1)], ["x": d(1), "a": d(2)]) == ["a"])
            #expect(receipts(["c"], ["x": d(1)], ["x": d(1), "a": d(2)]) == ["a"])
            #expect(receipts([], ["x": d(1)], ["x": d(1)]) == [])
            #expect(receipts(["x"], ["x": d(1)], ["x": d(2)]) == ["x"], "a reinstall over itself")
            #expect(receipts(["a", "b"], ["b": d(1)], ["a": d(2), "b": d(1)]) == ["a"], "b was there, and installer skipped it")
            #expect(receipts(["a", "b"], owned: ["b"], ["b": d(1)], ["a": d(2), "b": d(1)]) == ["a", "b"], "an earlier version installed b")
            #expect(receipts(["a"], owned: ["b"], ["b": d(1)], ["a": d(2), "b": d(1)]) == ["a"], "the new version doesn't list b")
        }

        @Test func aSkippedOptionalReceiptSomethingElseInstalledIsNeverClaimed() async throws {
            // `extras` is an optional choice installer skips, already on the Mac from elsewhere.
            let extras = "com.example.extras"
            let fake = serving(.init(identifiers: [receipt, extras], installs: [receipt: toolPaths]))
            fake.preinstall(extras, ReceiptPaths(files: ["/usr/local/extras"]))
            try await install(source(), on: fake)
            #expect(fake.markerOnMac("tool")?.receipts == [receipt])

            try await uninstall(on: fake)
            #expect(fake.receiptIDs == [extras])
            #expect(fake.filesOnMac == ["/usr/local/extras"])
        }

        @Test func anInstallThatWroteReceiptsBeforeFailingKeepsThemOwned() async throws {
            let fake = serving()
            fake.fail(.afterInstall)
            await #expect(throws: FakePkgSystem.FakeError.self) { try await install(source(), on: fake) }
            #expect(fake.markerOnMac("tool")?.receipts == [receipt])
            #expect(fake.markerOnMac("tool")?.hash == "", "never current: the next rollout installs again")

            try await install(source(), on: fake)
            #expect(fake.installs == 2)
            #expect(fake.markerOnMac("tool")?.hash == hash(source()))
        }

        @Test func anInstallThatFailedAfterWritingReceiptsCanStillBeRemoved() async throws {
            let fake = serving()
            fake.fail(.afterInstall)
            await #expect(throws: FakePkgSystem.FakeError.self) { try await install(source(), on: fake) }
            try await uninstall(on: fake)
            #expect(fake.receiptIDs.isEmpty)
            #expect(fake.filesOnMac.isEmpty)
            #expect(fake.markerOnMac("tool") == nil)
        }

        @Test func anUpgradeForgetsTheReceiptsItDroppedAndKeepsWhatTheNewOneClaims() async throws {
            let shared = "/usr/local/tool/lib/shared.dylib"
            let fake = serving(.init(identifiers: ["com.example.old"], installs: [
                "com.example.old": ReceiptPaths(files: ["/usr/local/tool/old", shared], directories: ["/usr/local/tool", "/usr/local/tool/lib"]),
            ]))
            fake.serve(v2, .init(identifiers: ["com.example.new"], installs: [
                "com.example.new": ReceiptPaths(files: ["/usr/local/tool/new", shared], directories: ["/usr/local/tool", "/usr/local/tool/lib"]),
            ]))
            try await install(source(v1), on: fake)
            try await install(source(v2), on: fake)

            #expect(fake.receiptIDs == ["com.example.new"])
            #expect(fake.filesOnMac == ["/usr/local/tool/new", shared])
            #expect(fake.directoriesOnMac.isSuperset(of: ["/usr/local/tool", "/usr/local/tool/lib"]))
            #expect(fake.markerOnMac("tool")?.receipts == ["com.example.new"])
            #expect(fake.markerOnMac("tool")?.hash == hash(source(v2)))
            // The marker kept the dropped receipt until it was gone.
            #expect(fake.calls.contains(.writeMarker("tool", hash: "", receipts: ["com.example.new", "com.example.old"])))
            #expect(!fake.calls.contains(.deleteMarker("tool")))
        }

        @Test func aFailedUpgradeCleanupIsRetried() async throws {
            let fake = serving(.init(identifiers: ["com.example.old"], installs: ["com.example.old": ReceiptPaths(files: ["/usr/local/old"])]))
            fake.serve(v2, .init(identifiers: ["com.example.new"], installs: ["com.example.new": ReceiptPaths(files: ["/usr/local/new"])]))
            try await install(source(v1), on: fake)
            fake.fail(.forget)
            await #expect(throws: FakePkgSystem.FakeError.self) { try await install(source(v2), on: fake) }
            #expect(fake.markerOnMac("tool")?.receipts == ["com.example.new", "com.example.old"])

            try await install(source(v2), on: fake)
            #expect(fake.receiptIDs == ["com.example.new"])
            #expect(fake.markerOnMac("tool")?.receipts == ["com.example.new"])
            #expect(fake.markerOnMac("tool")?.hash == hash(source(v2)))
        }

        @Test func anUnsignedPackageThrows() async throws {
            var package = toolPackage
            package.signed = false
            let fake = serving(package)
            await #expect(throws: PkgError.untrusted(output: "Status: no signature")) { try await install(source(), on: fake) }
            #expect(fake.installs == 0)
            #expect(fake.markerOnMac("tool") == nil)
        }

        @Test func allowUntrustedSkipsTheCheck() async throws {
            var package = toolPackage
            package.signed = false
            let fake = serving(package)
            try await install(source(), allowUntrusted: true, on: fake)
            #expect(!fake.calls.contains(.checkSignature))
            #expect(fake.calls.contains(.install(allowUntrusted: true)))
            #expect(fake.markerOnMac("tool") != nil)
        }

        @Test func aMismatchedSha256Throws() async throws {
            let fake = serving()
            await #expect(throws: PkgError.self) { try await install(source(sha256: String(repeating: "0", count: 64)), on: fake) }
            #expect(fake.installs == 0)
            #expect(fake.markerOnMac("tool") == nil)
        }

        @Test func aMatchingSha256Installs() async throws {
            let fake = serving()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabe-sha-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data(v1.absoluteString.utf8).write(to: file)  // what the fake downloads
            let sha256 = try PkgSource.sha256(of: file)
            try await install(source(sha256: sha256.uppercased()), on: fake)
            #expect(fake.installs == 1)
        }

        @Test func cancellingRemovesTheWorkDirectory() async throws {
            let fake = serving()
            fake.hold(.download)
            try await withPkg(fake) { _ in
                let task = Task { try await PkgInstall.rollout(PkgInstall(source: source(), allowUntrusted: false)) }
                await eventually("downloading") { fake.calls.contains(.download(v1)) }
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            #expect(fake.workDirectories.count == 1)
            #expect(!FileManager.default.fileExists(atPath: fake.workDirectories[0].path))
            #expect(fake.installs == 0)
            #expect(fake.markerOnMac("tool") == nil)
        }

        @Test func aFailedInstallWritesNoMarker() async throws {
            let fake = serving()
            fake.fail(.install)
            await #expect(throws: FakePkgSystem.FakeError.self) { try await install(source(), on: fake) }
            #expect(fake.markerOnMac("tool") == nil)
            #expect(fake.workDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }

        @Test func aGitHubReleaseIsDownloadedWithTheTokenFromItsFile() async throws {
            let token = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabe-token-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: token) }
            try Data("  secret-token\n".utf8).write(to: token)
            let fake = FakePkgSystem()
            let published = fake.publish("org/tool", tag: "v1", assets: ["notes.txt": toolPackage, "tool-1.0.pkg": toolPackage])

            try await install(.gitHub("org/tool", tag: "v1", token: .file(token.path)), on: fake)
            let asset = try #require(published.assets.first { $0.name == "tool-1.0.pkg" })
            #expect(Array(fake.calls.prefix(2)) == [.release("org/tool", tag: "v1", token: "secret-token"), .download(asset.apiURL)])
            #expect(fake.markerOnMac("org/tool")?.receipts == [receipt])
        }

        @Test func aPublicReleaseUsesTheBrowserURL() async throws {
            let fake = FakePkgSystem()
            let published = fake.publish("org/tool", tag: "v1", assets: ["tool-1.0.pkg": toolPackage])
            try await install(.gitHub("org/tool", tag: "v1"), on: fake)
            #expect(fake.calls.contains(.download(published.assets[0].downloadURL)))
        }

        @Test func aMissingTokenThrowsBeforeAnyRequest() async throws {
            let fake = FakePkgSystem()
            fake.publish("org/tool", tag: "v1", assets: ["tool-1.0.pkg": toolPackage])
            let missing = GitHubToken.file("/nonexistent/astrolabe-token")
            await #expect(throws: GitHubReleasesError.tokenUnavailable(missing)) {
                try await install(.gitHub("org/tool", tag: "v1", token: missing), on: fake)
            }
            #expect(fake.calls.isEmpty)
        }

        @Test func aReleaseWithoutTheAssetThrows() async throws {
            let fake = FakePkgSystem()
            fake.publish("org/tool", tag: "v1", assets: ["tool.zip": toolPackage])
            await #expect(throws: PkgError.noMatchingAsset(repo: "org/tool", tag: "v1")) {
                try await install(.gitHub("org/tool", tag: "v1"), on: fake)
            }
            #expect(fake.installs == 0)
        }
    }

    // MARK: - Uninstall

    @MainActor
    struct Uninstall {
        @Test func itDeletesUnclaimedFilesAndKeepsClaimedOnes() async throws {
            let shared = "/usr/local/tool/bin/shared"
            let fake = serving(.init(identifiers: [receipt], installs: [
                receipt: ReceiptPaths(files: ["/usr/local/tool/bin/tool", shared], directories: ["/usr/local/tool", "/usr/local/tool/bin"]),
            ]))
            fake.preinstall("com.other", ReceiptPaths(files: [shared]))
            try await install(source(), on: fake)
            try await uninstall(on: fake)

            #expect(fake.filesOnMac == [shared])
            #expect(!fake.calls.contains(.deleteFile(shared)))
            #expect(fake.calls.contains(.deleteFile("/usr/local/tool/bin/tool")))
            // `bin` holds the shared file, so it and `tool` stay.
            #expect(fake.directoriesOnMac.isSuperset(of: ["/usr/local/tool", "/usr/local/tool/bin"]))
            #expect(fake.receiptIDs == ["com.other"])
        }

        @Test func itPrunesEmptyDirectoriesDeepestFirstAndNeverProtectedOnes() async throws {
            let fake = serving()
            try await install(source(), on: fake)
            try await uninstall(on: fake)
            let pruned = fake.calls.compactMap { if case .removeDirectory(let path) = $0 { path } else { nil } }
            #expect(pruned == ["/usr/local/tool/bin", "/usr/local/tool"])
            #expect(fake.directoriesOnMac == ["/usr/local", "/Library/LaunchDaemons"])
            #expect(fake.filesOnMac.isEmpty)
        }

        @Test func protectedDirectories() {
            for directory in ["/", "/usr", "/usr/local", "/usr/local/bin", "/Applications", "/Library", "/opt", "/private", "/Library/LaunchDaemons", "/Foo"] {
                #expect(PkgInstaller.isProtected(directory), "\(directory)")
            }
            for directory in ["/usr/local/tool", "/Applications/Tool.app", "/Library/Application Support/Tool"] {
                #expect(!PkgInstaller.isProtected(directory), "\(directory)")
            }
        }

        @Test func itBootsOutLaunchdJobsBeforeDeletingAnything() async throws {
            let daemon = "/Library/LaunchDaemons/com.example.tool.plist"
            let agent = "/Library/LaunchAgents/com.example.tool.agent.plist"
            let fake = serving(.init(identifiers: [receipt], installs: [
                receipt: ReceiptPaths(files: ["/usr/local/tool/tool", daemon, agent, "/Library/LaunchDaemons/README"]),
            ]))
            try await install(source(), on: fake)
            try await uninstall(on: fake)

            let changes = fake.changes.filter {
                switch $0 {
                case .bootout, .deleteFile: true
                default: false
                }
            }
            #expect(Array(changes.prefix(2)) == [.bootout(agent, agent: true), .bootout(daemon, agent: false)])
            #expect(changes.count == 6, "two boot-outs, then four deletions")
            #expect(fake.filesOnMac.isEmpty)
        }

        @Test func itForgetsTheReceiptsThenDeletesTheMarker() async throws {
            let fake = serving()
            try await install(source(), on: fake)
            try await uninstall(on: fake)
            #expect(Array(fake.changes.suffix(2)) == [.forget(receipt), .deleteMarker("tool")])
            #expect(fake.receiptIDs.isEmpty)
            #expect(fake.markerOnMac("tool") == nil)
        }

        @Test func withoutAMarkerItDoesNothing() async throws {
            let fake = FakePkgSystem()
            fake.preinstall(receipt, toolPaths)
            try await uninstall(on: fake)
            #expect(fake.calls.isEmpty)
            #expect(fake.receiptIDs == [receipt])
            #expect(fake.filesOnMac == Set(toolPaths.files))
        }

        @Test func anAlreadyForgottenReceiptIsSkipped() async throws {
            let fake = serving()
            try await install(source(), on: fake)
            fake.forgetByHand(receipt)
            try await uninstall(on: fake)
            #expect(fake.changes.last == .deleteMarker("tool"))
            #expect(!fake.changes.contains { if case .deleteFile = $0 { true } else { false } })
            #expect(fake.filesOnMac == Set(toolPaths.files), "what it listed is unknown")
        }

        @Test func aFailedForgetKeepsTheMarker() async throws {
            let fake = serving()
            try await install(source(), on: fake)
            fake.fail(.forget)
            await #expect(throws: FakePkgSystem.FakeError.self) { try await uninstall(on: fake) }
            #expect(fake.markerOnMac("tool") != nil)
            try await uninstall(on: fake)
            #expect(fake.markerOnMac("tool") == nil)
            #expect(fake.receiptIDs.isEmpty)
        }

        @Test func aRemovalCutShortNeverLeavesTheMarkerCurrent() async throws {
            let fake = serving()
            try await install(source(), on: fake)
            fake.fail(.forget)
            await #expect(throws: FakePkgSystem.FakeError.self) { try await uninstall(on: fake) }
            // The files are gone, the receipt and marker stay: declared again, it reinstalls.
            #expect(fake.filesOnMac.isEmpty)
            #expect(fake.markerOnMac("tool")?.hash == "")
            #expect(fake.markerOnMac("tool")?.receipts == [receipt])

            try await install(source(), on: fake)
            #expect(fake.installs == 2)
            #expect(fake.filesOnMac == Set(toolPaths.files))
            #expect(fake.markerOnMac("tool")?.hash == hash(source()))
        }

        @Test func aLaunchdPlistIsADaemonOrAnAgent() {
            #expect(PkgInstaller.launchdJob("/Library/LaunchDaemons/a.plist") == false)
            #expect(PkgInstaller.launchdJob("/Library/LaunchAgents/a.plist") == true)
            #expect(PkgInstaller.launchdJob("/Library/LaunchDaemons/a.txt") == nil)
            #expect(PkgInstaller.launchdJob("/usr/local/a.plist") == nil)
        }
    }

    // MARK: - Fact

    @MainActor
    struct InstalledFact {
        @Test func installedIsEveryKeyWithAllItsReceipts() async throws {
            let fake = FakePkgSystem()
            fake.preinstall("com.a", ReceiptPaths())
            fake.setMarker(PkgMarker(key: "a", hash: "h", receipts: ["com.a"], installedAt: Date()))
            fake.setMarker(PkgMarker(key: "b", hash: "h", receipts: ["com.a", "com.b"], installedAt: Date()))
            fake.setMarker(PkgMarker(key: "c", hash: "h", receipts: [], installedAt: Date()))
            let installed = try await withPkg(fake) { _ in try PkgReads.installed() }
            #expect(installed == ["a", "c"])
        }
    }

    // MARK: - Real system, on the file system

    struct OnDisk {
        @Test func markersRoundTripUnderAPercentEncodedName() throws {
            let directory = try TemporaryDirectory()
            let system = InstallerPkgSystem(markerDirectory: directory.url.appendingPathComponent("pkg"), receiptDirectories: [])
            #expect(try system.marker("org/tool") == nil)
            #expect(try system.markers().isEmpty)

            let marker = PkgMarker(key: "org/tool", hash: "h", receipts: ["com.org.tool"], installedAt: Date(timeIntervalSince1970: 1_800_000_000))
            try system.writeMarker(marker)
            #expect(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("pkg/org%2Ftool.json").path))
            #expect(try system.marker("org/tool") == marker)

            try Data("garbage".utf8).write(to: directory.url.appendingPathComponent("pkg/broken.json"))
            #expect(try system.markers() == [marker])

            try system.deleteMarker("org/tool")
            try system.deleteMarker("org/tool")
            #expect(try system.marker("org/tool") == nil)
        }

        @Test func receiptsAreThePlistNamesInEveryDatabase() throws {
            let directory = try TemporaryDirectory()
            let first = directory.url.appendingPathComponent("a").path
            let second = directory.url.appendingPathComponent("b").path
            for path in [first, second] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            for name in ["com.a.plist", "com.a.bom", "com.b.plist"] { FileManager.default.createFile(atPath: "\(first)/\(name)", contents: Data()) }
            FileManager.default.createFile(atPath: "\(second)/com.apple.pkg.Core.plist", contents: Data())
            let system = InstallerPkgSystem(markerDirectory: directory.url, receiptDirectories: [first, second, "/nonexistent"])
            #expect(try system.receipts() == ["com.a", "com.b", "com.apple.pkg.Core"])
        }

        @Test func joinNeverStandardizes() {
            #expect(InstallerPkgSystem.join(["/", "usr/local", "bin/tool"]) == "/usr/local/bin/tool")
            #expect(InstallerPkgSystem.join(["/", "/", "./Applications/Tool.app"]) == "/Applications/Tool.app")
            #expect(InstallerPkgSystem.join(["/", "", "private/var/db"]) == "/private/var/db")
            #expect(InstallerPkgSystem.join(["/", "usr", "../etc/passwd"]) == nil)
            #expect(InstallerPkgSystem.join(["/", "/"]) == "/")
        }

        @Test func packageInfoGivesItsIdentifier() {
            let info = #"<?xml version="1.0" encoding="utf-8"?><pkg-info format-version="2" identifier="com.scriptingosx.Installomator" version="10.8" install-location="/" auth="root"><payload numberOfFiles="3"/></pkg-info>"#
            #expect(PackageInfo.identifier(in: Data(info.utf8)) == "com.scriptingosx.Installomator")
            #expect(PackageInfo.identifier(in: Data("<installer-gui-script/>".utf8)) == nil)
            #expect(PackageInfo.identifier(in: Data("not xml".utf8)) == nil)
        }

        @Test func deleteFileLeavesDirectoriesAndPruneLeavesFullOnes() throws {
            let directory = try TemporaryDirectory()
            let system = InstallerPkgSystem(markerDirectory: directory.url, receiptDirectories: [])
            let root = directory.url.path
            try FileManager.default.createDirectory(atPath: "\(root)/a/b", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: "\(root)/a/file", contents: Data())

            try system.deleteFile("\(root)/a/b")  // a directory: left
            #expect(FileManager.default.fileExists(atPath: "\(root)/a/b"))
            try system.removeDirectoryIfEmpty("\(root)/a")  // not empty: left
            #expect(FileManager.default.fileExists(atPath: "\(root)/a"))

            try system.deleteFile("\(root)/a/file")
            try system.deleteFile("\(root)/a/file")
            try system.removeDirectoryIfEmpty("\(root)/a/b")
            try system.removeDirectoryIfEmpty("\(root)/a")
            try system.removeDirectoryIfEmpty("\(root)/missing")
            #expect(!FileManager.default.fileExists(atPath: "\(root)/a"))
        }

        @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/productbuild")))
        func pkgutilReadsTheIdentifiersOfAComponentAndADistribution() async throws {
            let directory = try TemporaryDirectory()
            let root = directory.url.path
            try FileManager.default.createDirectory(atPath: "\(root)/payload/usr/local/astrolabe-test", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: "\(root)/payload/usr/local/astrolabe-test/file", contents: Data("hi".utf8))
            for id in ["com.example.astrolabe.a", "com.example.astrolabe.b"] {
                try await ProcessRunner.run("/usr/bin/pkgbuild", arguments: [
                    "--root", "\(root)/payload", "--identifier", id, "--version", "1", "--install-location", "/", "\(root)/\(id).pkg",
                ])
            }
            try await ProcessRunner.run("/usr/bin/productbuild", arguments: [
                "--package", "\(root)/com.example.astrolabe.a.pkg", "--package", "\(root)/com.example.astrolabe.b.pkg", "\(root)/dist.pkg",
            ])
            let system = InstallerPkgSystem(markerDirectory: directory.url, receiptDirectories: [])
            for (name, expected) in [("com.example.astrolabe.a", ["com.example.astrolabe.a"]), ("dist", ["com.example.astrolabe.a", "com.example.astrolabe.b"])] {
                let work = directory.url.appendingPathComponent("work-\(name)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let pkg = work.appendingPathComponent("package.pkg")
                try FileManager.default.copyItem(atPath: "\(root)/\(name).pkg", toPath: pkg.path)
                #expect(try await system.componentIdentifiers(of: pkg) == expected)
                await #expect(throws: PkgError.self) { try await system.checkSignature(pkg) }
            }
        }

        @Test func latestTagsRoundTripBesideTheMarkersAndAGarbledFileThrows() throws {
            let directory = try TemporaryDirectory()
            let system = InstallerPkgSystem(markerDirectory: directory.url.appendingPathComponent("pkg"), receiptDirectories: [])
            #expect(try system.latestTagCache().isEmpty)
            let cache = [toolLatest: LatestTagEntry(tag: "v1", checkedAt: Date(timeIntervalSince1970: 1_800_000_000))]
            try system.writeLatestTagCache(cache)
            #expect(try system.latestTagCache() == cache)
            #expect(try system.markers().isEmpty, "not a marker")
            try Data("garbage".utf8).write(to: system.latestTagsURL)
            #expect(throws: (any Error).self) { try system.latestTagCache() }
        }

        @Test func aWorkDirectoryIsPrivateAndRemoved() throws {
            let directory = try TemporaryDirectory()
            let system = InstallerPkgSystem(markerDirectory: directory.url, receiptDirectories: [], workRoot: directory.url.path)
            let work = try system.makeWorkDirectory()
            #expect(work.lastPathComponent.hasPrefix("astrolabe-pkg-"))
            let mode = try FileManager.default.attributesOfItem(atPath: work.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
            FileManager.default.createFile(atPath: work.appendingPathComponent("package.pkg").path, contents: Data())
            system.removeWorkDirectory(work)
            #expect(!FileManager.default.fileExists(atPath: work.path))
        }
    }

    // MARK: - Latest release

    struct LatestRelease {
        typealias Options = GitHubReleases.Options

        @Test func withNoOptionsItIsTheDefault() {
            #expect(Options().isDefault)
            #expect(!Options(prereleases: true).isDefault)
            #expect(!Options(tag: "^v2").isDefault)
            #expect(!Options(asset: .pkg).isDefault)
            #expect(!Options(order: .version).isDefault)
        }

        @Test func draftsAreNeverPicked() throws {
            let releases = [release(1, "v1"), release(2, "v2", draft: true)]
            #expect(try GitHubReleases.select(releases, Options(prereleases: true))?.tagName == "v1")
        }

        @Test func prereleasesOnlyWhenAsked() throws {
            let releases = [release(1, "v1"), release(2, "v2-rc1", prerelease: true)]
            #expect(try GitHubReleases.select(releases, Options(order: .published))?.tagName == "v1")
            #expect(try GitHubReleases.select(releases, Options(prereleases: true))?.tagName == "v2-rc1")
        }

        @Test func theTagPatternPinsALine() throws {
            let releases = [release(1, "v2.4"), release(2, "v3.0"), release(3, "v2.5")]
            #expect(try GitHubReleases.select(releases, Options(tag: #"^v2\."#))?.tagName == "v2.5")
            #expect(try GitHubReleases.select(releases, Options(tag: #"^v4\."#)) == nil)
        }

        @Test func anAssetCanBeRequired() throws {
            let releases = [release(1, "v1", assets: ["tool.pkg"]), release(2, "v2", assets: ["tool.zip"])]
            #expect(try GitHubReleases.select(releases, Options(asset: .pkg))?.tagName == "v1")
            #expect(try GitHubReleases.select(releases, Options(asset: .regex(#"\.zip$"#)))?.tagName == "v2")
            #expect(try GitHubReleases.select(releases, Options(asset: .filename("tool.dmg"))) == nil)
        }

        @Test func publishedOrderIsNewestFirst() throws {
            let releases = [
                release(1, "v3.0", published: "2026-01-01T00:00:00Z"),
                release(2, "v2.9", published: "2026-03-01T00:00:00Z"),
                release(3, "v2.10", published: "2026-02-01T00:00:00Z"),
            ]
            #expect(try GitHubReleases.select(releases, Options(asset: .pkg))?.tagName == "v2.9")
            #expect(try GitHubReleases.select(releases, Options(order: .version))?.tagName == "v3.0")
            #expect(try GitHubReleases.select(Array(releases.dropFirst()), Options(order: .version))?.tagName == "v2.10")
        }

        @Test func versionOrderSortsUnparseableTagsLast() throws {
            let releases = [release(1, "v1.0"), release(2, "nightly"), release(3, "v1.1-beta")]
            #expect(try GitHubReleases.select(releases, Options(order: .version))?.tagName == "v1.0")
            let none = [release(1, "alpha"), release(2, "beta")]
            #expect(try GitHubReleases.select(none, Options(order: .version))?.tagName == "beta", "newest published")
        }

        @Test func versionsStripALeadingV() {
            #expect(GitHubReleases.version(of: "v10.8") == BrewVersion("10.8"))
            #expect(GitHubReleases.version(of: "10.8") == BrewVersion("10.8"))
            #expect(GitHubReleases.version(of: "v1.2.3-beta") == nil)
        }

        @Test func noMatchThrows() throws {
            #expect(throws: GitHubReleasesError.noMatchingRelease(repo: "org/tool")) {
                try GitHubReleases.latestTag(of: "org/tool", in: [release(1, "v1", draft: true)], Options(order: .version))
            }
            #expect(try GitHubReleases.latestTag(of: "org/tool", in: [release(1, "v1")], Options(order: .version)) == "v1")
        }

        @Test func aBadPatternThrows() {
            #expect(throws: GitHubReleasesError.invalidPattern("(")) {
                try GitHubReleases.select([release(1, "v1")], Options(tag: "("))
            }
            #expect(throws: GitHubReleasesError.invalidPattern("[")) {
                try GitHubReleases.select([release(1, "v1")], Options(asset: .regex("[")))
            }
        }

        @Test func aTokenResolvesTrimmedOrThrows() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabe-token-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data(" tok\n".utf8).write(to: file)
            #expect(try GitHubToken.file(file.path).resolve() == "tok")
            try Data("\n".utf8).write(to: file)
            #expect(throws: GitHubReleasesError.tokenUnavailable(.file(file.path))) { try GitHubToken.file(file.path).resolve() }
            #expect(throws: GitHubReleasesError.self) { try GitHubToken.environment("ASTROLABE_NO_SUCH_TOKEN_\(UUID().uuidString.prefix(8))").resolve() }
        }
    }

    // MARK: - Latest

    @MainActor
    struct Latest {
        @Test func latestResolvesInBodyAndDeclaresTheTag() async throws {
            let fake = FakePkgSystem()
            fake.setLatest("org/tool", "v1")
            fake.publish("org/tool", tag: "v1", assets: ["tool-1.pkg": toolPackage])
            try await withPkg(fake) { _ in
                try await withEngine(LatestPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("on record") { h.diskRecord("pkg:org/tool") != nil }
                    await h.settle()
                    #expect(h.diskRecord("pkg:org/tool")?.hash == hash(.gitHub("org/tool", tag: "v1")))
                    #expect(fake.calls.contains(.release("org/tool", tag: "v1", token: nil)))
                    #expect(fake.savedLatestTags[toolLatest]?.tag == "v1", "the query carries Pkg's asset")
                    #expect(fake.latestChecks("org/tool") == 1)
                }
            }
        }

        @Test func aNewReleaseUpgradesWithinTheHour() async throws {
            let fake = FakePkgSystem()
            fake.setLatest("org/tool", "v1")
            fake.publish("org/tool", tag: "v1", assets: ["tool-1.pkg": toolPackage])
            fake.publish("org/tool", tag: "v2", assets: ["tool-2.pkg": toolPackage])
            try await withPkg(fake) { _ in
                try await withEngine(LatestPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("on record") { h.diskRecord("pkg:org/tool") != nil }
                    fake.setLatest("org/tool", "v2")
                    // Under an hour old: GitHub isn't asked.
                    await h.advance(.seconds(60))
                    #expect(fake.latestChecks("org/tool") == 1)

                    fake.wallClock += 3600
                    await h.advance(.seconds(60))
                    await eventually("upgraded") { h.diskRecord("pkg:org/tool")?.hash == hash(.gitHub("org/tool", tag: "v2")) }
                    await h.settle()
                    #expect(fake.latestChecks("org/tool") == 2)
                    #expect(fake.installs == 2)
                    #expect(!fake.changes.contains(.deleteMarker("org/tool")))
                }
            }
        }

        @Test func untilTheFirstCheckLandsNothingIsDeclaredAndAFailureWaitsFiveMinutes() async throws {
            let fake = FakePkgSystem()
            fake.setLatest("org/tool", "v1")
            fake.publish("org/tool", tag: "v1", assets: ["tool-1.pkg": toolPackage])
            fake.fail(.latestTag)
            try await withPkg(fake) { _ in
                try await withEngine(LatestPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("checked") { fake.latestChecks("org/tool") == 1 }
                    await h.settle()
                    #expect(h.diskRecord("pkg:org/tool") == nil)
                    await h.advance(.seconds(60))
                    #expect(fake.latestChecks("org/tool") == 1, "retried after 5 minutes, not every minute")

                    fake.wallClock += 5 * 60
                    await h.advance(.seconds(60))
                    await eventually("on record") { h.diskRecord("pkg:org/tool") != nil }
                    #expect(fake.latestChecks("org/tool") == 2)
                }
            }
        }

        @Test func afterARestartWithGitHubDownTheSavedTagKeepsItInstalled() async throws {
            let fake = FakePkgSystem()
            fake.setLatest("org/tool", "v1")
            fake.publish("org/tool", tag: "v1", assets: ["tool-1.pkg": toolPackage])
            try await withPkg(fake) { _ in
                try await withEngine(LatestPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("on record") { h.diskRecord("pkg:org/tool") != nil }
                    await h.settle()

                    // A new launch: nothing declared yet, GitHub failing, and the tag stale.
                    fake.wallClock += 2 * 3600
                    fake.fail(.latestTag, times: 100)
                    await h.restart()
                    await h.advance(.seconds(60))
                    #expect(fake.latestChecks("org/tool") >= 2)
                    #expect(h.diskRecord("pkg:org/tool")?.hash == hash(.gitHub("org/tool", tag: "v1")))
                    #expect(!fake.changes.contains(.deleteMarker("org/tool")))
                    #expect(fake.installs == 1)
                }
            }
        }

        @Test func turnedLatestWhileGitHubIsDownItStaysInstalledThenUpgrades() async throws {
            let fake = FakePkgSystem()
            fake.publish("org/tool", tag: "v1", assets: ["tool-1.pkg": toolPackage])
            fake.publish("org/tool", tag: "v2", assets: ["tool-2.pkg": toolPackage])
            fake.setLatest("org/tool", "v2")
            try await withPkg(fake) { _ in
                try await withEngine(PinnedThenLatestPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("pinned") { h.diskRecord("pkg:org/tool")?.hash == hash(.gitHub("org/tool", tag: "v1")) }
                    await h.settle()

                    // A new query, never checked, and GitHub failing: the installed one stays.
                    fake.fail(.latestTag)
                    h.state.tracked = 1
                    await eventually("checked") { fake.latestChecks("org/tool") == 1 }
                    await h.advance(.seconds(60))
                    await h.settle()
                    #expect(!fake.changes.contains(.deleteMarker("org/tool")))
                    #expect(fake.receiptIDs == [receipt])
                    #expect(h.diskRecord("pkg:org/tool")?.hash == hash(.gitHub("org/tool", tag: "v1")))

                    fake.wallClock += 5 * 60
                    await h.advance(.seconds(60))
                    await eventually("upgraded") { h.diskRecord("pkg:org/tool")?.hash == hash(.gitHub("org/tool", tag: "v2")) }
                    await h.settle()
                    #expect(fake.installs == 2)
                    #expect(!fake.changes.contains(.deleteMarker("org/tool")))
                }
            }
        }

        @Test func turnedLatestWithinAMinuteOfItsInstallItStaysInstalled() async throws {
            let fake = FakePkgSystem()
            fake.publish("org/tool", tag: "v1", assets: ["tool-1.pkg": toolPackage])
            try await withPkg(fake) { _ in
                try await withEngine(WarmMarkedPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("pinned") { h.diskRecord("pkg:org/tool") != nil }
                    await h.settle()
                    // No minute passes: `marked` still holds the read from before the install.
                    h.state.tracked = 1
                    await h.settle()
                    #expect(!fake.changes.contains(.deleteMarker("org/tool")))
                    #expect(fake.receiptIDs == [receipt])
                    #expect(fake.filesOnMac == Set(toolPaths.files))
                }
            }
        }

        @Test func aLatestReachingARolloutThrows() async throws {
            let fake = FakePkgSystem()
            await #expect(throws: PkgError.unresolvedTag(repo: "org/tool")) {
                try await install(.gitHub("org/tool", tag: .latest), on: fake)
            }
        }
    }

    // MARK: - Engine

    @MainActor
    struct InEngine {
        @Test func aForgottenReceiptIsReinstalledWithinAMinute() async throws {
            let fake = serving()
            try await withPkg(fake) { _ in
                try await withEngine(SwitchingPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("on record") { h.diskRecord(toolID) != nil }
                    // The next read sees the install: one rollout, which installs nothing.
                    await h.advance(.seconds(60))
                    #expect(fake.installs == 1)

                    fake.forgetByHand(receipt)
                    await h.advance(.seconds(60))
                    await eventually("installed again") { fake.installs == 2 }
                    await h.settle()
                    #expect(fake.receiptIDs == [receipt])
                    await h.advance(.seconds(60))
                    await h.advance(.seconds(60))
                    #expect(fake.installs == 2)
                    #expect(h.logs("astrolabe.operation.failed").isEmpty)
                }
            }
        }

        @Test func aNewVersionUpgradesInPlace() async throws {
            let fake = serving()
            fake.serve(v2, toolPackage)
            try await withPkg(fake) { _ in
                try await withEngine(SwitchingPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("on record") { h.diskRecord(toolID)?.hash == hash(source(v1)) }
                    h.state.tracked = 1
                    await eventually("upgraded") { h.diskRecord(toolID)?.hash == hash(source(v2)) }
                    await h.settle()
                    #expect(fake.installs == 2)
                    #expect(fake.calls.contains(.download(v2)))
                    #expect(!fake.changes.contains(.deleteMarker("tool")))
                    #expect(!fake.changes.contains(.forget(receipt)))
                    #expect(fake.markerOnMac("tool")?.hash == hash(source(v2)))
                }
            }
        }

        @Test func droppedFromBodyItIsUninstalled() async throws {
            let fake = serving()
            try await withPkg(fake) { _ in
                try await withEngine(SwitchingPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("on record") { h.diskRecord(toolID) != nil }
                    h.state.tracked = 2
                    await eventually("record removed") { h.diskRecord(toolID) == nil }
                    await h.settle()
                    #expect(fake.markerOnMac("tool") == nil)
                    #expect(fake.receiptIDs.isEmpty)
                    #expect(fake.filesOnMac.isEmpty)
                }
            }
        }

        @Test func droppedWhileTheDaemonWasDownItIsUninstalled() async throws {
            let directory = try TemporaryDirectory()
            let pkg = PkgInstall(source: source(), allowUntrusted: false)
            try RecordStore(url: directory.recordsURL).set(
                toolID, Record(kind: PkgInstall.kind, hash: PkgInstall.compute(pkg), snapshot: try AnyResource(pkg).encode())
            )
            let fake = FakePkgSystem()
            fake.preinstall(receipt, toolPaths)
            fake.setMarker(PkgMarker(key: "tool", hash: PkgInstall.compute(pkg), receipts: [receipt], installedAt: Date()))
            try await withPkg(fake) { _ in
                let h = EngineHarness<NoPkgApp>(recordsURL: directory.recordsURL, resourceTypes: pkgResourceTypes)
                await h.start()
                await eventually("record removed") { h.diskRecord(toolID) == nil }
                await h.settle()
                #expect(fake.markerOnMac("tool") == nil)
                #expect(fake.receiptIDs.isEmpty)
                #expect(fake.filesOnMac.isEmpty)
                await h.stop()
            }
        }

        @Test func recordsHoldTheTokensPathAndNeverTheToken() async throws {
            try Data(PkgTokenFile.secret.utf8).write(to: URL(fileURLWithPath: PkgTokenFile.path))
            defer { try? FileManager.default.removeItem(atPath: PkgTokenFile.path) }
            let fake = FakePkgSystem()
            fake.publish("org/tool", tag: "v1", assets: ["tool-1.0.pkg": toolPackage])
            try await withPkg(fake) { _ in
                try await withEngine(GitHubPkgApp.self, resourceTypes: pkgResourceTypes) { h in
                    await eventually("on record") { h.diskRecord("pkg:org/tool") != nil }
                    await h.settle()
                    #expect(fake.calls.contains(.release("org/tool", tag: "v1", token: PkgTokenFile.secret)))
                    let records = try String(contentsOf: h.recordsURL, encoding: .utf8)
                    #expect(!records.contains(PkgTokenFile.secret))
                    #expect(records.contains(URL(fileURLWithPath: PkgTokenFile.path).lastPathComponent))
                }
            }
        }
    }
}
