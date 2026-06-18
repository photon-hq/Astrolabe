import Foundation
import Testing
@testable import Astrolabe

// MARK: - isTransientLaunchctlError

@Test func transientErrorDetectsBootstrapEIO() {
    let err = ReconcileError.processFailed(
        path: "/bin/launchctl",
        arguments: ["bootstrap", "system", "/Library/LaunchDaemons/codes.photon.astrolabe.plist"],
        output: "Bootstrap failed: 5: Input/output error\n"
    )
    #expect(LaunchctlHelper.isTransientLaunchctlError(err))
}

@Test func transientErrorDetectsOperationInProgress() {
    let err = ReconcileError.processFailed(
        path: "/bin/launchctl",
        arguments: ["bootstrap", "system", "/x.plist"],
        output: "Bootstrap failed: 37: Operation now in progress\n"
    )
    #expect(LaunchctlHelper.isTransientLaunchctlError(err))
}

@Test func transientErrorIgnoresPermanentFailures() {
    // errno 5 message but a permanent cause (bad plist) — must NOT be retried.
    let err = ReconcileError.processFailed(
        path: "/bin/launchctl",
        arguments: ["bootstrap", "system", "/x.plist"],
        output: "Bootstrap failed: 5: Path had bad ownership/permissions\n"
    )
    #expect(!LaunchctlHelper.isTransientLaunchctlError(err))
}

@Test func transientErrorIgnoresNonProcessErrors() {
    struct SomeOtherError: Error {}
    #expect(!LaunchctlHelper.isTransientLaunchctlError(SomeOtherError()))
}

// MARK: - plistDiffers

@Test func plistDiffersWhenFileMissing() {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-missing-\(UUID().uuidString).plist").path
    #expect(DaemonManager.plistDiffers(at: path, from: ["Label": "x"]))
}

@Test func plistDiffersFalseWhenIdentical() throws {
    let candidate: [String: Any] = [
        "Label": "codes.photon.astrolabe",
        "ProgramArguments": ["/usr/local/bin/macrocosm-astrolabe"],
        "KeepAlive": true,
        "RunAtLoad": true,
        "StandardOutPath": "/var/log/codes.photon.astrolabe.log",
    ]
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-\(UUID().uuidString).plist")
    let data = try PropertyListSerialization.data(fromPropertyList: candidate, format: .xml, options: 0)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    // Round-trips through plist serialization (Bool -> CFBoolean) and back: equal.
    #expect(!DaemonManager.plistDiffers(at: url.path, from: candidate))
}

@Test func plistDiffersTrueWhenChanged() throws {
    let onDisk: [String: Any] = ["Label": "x", "KeepAlive": true]
    let candidate: [String: Any] = ["Label": "x", "KeepAlive": false]
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-\(UUID().uuidString).plist")
    let data = try PropertyListSerialization.data(fromPropertyList: onDisk, format: .xml, options: 0)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(DaemonManager.plistDiffers(at: url.path, from: candidate))
}
