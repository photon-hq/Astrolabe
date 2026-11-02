import Foundation
@testable import Astrolabe

/// Stands in for `pkgutil`, `installer`, the receipt databases, the marker directory and the
/// network. Bound through `PkgContext`, the way `FakeHomebrewSystem` is bound through
/// `HomebrewContext`.
///
/// Serves a `Package` per URL: a download writes the URL into the file, so every later step knows
/// which package it's looking at. Installing one lands its receipts with their files and
/// directories. Work directories are real, so a test can see they're removed. Records every
/// call, can fail some steps on command, and can hold them until released.
final class FakePkgSystem: PkgSystem, @unchecked Sendable {
    /// What a `.pkg` holds.
    struct Package: Sendable {
        /// The identifiers in its `PackageInfo`s.
        var identifiers: [String]
        /// The receipts `installer` writes, and what each lists. An optional choice that isn't
        /// installed is in `identifiers` and not here.
        var installs: [String: ReceiptPaths]
        var signed = true
    }

    enum Call: Equatable, Sendable {
        case release(String, tag: String, token: String?)
        case download(URL)
        case componentIdentifiers
        case checkSignature
        case install(allowUntrusted: Bool)
        case receiptPaths(String)
        case forget(String)
        case bootout(String, agent: Bool)
        case deleteFile(String)
        case removeDirectory(String)
        case writeMarker(String, hash: String, receipts: [String])
        case deleteMarker(String)
        case latestTag(String)
    }

    enum Step: Hashable, Sendable {
        /// `afterInstall` fails `installer` once its receipts are written, as a cancel that
        /// lands just as it exits does.
        case download, install, afterInstall, forget, receipts, latestTag
    }

    struct FakeError: Error {}

    private let lock = NSLock()
    private var served: [URL: Package] = [:]
    private var releases: [String: GitHubRelease] = [:]
    private var receiptsOnMac: [String: ReceiptPaths] = [:]
    /// Each receipt's database date: bumped whenever it's written.
    private var stamps: [String: Date] = [:]
    private var stampClock = Date(timeIntervalSince1970: 1_700_000_000)
    private var files: Set<String> = []
    private var directories: Set<String> = []
    private var markersOnMac: [String: PkgMarker] = [:]
    private var _workDirectories: [URL] = []
    private var _calls: [Call] = []
    private var failures: [Step: Int] = [:]
    private var held: Set<Step> = []
    private var latest: [String: String] = [:]
    private var latestCache: [LatestTagQuery: LatestTagEntry] = [:]
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The network

    /// What downloading `url` gets.
    func serve(_ url: URL, _ package: Package) {
        lock.withLock { served[url] = package }
    }

    /// A release of `repo` tagged `tag`, with one asset per name, served at
    /// `https://example.com/<repo>/<tag>/<name>` (`api.example.com` with a token).
    @discardableResult
    func publish(_ repo: String, tag: String, assets: [String: Package]) -> GitHubRelease {
        let release = GitHubRelease(
            id: 1, tagName: tag,
            assets: assets.keys.sorted().map { name in
                GitHubAsset(
                    name: name,
                    apiURL: URL(string: "https://api.example.com/\(repo)/\(tag)/\(name)")!,
                    downloadURL: URL(string: "https://example.com/\(repo)/\(tag)/\(name)")!
                )
            },
            prerelease: false, draft: false, createdAt: "2026-01-01T00:00:00Z", publishedAt: nil
        )
        lock.withLock {
            releases["\(repo)@\(tag)"] = release
            for asset in release.assets {
                served[asset.downloadURL] = assets[asset.name]
                served[asset.apiURL] = assets[asset.name]
            }
        }
        return release
    }

    /// What GitHub says `repo`'s newest release is, whatever the query's filters.
    func setLatest(_ repo: String, _ tag: String) {
        lock.withLock { latest[repo] = tag }
    }

    // MARK: - The Mac

