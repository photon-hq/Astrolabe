import Darwin
import Foundation

/// Everything `Pkg` does on the Mac. Tests bind a fake through `PkgContext`, so they never run
/// `installer` or delete anything.
protocol PkgSystem: Sendable {
    // MARK: Receipts

    /// Every receipt id on the Mac, from the receipt databases' file names. No subprocess, so
    /// the fact can read it every minute. Throws when a database can't be read.
    func receipts() throws -> Set<String>

    /// The absolute paths `id`'s receipt lists: its files and its directories, joined to the
    /// volume and install location it was installed to.
    func receiptPaths(_ id: String) async throws -> ReceiptPaths

    /// `pkgutil --forget`.
    func forget(_ id: String) async throws

    // MARK: Packages

    /// The receipt ids the `.pkg` would write: the `identifier` of every `PackageInfo` in it,
    /// a component package's own or each of a distribution's. Expands it next to itself.
    func componentIdentifiers(of pkg: URL) async throws -> [String]

    /// `pkgutil --check-signature`. Throws `PkgError.untrusted` when it isn't signed by a
    /// trusted identity.
    func checkSignature(_ pkg: URL) async throws

    /// `installer -pkg … -target /`, streamed to the log. Throws `PkgError.installFailed`.
    func install(_ pkg: URL, allowUntrusted: Bool) async throws

    // MARK: Files

    /// Removes a file or a link. Missing is fine. Never a directory: one there now is left alone.
    func deleteFile(_ path: String) throws

    /// Removes the directory when it's empty. Missing, not empty, or not a directory: left alone.
    func removeDirectoryIfEmpty(_ path: String) throws

    /// Boots out the job the plist at `path` defines, by its `Label`: from the system domain, or
    /// with `agent`, from every logged-in user's. Errors are ignored: it may not be loaded.
    func bootout(plist path: String, agent: Bool) async

    // MARK: Markers

    /// The marker of the package keyed `key`, or `nil` when there's none.
    func marker(_ key: String) throws -> PkgMarker?

    /// Every marker on the Mac. One that can't be decoded is skipped, with a log.
    func markers() throws -> [PkgMarker]

    func writeMarker(_ marker: PkgMarker) throws

    /// Missing is fine.
    func deleteMarker(_ key: String) throws

    // MARK: Downloads

    /// A new empty directory, root's alone, to download and expand into.
    func makeWorkDirectory() throws -> URL

    /// Removes it and everything in it. Never throws: it runs in a `defer`.
    func removeWorkDirectory(_ directory: URL)

    /// The release of `repo` tagged `tag`.
    func release(_ repo: String, tag: String, token: String?) async throws -> GitHubRelease

    /// Downloads `request` to `destination`. Throws `PkgError.downloadFailed` on a status other
    /// than 200.
    func download(_ request: URLRequest, to destination: URL) async throws

    // MARK: Latest tags

    /// `GitHubReleases.latestTag` for `query`.
    func latestTag(_ query: LatestTagQuery) async throws -> String

    /// Every `.latest` tag checked so far, from disk. Throws when the file can't be decoded:
    /// reading it as empty would uninstall every `.latest` package.
    func latestTagCache() throws -> [LatestTagQuery: LatestTagEntry]

    func writeLatestTagCache(_ cache: [LatestTagQuery: LatestTagEntry]) throws

    func now() -> Date
}

/// One `.latest`: the repo, its token, and the filters, the asset `Pkg` installs among them.
struct LatestTagQuery: Codable, Sendable, Hashable {
    let repo: String
    let token: GitHubToken?
    let options: GitHubReleases.Options
}

/// A `.latest`'s tag, and when GitHub last said so.
struct LatestTagEntry: Codable, Sendable, Equatable {
    let tag: String
    let checkedAt: Date
}

/// The paths one receipt lists, absolute.
struct ReceiptPaths: Equatable, Sendable {
    var files: [String] = []
    var directories: [String] = []
}

/// What Astrolabe installed for one `Pkg`: written by its rollout, read by its removal and the
/// `installed` fact. At `<Persistence.directory>/pkg/<percent-encoded key>.json`.
struct PkgMarker: Codable, Equatable, Sendable {
    /// `PkgSource.key`.
    let key: String
    /// `PkgInstall.compute` of what was installed. Empty while an upgrade's cleanup is unfinished.
    let hash: String
    /// Sorted. Empty for a package that writes no receipt.
    let receipts: [String]
    let installedAt: Date
}

