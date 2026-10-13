import Astrolabe
import Darwin
import Foundation

extension Facts {
    /// The staging app's only fact: which files should exist under `StateFile.directory`, and
    /// what they contain.
    @FactEntry(schedule: .every(.seconds(1)), read: {
        try StateFile.read(StateFile.path)                     // a throw means "couldn't read", never "nothing"
    })
    var stagingFiles: [String: String] = [:]                   // never acted on
}

/// `/tmp/astrolabe-staging/state.json`: `{"<name>": "<contents>", …}`.
///
/// The daemon runs as root, so it only trusts the directory and the file when they are real,
/// root-owned, and not writable by group or others, and it only accepts plain file names.
/// Otherwise anyone could make root write files anywhere.
enum StateFile {
    static let directory = "/tmp/astrolabe-staging"
    static let path = "\(directory)/state.json"

    enum ReadError: Error {
        /// The path doesn't exist, or can't be inspected.
        case missing(String)
        /// Not root-owned, not the expected type, or writable by group or others.
        case untrusted(String)
    }

    /// Throws when the file can't be read or trusted: the engine then keeps the last value, and
    /// before the first one acts on nothing. Never returns `[:]` for "couldn't read": not
    /// declaring a file removes it.
    static func read(_ path: String) throws -> [String: String] {
        try checkTrusted((path as NSString).deletingLastPathComponent, directory: true)
        try checkTrusted(path, directory: false)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let files = try JSONDecoder().decode([String: String].self, from: data)
        return files.filter { isPlainFileName($0.key) && $0.key != (path as NSString).lastPathComponent }
    }

    private static func checkTrusted(_ path: String, directory: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ReadError.missing(path) }
        let type = info.st_mode & S_IFMT
        guard info.st_uid == 0,
              type == (directory ? S_IFDIR : S_IFREG),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else { throw ReadError.untrusted(path) }
    }

    private static func isPlainFileName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !name.isEmpty
            && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}
