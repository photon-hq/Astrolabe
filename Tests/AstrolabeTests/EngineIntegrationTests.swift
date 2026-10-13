import Foundation
import Observation
import Testing
@testable import Astrolabe

/// A real file, like the staging example's, under a test's temporary directory.
private struct TempFile: Resource, Equatable {
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

@Observable @MainActor
private final class FileState {
    var directory = ""
    var files: [String: String] = [:]
}

private struct FileApp: Astrolabe {
    let state = FileState()

    var body: some Component {
        for (name, contents) in state.files.sorted(by: { $0.key < $1.key }) {
            TempFile(path: "\(state.directory)/\(name)", contents: contents)
        }
    }

    static var resourceTypes: [any Resource.Type] { [TempFile.self] }
}

private func read(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// The daemon's configuration: a continuous clock and real files.
@MainActor
@Test func engineOnTheContinuousClockConvergesRealFiles() async throws {
    let directory = try TemporaryDirectory()
    let files = directory.url.appendingPathComponent("files").path
    try FileManager.default.createDirectory(atPath: files, withIntermediateDirectories: true)

    let app = FileApp()
    app.state.directory = files
    let engine = Engine(app: app, store: RecordStore(url: directory.recordsURL), clock: ContinuousClock())
    let run = Task { await engine.run() }

    app.state.files = ["a.txt": "1", "b.txt": "2"]
    await eventually("both files written") { read("\(files)/a.txt") == "1" && read("\(files)/b.txt") == "2" }

    app.state.files = ["a.txt": "3"]
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
