import Darwin
import Foundation

/// One entry in `records.json`: the last snapshot that was successfully rolled out for an id.
struct Record: Codable, Sendable, Equatable {
    let kind: String
    let hash: String
    let snapshot: JSONValue
}

/// `records.json`: `id → {kind, hash, snapshot}` for every successful rollout not since removed.
///
/// Written through on every success, from the main actor (single writer, no lock). Each write
/// replaces the whole file durably: temp file in the same directory, `F_FULLFSYNC`, `rename`,
/// then fsync the directory. A failed write is reported to the caller and naturally retried by
/// the next one, since every write carries the full contents; the in-memory copy stays
/// authoritative for the run.
///
/// Entries the engine can't decode are kept verbatim, so they survive every rewrite.
@MainActor
final class RecordStore {
    static let version = 1

    let url: URL
    private(set) var records: [String: Record] = [:]

    init(url: URL = Persistence.recordsURL) {
        self.url = url
    }

    enum LoadOutcome: Equatable {
        /// No file: every declared resource rolls out once, and nothing is removed.
        case missing
        case loaded
        /// The file was unreadable or of an unknown version, so the store starts empty.
        /// `movedTo` is where it went, or `nil` if it was left in place (dry run, or the move failed).
        case reset(reason: String, movedTo: URL?)
    }

    /// Reads the file into `records`.
    ///
    /// - Parameter moveAsideCorrupt: Move a corrupt or unknown-version file to
    ///   `records.json.corrupt-<timestamp>`. Off in dry run, which never writes.
    func load(moveAsideCorrupt: Bool = true) -> LoadOutcome {
        records = [:]
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            return reset("unreadable", moveAside: moveAsideCorrupt)
        }

        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            return reset("corrupt", moveAside: moveAsideCorrupt)
        }
        guard header.version == Self.version else {
            return reset("unknown_version", moveAside: moveAsideCorrupt)
        }
        guard let file = try? decoder.decode(File.self, from: data) else {
            return reset("corrupt", moveAside: moveAsideCorrupt)
        }
        records = file.records
        return .loaded
    }

    /// Records a success for `id` and rewrites the file.
    func set(_ id: String, _ record: Record) throws {
        records[id] = record
        try flush()
    }

    /// Forgets `id` and rewrites the file.
    func delete(_ id: String) throws {
        guard records.removeValue(forKey: id) != nil else { return }
        try flush()
    }

    // MARK: - Private

    private struct Header: Decodable {
        let version: Int
    }

    private struct File: Codable {
        let version: Int
        let records: [String: Record]
    }

    private func reset(_ reason: String, moveAside: Bool) -> LoadOutcome {
        guard moveAside else { return .reset(reason: reason, movedTo: nil) }
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
        let moved = rename(url.path, destination.path) == 0
        return .reset(reason: reason, movedTo: moved ? destination : nil)
    }

    private func flush() throws {
        let encoder = JSONEncoder()
        // Sorted and indented so `jq` and a human can read it on a host.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(version: Self.version, records: records))

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        try Self.writeDurably(data, to: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            let error = Self.posixError()
            unlink(temporary.path)
            throw error
        }
        // Make the rename itself durable. Best effort: the data is already on disk.
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 {
            fsync(directoryFD)
            close(directoryFD)
        }
    }

    /// Writes `data` to a new file at `path`, mode 0600, and flushes it to stable storage.
    /// `Data.write(options: .atomic)` alone doesn't fsync.
    private static func writeDurably(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        var written = false
        defer {
            close(fd)
            if !written { unlink(path) }
        }

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, base + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += count
            }
        }
        // F_FULLFSYNC also flushes the drive's own cache; fall back where it's unsupported.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw posixError()
        }
        written = true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
