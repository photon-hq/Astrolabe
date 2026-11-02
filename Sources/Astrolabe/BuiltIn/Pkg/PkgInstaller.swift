import Foundation
import Semaphore
import Synchronization

/// The Mac `Pkg` acts on, plus the lock its rollouts and removals share.
///
/// Task-local, so tests bind their own: the engine's run task, its fact loops and its operations
/// all inherit it.
final class PkgContext: Sendable {
    @TaskLocal static var current = PkgContext(system: InstallerPkgSystem())

    let system: any PkgSystem
    /// One `installer` or uninstall at a time: two `installer`s at once can fail on macOS's
    /// install lock, and an uninstall must not read another package's receipts half written.
    let lock = AsyncSemaphore(value: 1)
    /// Every `.latest` a pass has declared since launch: what the `latestTags` fact checks.
    let latestQueries = Mutex<Set<LatestTagQuery>>([])
    /// When each query last failed, so a broken repo isn't asked every minute.
    let latestFailures = Mutex<[LatestTagQuery: Date]>([:])

    init(system: any PkgSystem) {
        self.system = system
    }
}

/// Installs, upgrades and uninstalls `.pkg`s, and keeps what it installed in a marker.
enum PkgInstaller {
    /// Makes sure the package keyed `key` is installed as `hash` describes.
    ///
    /// Checks the marker first, without the lock: when its hash matches and its receipts are all
    /// on the Mac, it changes nothing and never waits. Otherwise, under the lock, `fetch`
    /// downloads the `.pkg` into a fresh directory (removed after), the receipts are read from
    /// it, its signature checked unless `allowUntrusted`, and `installer` runs. The receipts the
    /// old version wrote and this one doesn't are uninstalled, and the marker is written.
    static func install(
        key: String,
        hash: String,
        allowUntrusted: Bool,
        fetch: @Sendable (URL) async throws -> URL
    ) async throws {
        let context = PkgContext.current
        let system = context.system
        if try isCurrent(key, hash: hash, system) { return }

        try await locked(context) {
            try Task.checkCancellation()
            if try isCurrent(key, hash: hash, system) { return }  // another rollout just did it
            let old = try system.marker(key)

            let directory = try system.makeWorkDirectory()
            defer { system.removeWorkDirectory(directory) }
            let pkg = try await fetch(directory)
            try Task.checkCancellation()
            let inferred = try await system.componentIdentifiers(of: pkg)
            try Task.checkCancellation()
            if !allowUntrusted { try await system.checkSignature(pkg) }
            try Task.checkCancellation()

            let owned = old?.receipts ?? []
            let before = try system.receiptStamps()
            print("[Astrolabe] pkg \(key): installing (receipts \(inferred.isEmpty ? "unknown" : inferred.joined(separator: ", ")))")
            do {
                try await system.install(pkg, allowUntrusted: allowUntrusted)
            } catch {
                // `installer` may have written receipts before it failed, or before the cancel
                // that ended it: keep them owned, so a removal still finds them, with a hash that
                // never matches, so the next rollout installs again.
                if let after = try? system.receiptStamps(), !written(before: before, after: after).isEmpty {
                    let receipts = self.receipts(inferred: inferred, owned: owned, before: before, after: after)
                    try? system.writeMarker(PkgMarker(key: key, hash: "", receipts: receipts.union(owned).sorted(), installedAt: Date()))
                }
                throw error
            }
            // Installed. Only cleanup below can be cancelled, and the interim marker it writes
            // first keeps every receipt, so a cancelled upgrade is finished by the next rollout.
            let after = try system.receiptStamps()
            let receipts = self.receipts(inferred: inferred, owned: owned, before: before, after: after)
            if receipts.isEmpty {
                print("[Astrolabe] pkg \(key): installed, but it wrote no receipt: drift goes unseen, and removing it removes nothing")
            }

            let dropped = Set(owned).subtracting(receipts)
            if !dropped.isEmpty {
                // Keeps every receipt it may still own, with a hash that never matches, so a
                // cleanup that fails is retried rather than forgotten.
                try system.writeMarker(PkgMarker(key: key, hash: "", receipts: receipts.union(dropped).sorted(), installedAt: Date()))
                print("[Astrolabe] pkg \(key): the new version dropped \(dropped.sorted().joined(separator: ", "))")
                try await uninstallReceipts(dropped.sorted(), system)
            }
            try system.writeMarker(PkgMarker(key: key, hash: hash, receipts: receipts.sorted(), installedAt: Date()))
        }
    }