/// The real `PkgSystem`: `pkgutil`, `installer`, and the receipt databases.
struct InstallerPkgSystem: PkgSystem {
    static let pkgutil = "/usr/sbin/pkgutil"
    static let installer = "/usr/sbin/installer"
    /// A receipt list for a large package runs to megabytes.
    static let listingLimit = 64 * 1024 * 1024
    /// Downloads run under `PkgContext.lock`: a stalled one must not hold it for days.
    static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    let markerDirectory: URL
    /// Beside the markers' directory, not in it: `markers()` reads every `.json` there.
    let latestTagsURL: URL
    /// Where `installer` writes receipts, and where macOS keeps its own.
    let receiptDirectories: [String]
    let workRoot: String

    init(
        markerDirectory: URL = Persistence.directory.appendingPathComponent("pkg"),
        receiptDirectories: [String] = ["/var/db/receipts", "/System/Library/Receipts"],
        workRoot: String = "/private/var/tmp"
    ) {
        self.markerDirectory = markerDirectory
        latestTagsURL = markerDirectory.deletingLastPathComponent().appendingPathComponent("pkg-latest-tags.json")
        self.receiptDirectories = receiptDirectories
        self.workRoot = workRoot
    }

    // MARK: Receipts

    func receipts() throws -> Set<String> {
        var ids: Set<String> = []
        for directory in receiptDirectories {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            }
            for name in names where name.hasSuffix(".plist") {
                ids.insert(String(name.dropLast(".plist".count)))
            }
        }
        return ids
    }

    func receiptPaths(_ id: String) async throws -> ReceiptPaths {
        let info = try await ProcessRunner.run(Self.pkgutil, arguments: ["--pkg-info-plist", id], timeout: ProcessRunner.Timeout.probe)
        guard let plist = try PropertyListSerialization.propertyList(from: Data(info.standardOutput.utf8), format: nil) as? [String: Any] else {
            throw PkgError.unreadableReceipt(id)
        }
        let base = Self.join([plist["volume"] as? String ?? "/", plist["install-location"] as? String ?? ""]) ?? "/"
        func list(_ only: String) async throws -> [String] {
            let result = try await ProcessRunner.run(
                Self.pkgutil, arguments: [only, "--files", id], timeout: ProcessRunner.Timeout.probe, limit: Self.listingLimit
            )
            return result.standardOutput.split(whereSeparator: \.isNewline).compactMap { Self.join([base, String($0)]) }
        }
        return ReceiptPaths(files: try await list("--only-files"), directories: try await list("--only-dirs"))
    }

    func forget(_ id: String) async throws {
        print("[Astrolabe] pkgutil --forget \(id)")
        try await ProcessRunner.run(Self.pkgutil, arguments: ["--forget", id])
    }

    // MARK: Packages

    func componentIdentifiers(of pkg: URL) async throws -> [String] {
        let expanded = pkg.deletingLastPathComponent().appendingPathComponent("expanded")
        try await ProcessRunner.run(Self.pkgutil, arguments: ["--expand", pkg.path, expanded.path], timeout: .seconds(600))
        var infos = [expanded.appendingPathComponent("PackageInfo")]
        for name in try FileManager.default.contentsOfDirectory(atPath: expanded.path).sorted() where name.hasSuffix(".pkg") {
            infos.append(expanded.appendingPathComponent(name).appendingPathComponent("PackageInfo"))
        }
        var identifiers: [String] = []
        for info in infos {
            guard let data = FileManager.default.contents(atPath: info.path) else { continue }
            if let identifier = PackageInfo.identifier(in: data), !identifiers.contains(identifier) {
                identifiers.append(identifier)
            }
        }
        return identifiers
    }

    func checkSignature(_ pkg: URL) async throws {
        let result = try await ProcessRunner.capture(Self.pkgutil, arguments: ["--check-signature", pkg.path])
        guard result.isSuccess, !result.standardOutput.contains("no signature") else {
            throw PkgError.untrusted(output: result.combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func install(_ pkg: URL, allowUntrusted: Bool) async throws {
        var arguments = ["-pkg", pkg.path, "-target", "/"]
        if allowUntrusted { arguments.insert("-allowUntrusted", at: 0) }
        do {
            // Streamed: `installer` runs the package's own scripts, which can be arbitrarily chatty.
            try await ProcessRunner.stream(Self.installer, arguments: arguments, timeout: ProcessRunner.Timeout.install) { line in
                print("[Astrolabe] installer: \(line)")
            }
        } catch ReconcileError.processFailed(_, _, let output) {
            throw PkgError.installFailed(output: output)
        }
    }

    // MARK: Files

    func deleteFile(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT != S_IFDIR else { return }
        guard unlink(path) == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func removeDirectoryIfEmpty(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // A link in place of the directory is left, and so is what it points at.
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        guard rmdir(path) == 0 else {
            if [ENOTEMPTY, EEXIST, ENOENT, EBUSY].contains(errno) { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func bootout(plist path: String, agent: Bool) async {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String
        else {
            print("[Astrolabe] no Label in \(path): nothing booted out")
            return
        }
        print("[Astrolabe] booting out \(label)")
        if agent {
            for user in await LaunchctlHelper.activeGUIUsers() {
                await LaunchctlHelper.bootout(domain: "gui/\(user.uid)", label: label)
            }
        } else {
            await LaunchctlHelper.bootout(domain: "system", label: label)
        }
    }

    // MARK: Markers

    func marker(_ key: String) throws -> PkgMarker? {
        guard let data = FileManager.default.contents(atPath: markerURL(key).path) else { return nil }
        return try Self.decoder.decode(PkgMarker.self, from: data)
    }

    func markers() throws -> [PkgMarker] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: markerDirectory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = FileManager.default.contents(atPath: markerDirectory.appendingPathComponent(name).path) else { return nil }
            do {
                return try Self.decoder.decode(PkgMarker.self, from: data)
            } catch {
                print("[Astrolabe] skipping unreadable pkg marker \(name): \(error)")
                return nil
            }
        }
    }

    func writeMarker(_ marker: PkgMarker) throws {
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        try Self.encoder.encode(marker).write(to: markerURL(marker.key), options: .atomic)
    }

    func deleteMarker(_ key: String) throws {
        do {
            try FileManager.default.removeItem(at: markerURL(key))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    // MARK: Downloads

    func makeWorkDirectory() throws -> URL {
        let path = "\(workRoot)/astrolabe-pkg-\(UUID().uuidString)"
        guard mkdir(path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func removeWorkDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    func release(_ repo: String, tag: String, token: String?) async throws -> GitHubRelease {
        try await GitHubReleases.fetchByTag(repo: repo, tag: tag, token: token)
    }

    func download(_ request: URLRequest, to destination: URL) async throws {
        let (file, response) = try await Self.downloadSession.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw PkgError.downloadFailed(url: request.url?.absoluteString ?? "", status: status)
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    // MARK: Latest tags

    func latestTag(_ query: LatestTagQuery) async throws -> String {
        let options = query.options
        return try await GitHubReleases.latestTag(
            query.repo, token: query.token, prereleases: options.prereleases, tag: options.tag,
            asset: options.asset, order: options.order
        )
    }

    /// Stored as a list: a dictionary with struct keys has no JSON object form.
    private struct CachedTag: Codable {
        let query: LatestTagQuery
        let entry: LatestTagEntry
    }

    func latestTagCache() throws -> [LatestTagQuery: LatestTagEntry] {
        guard let data = FileManager.default.contents(atPath: latestTagsURL.path) else { return [:] }
        let cached = try Self.decoder.decode([CachedTag].self, from: data)
        return Dictionary(cached.map { ($0.query, $0.entry) }, uniquingKeysWith: { _, last in last })
    }

    func writeLatestTagCache(_ cache: [LatestTagQuery: LatestTagEntry]) throws {
        let cached = cache.map { CachedTag(query: $0.key, entry: $0.value) }.sorted { $0.query.repo < $1.query.repo }
        try FileManager.default.createDirectory(at: latestTagsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(cached).write(to: latestTagsURL, options: .atomic)
    }

    func now() -> Date { Date() }

    // MARK: - Private

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func markerURL(_ key: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return markerDirectory.appendingPathComponent("\(name).json")
    }

    /// `["/", "usr/local", "./bin/tool"]` → `/usr/local/bin/tool`. `nil` for a path through `..`.
    /// Never `standardizingPath`: it rewrites `/private/var` to `/var`.
    static func join(_ parts: [String]) -> String? {
        var components: [Substring] = []
        for part in parts {
            for component in part.split(separator: "/") where component != "." {
                guard component != ".." else { return nil }
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}

/// Reads the `identifier` off a `PackageInfo`'s `<pkg-info>` root.
final class PackageInfo: NSObject, XMLParserDelegate {
    private var identifier: String?

    static func identifier(in data: Data) -> String? {
        let delegate = PackageInfo()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.identifier
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if elementName == "pkg-info", let identifier = attributes["identifier"], !identifier.isEmpty {
            self.identifier = identifier
        }
        parser.abortParsing()
    }
}
