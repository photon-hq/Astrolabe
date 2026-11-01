import Astrolabe
import Foundation

/// A file with fixed contents. Staging only: not part of the library.
@Resource
struct StagingFile {
    static let kind = "staging.file"
    let path: String
    let contents: String
    var id: String { "file:\(path)" }                                   // which file

    static func compute(_ f: StagingFile) -> String {
        Hash.of("staging.file", f.path, f.contents)                     // how it should look
    }

    @concurrent static func rollout(_ f: StagingFile) async throws {
        if (try? String(contentsOfFile: f.path, encoding: .utf8)) == f.contents { return }  // check the Mac first
        try await Task.sleep(for: .seconds(10))      // staging only: a window to change state mid-rollout
        try Task.checkCancellation()
        if f.contents.hasPrefix("FAIL") { throw StagingError.failRequested(f.path) }
        try f.contents.write(toFile: f.path, atomically: true, encoding: .utf8)
    }

    @concurrent static func remove(_ f: StagingFile) async throws {
        guard FileManager.default.fileExists(atPath: f.path) else { return }               // no-op if absent
        try FileManager.default.removeItem(atPath: f.path)
    }

    static var retryPolicy: RetryPolicy { .rollback() }
}

enum StagingError: Error {
    /// The declared contents start with `FAIL`.
    case failRequested(String)
}