    /// Uninstalls what the marker of `key` lists, then deletes the marker. No marker: nothing is
    /// known about it, so nothing is removed.
    static func uninstall(key: String) async throws {
        let context = PkgContext.current
        let system = context.system
        guard try system.marker(key) != nil else {
            print("[Astrolabe] pkg \(key): no marker, nothing to uninstall")
            return
        }

        try await locked(context) {
            // Declared again while waiting: the engine cancelled this, and nothing is uninstalled.
            try Task.checkCancellation()
            guard let marker = try system.marker(key) else { return }
            print("[Astrolabe] pkg \(key): uninstalling \(marker.receipts.joined(separator: ", "))")
            // Before anything is deleted: a removal cut short leaves the receipts on the Mac and
            // the marker listing them, and a hash that matched would then skip the reinstall.
            if !marker.hash.isEmpty {
                try system.writeMarker(PkgMarker(key: key, hash: "", receipts: marker.receipts, installedAt: marker.installedAt))
            }
            try await uninstallReceipts(marker.receipts, system)
            try system.deleteMarker(key)
        }
    }

    /// Pure: the receipts of `inferred` this package owns now. Those `installer` just wrote, and
    /// those an earlier version installed (`owned`) that are still on the Mac. An optional choice
    /// it skipped is dropped, even when something else installed that receipt. When none of
    /// `inferred`, every receipt `installer` wrote.
    static func receipts(inferred: [String], owned: [String], before: [String: Date], after: [String: Date]) -> Set<String> {
        let written = written(before: before, after: after)
        let kept = Set(inferred).intersection(written.union(Set(owned).intersection(after.keys)))
        return kept.isEmpty ? written : kept
    }

    /// Pure: the receipts that are new since `before`, or whose database file changed.
    static func written(before: [String: Date], after: [String: Date]) -> Set<String> {
        Set(after.compactMap { id, stamp in before[id] == stamp ? nil : id })
    }

    /// Call under the lock. Removes what the receipts `ids` list and no other receipt claims:
    /// launchd jobs booted out, then files deleted, then directories pruned deepest first, only
    /// when empty and never `protectedDirectories`. Then forgets the receipts. A receipt already
    /// gone is skipped: what it listed is unknown.
    static func uninstallReceipts(_ ids: [String], _ system: any PkgSystem) async throws {
        let onMac = try system.receipts()
        let targets = ids.filter(onMac.contains)
        for missing in ids where !onMac.contains(missing) {
            print("[Astrolabe] receipt \(missing) is already gone: its files are unknown")
        }
        guard !targets.isEmpty else { return }

        var files: Set<String> = []
        var directories: Set<String> = []
        for id in targets {
            let paths = try await system.receiptPaths(id)
            files.formUnion(paths.files)
            directories.formUnion(paths.directories)
        }
        // A file another receipt lists stays: the new version of an upgrade, or a shared framework.
        var claimed: Set<String> = []
        for other in onMac.subtracting(targets).sorted() {
            let paths = try await system.receiptPaths(other)
            claimed.formUnion(paths.files)
            claimed.formUnion(paths.directories)
        }
        files.subtract(claimed)
        directories.subtract(claimed)

        // Before any file goes: a job whose plist or binary vanishes keeps running.
        for file in files.sorted() {
            if let agent = launchdJob(file) { await system.bootout(plist: file, agent: agent) }
        }
        for file in files.sorted() { try system.deleteFile(file) }
        let prunable = directories.filter { !isProtected($0) }.sorted { lhs, rhs in
            let (l, r) = (depth(lhs), depth(rhs))
            return l != r ? l > r : lhs < rhs
        }
        for directory in prunable { try system.removeDirectoryIfEmpty(directory) }
        for id in targets { try await system.forget(id) }
    }