    /// The fake's wall clock, for the `latestTags` fact's refresh and retry.
    var wallClock: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }

    /// The saved `.latest` tags.
    var savedLatestTags: [LatestTagQuery: LatestTagEntry] { lock.withLock { latestCache } }

    /// How many times GitHub was asked for `repo`'s newest release.
    func latestChecks(_ repo: String) -> Int {
        calls.filter { $0 == .latestTag(repo) }.count
    }

    var receiptIDs: Set<String> { lock.withLock { Set(receiptsOnMac.keys) } }
    var filesOnMac: Set<String> { lock.withLock { files } }
    var directoriesOnMac: Set<String> { lock.withLock { directories } }
    func markerOnMac(_ key: String) -> PkgMarker? { lock.withLock { markersOnMac[key] } }

    /// A receipt installed without Astrolabe, with its files and directories.
    func preinstall(_ id: String, _ paths: ReceiptPaths) {
        lock.withLock {
            receiptsOnMac[id] = paths
            stamp(id)
            files.formUnion(paths.files)
            directories.formUnion(paths.directories)
        }
    }

    /// A marker written by an earlier launch.
    func setMarker(_ marker: PkgMarker) {
        lock.withLock { markersOnMac[marker.key] = marker }
    }

    /// `pkgutil --forget` run by hand: the files stay.
    func forgetByHand(_ id: String) {
        _ = lock.withLock { receiptsOnMac.removeValue(forKey: id) }
    }

    /// Every work directory made so far.
    var workDirectories: [URL] { lock.withLock { _workDirectories } }

    // MARK: - Inspection

    var calls: [Call] { lock.withLock { _calls } }

    var installs: Int { calls.filter { if case .install = $0 { true } else { false } }.count }

    /// Every call that changed the Mac: installs, deletions, forgets, boot-outs and markers.
    var changes: [Call] {
        calls.filter {
            switch $0 {
            case .release, .download, .componentIdentifiers, .checkSignature, .receiptPaths, .latestTag: false
            default: true
            }
        }
    }

    // MARK: - Control

    func fail(_ step: Step, times: Int = 1) { lock.withLock { failures[step, default: 0] += times } }
    func hold(_ step: Step) { _ = lock.withLock { held.insert(step) } }
    func release(_ step: Step) { _ = lock.withLock { held.remove(step) } }

    // MARK: - PkgSystem

    func receipts() throws -> Set<String> {
        try failIfAsked(.receipts)
        return receiptIDs
    }

    func receiptStamps() throws -> [String: Date] {
        try failIfAsked(.receipts)
        return lock.withLock { stamps.filter { receiptsOnMac[$0.key] != nil } }
    }

    func receiptPaths(_ id: String) async throws -> ReceiptPaths {
        record(.receiptPaths(id))
        guard let paths = lock.withLock({ receiptsOnMac[id] }) else { throw FakeError() }
        return paths
    }

    func forget(_ id: String) async throws {
        record(.forget(id))
        try await wait(.forget)
        try failIfAsked(.forget)
        _ = lock.withLock { receiptsOnMac.removeValue(forKey: id) }
    }

    func componentIdentifiers(of pkg: URL) async throws -> [String] {
        record(.componentIdentifiers)
        return try package(at: pkg).identifiers
    }

    func checkSignature(_ pkg: URL) async throws {
        record(.checkSignature)
        guard try package(at: pkg).signed else { throw PkgError.untrusted(output: "Status: no signature") }
    }

    func install(_ pkg: URL, allowUntrusted: Bool) async throws {
        record(.install(allowUntrusted: allowUntrusted))
        let package = try package(at: pkg)
        try await wait(.install)
        try failIfAsked(.install)
        lock.withLock {
            for (id, paths) in package.installs {
                receiptsOnMac[id] = paths
                stamp(id)
                files.formUnion(paths.files)
                directories.formUnion(paths.directories)
            }
        }
        try failIfAsked(.afterInstall)
    }

    func deleteFile(_ path: String) throws {
        record(.deleteFile(path))
        _ = lock.withLock { files.remove(path) }
    }

    func removeDirectoryIfEmpty(_ path: String) throws {
        record(.removeDirectory(path))
        lock.withLock {
            let inside = files.union(directories).contains { $0.hasPrefix(path + "/") }
            if !inside { directories.remove(path) }
        }
    }

    func bootout(plist path: String, agent: Bool) async {
        record(.bootout(path, agent: agent))
    }

    func marker(_ key: String) throws -> PkgMarker? {
        markerOnMac(key)
    }

    func markers() throws -> [PkgMarker] {
        lock.withLock { markersOnMac.values.sorted { $0.key < $1.key } }
    }

    func writeMarker(_ marker: PkgMarker) throws {
        record(.writeMarker(marker.key, hash: marker.hash, receipts: marker.receipts))
        lock.withLock { markersOnMac[marker.key] = marker }
    }

    func deleteMarker(_ key: String) throws {
        record(.deleteMarker(key))
        _ = lock.withLock { markersOnMac.removeValue(forKey: key) }
    }

    func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astrolabe-pkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        lock.withLock { _workDirectories.append(url) }
        return url
    }

    func removeWorkDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    func release(_ repo: String, tag: String, token: String?) async throws -> GitHubRelease {
        record(.release(repo, tag: tag, token: token))
        guard let release = lock.withLock({ releases["\(repo)@\(tag)"] }) else {
            throw GitHubReleasesError.requestFailed(repo: repo, status: 404)
        }
        return release
    }

    func download(_ request: URLRequest, to destination: URL) async throws {
        let url = request.url!
        record(.download(url))
        try await wait(.download)
        try failIfAsked(.download)
        guard lock.withLock({ served[url] }) != nil else { throw PkgError.downloadFailed(url: url.absoluteString, status: 404) }
        try Data(url.absoluteString.utf8).write(to: destination)
    }

    func latestTag(_ query: LatestTagQuery) async throws -> String {
        record(.latestTag(query.repo))
        try await wait(.latestTag)
        try failIfAsked(.latestTag)
        guard let tag = lock.withLock({ latest[query.repo] }) else {
            throw GitHubReleasesError.noMatchingRelease(repo: query.repo)
        }
        return tag
    }

    func latestTagCache() throws -> [LatestTagQuery: LatestTagEntry] {
        savedLatestTags
    }

    func writeLatestTagCache(_ cache: [LatestTagQuery: LatestTagEntry]) throws {
        lock.withLock { latestCache = cache }
    }

    func now() -> Date { wallClock }

    // MARK: - Private

    /// The package a download wrote to `pkg`.
    private func package(at pkg: URL) throws -> Package {
        let text = try String(contentsOf: pkg, encoding: .utf8)
        guard let url = URL(string: text), let package = lock.withLock({ served[url] }) else { throw FakeError() }
        return package
    }

    /// Call holding `lock`: a new date for `id`'s database file.
    private func stamp(_ id: String) {
        stampClock += 1
        stamps[id] = stampClock
    }

    private func record(_ call: Call) {
        lock.withLock { _calls.append(call) }
    }

    private func wait(_ step: Step) async throws {
        while lock.withLock({ held.contains(step) }) {
            try Task.checkCancellation()
            await realSleep(.milliseconds(1))
        }
        try Task.checkCancellation()
    }

    private func failIfAsked(_ step: Step) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard let remaining = failures[step], remaining > 0 else { return false }
            failures[step] = remaining - 1
            return true
        }
        if shouldFail { throw FakeError() }
    }
}

/// Runs `body` with a fresh `PkgContext` over `fake`: what one launch of the daemon shares.
/// Tasks created inside inherit it.
@MainActor @discardableResult
func withPkg<T>(
    _ fake: FakePkgSystem,
    _ body: (PkgContext) async throws -> T
) async throws -> T {
    let context = PkgContext(system: fake)
    return try await PkgContext.$current.withValue(context) {
        try await body(context)
    }
}
