import Foundation
import Testing
@testable import Astrolabe

/// A real file, like the staging example's, under a test's temporary directory.
@Resource
private struct TempFile: Equatable {
    static let kind = "test.file"
    let path: String
    let contents: String
    var id: String { "file:\(path)" }

    static func compute(_ f: TempFile) -> String {
        Hash.of(kind, f.path, f.contents)
    }

    @concurrent static func rollout(_ f: TempFile) async throws {
        if (try? String(contentsOfFile: f.path, encoding: .utf8)) == f.contents { return }
        try f.contents.write(toFile: f.path, atomically: true, encoding: .utf8)
    }

    @concurrent static func remove(_ f: TempFile) async throws {
        guard FileManager.default.fileExists(atPath: f.path) else { return }
        try FileManager.default.removeItem(atPath: f.path)
    }
}

/// The files `state.json` in a test's directory declares, under its `files` directory.
private struct TempFiles: Equatable, Sendable {
    var directory = ""
    var files: [String: String] = [:]
}

/// Like the staging example's fact: polls `state.json`, a map of file name to contents.
private struct TempFilesKey: FactKey {
    /// The test's directory. Fact loops start inside the engine's task, so they inherit it.
    @TaskLocal static var directory: String?

    static let defaultValue = TempFiles()
    static let schedule: FactSchedule = .every(.milliseconds(50))

    @concurrent static func read() async throws -> TempFiles {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/state.json"))
        return TempFiles(directory: "\(directory)/files", files: try JSONDecoder().decode([String: String].self, from: data))
    }
}

extension Facts {
    fileprivate var tempFiles: TempFiles { self[TempFilesKey.self] }
}

private struct FileApp: Astrolabe {
    @Fact(\.tempFiles) var state

    var body: some Component {
        for (name, contents) in state.files.sorted(by: { $0.key < $1.key }) {
            TempFile(path: "\(state.directory)/\(name)", contents: contents)
        }
    }
}

private func read(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

private func writeState(_ files: [String: String], in directory: URL) throws {
    let data = try JSONEncoder().encode(files)
    try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
}

/// The daemon's configuration: a continuous clock, a polled fact, and real files.
@MainActor
@Test func engineOnTheContinuousClockConvergesRealFiles() async throws {
    let directory = try TemporaryDirectory()
    let files = directory.url.appendingPathComponent("files").path
    try FileManager.default.createDirectory(atPath: files, withIntermediateDirectories: true)
    try writeState(["a.txt": "1", "b.txt": "2"], in: directory.url)

    let engine = Engine(
        app: FileApp(), resourceTypes: [TempFile.self], store: RecordStore(url: directory.recordsURL),
        clock: ContinuousClock()
    )
    let run = TempFilesKey.$directory.withValue(directory.url.path) {
        Task { await engine.run() }
    }

    await eventually("both files written") { read("\(files)/a.txt") == "1" && read("\(files)/b.txt") == "2" }

    try writeState(["a.txt": "3"], in: directory.url)
    await eventually("a rewritten, b removed") {
        read("\(files)/a.txt") == "3" && !FileManager.default.fileExists(atPath: "\(files)/b.txt")
    }
    await eventually("records settled") {
        let store = RecordStore(url: directory.recordsURL)
        _ = store.load()
        return Array(store.records.keys) == ["file:\(files)/a.txt"]
    }

    run.cancel()
    await run.value
}