    /// Never pruned, even when a receipt lists them and they're empty.
    static let protectedDirectories: Set<String> = [
        "/", "/Applications", "/Applications/Utilities", "/Library", "/Library/Application Support",
        "/Library/Caches", "/Library/Extensions", "/Library/Frameworks", "/Library/LaunchAgents",
        "/Library/LaunchDaemons", "/Library/Logs", "/Library/Preferences", "/Library/PrivilegedHelperTools",
        "/Library/Security", "/Library/StartupItems", "/System", "/Users", "/bin", "/sbin", "/etc", "/var",
        "/tmp", "/opt", "/opt/homebrew", "/private", "/private/etc", "/private/var", "/private/tmp", "/usr",
        "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/usr/local", "/usr/local/bin",
        "/usr/local/sbin", "/usr/local/lib", "/usr/local/include", "/usr/local/share", "/usr/local/etc",
        "/usr/local/opt", "/usr/local/share/man",
    ]

    /// Protected, or right under `/`.
    static func isProtected(_ directory: String) -> Bool {
        protectedDirectories.contains(directory) || depth(directory) <= 1
    }

    /// For a launchd plist: `false` for a daemon, `true` for an agent. `nil` for anything else.
    static func launchdJob(_ path: String) -> Bool? {
        guard path.hasSuffix(".plist") else { return nil }
        if path.hasPrefix("/Library/LaunchDaemons/") { return false }
        if path.hasPrefix("/Library/LaunchAgents/") { return true }
        return nil
    }

    // MARK: - Private

    /// The marker's hash is `hash`, and every receipt in it is on the Mac.
    private static func isCurrent(_ key: String, hash: String, _ system: any PkgSystem) throws -> Bool {
        guard let marker = try system.marker(key), marker.hash == hash else { return false }
        return Set(marker.receipts).isSubset(of: try system.receipts())
    }

    private static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    /// Runs `body` holding the context's lock. Waiting is cancellable.
    private static func locked<T>(_ context: PkgContext, _ body: () async throws -> T) async throws -> T {
        try await context.lock.waitUnlessCancelled()
        defer { context.lock.signal() }
        return try await body()
    }
}

enum PkgError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The release has no asset matching the filter.
    case noMatchingAsset(repo: String, tag: String)
    /// The download answered with something other than 200.
    case downloadFailed(url: String, status: Int)
    /// The URL source's download doesn't match its declared `sha256`.
    case checksumMismatch(name: String, expected: String, actual: String)
    /// `pkgutil --check-signature` failed, and `allowUntrusted` isn't set.
    case untrusted(output: String)
    /// `installer` exited non-zero.
    case installFailed(output: String)
    /// `pkgutil --pkg-info-plist` printed no plist.
    case unreadableReceipt(String)
    /// A `.latest` reached a rollout before its tag was known. `Pkg` declares one only to keep an
    /// installed package in place; it's retried until the tag lands and replaces it.
    case unresolvedTag(repo: String)

    var description: String {
        switch self {
        case .noMatchingAsset(let repo, let tag):
            "\(repo) \(tag) has no matching asset"
        case .downloadFailed(let url, let status):
            "downloading \(url) failed (status \(status))"
        case .checksumMismatch(let name, let expected, let actual):
            "\(name)'s download has sha256 \(actual), not \(expected)"
        case .untrusted(let output):
            "the package isn't signed by a trusted identity (set allowUntrusted to install it anyway): \(output)"
        case .installFailed(let output):
            "installer failed: \(output)"
        case .unreadableReceipt(let id):
            "pkgutil printed no info for receipt \(id)"
        case .unresolvedTag(let repo):
            "\(repo): the latest release isn't known yet"
        }
    }
}
