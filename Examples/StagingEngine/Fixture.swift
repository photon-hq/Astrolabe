import Darwin
import Foundation
import Observation

/// The staging app's only state: which files should exist, and what they contain.
@Observable @MainActor
final class Fixture {
    /// File name → contents. Writers assign whole values, so equal reads don't wake the engine.
    var files: [String: String] = [:]

    /// A fixture kept in sync with a JSON file by polling it every second.
    static func watching(_ path: String) -> Fixture {
        let fixture = Fixture()
        Task {
            while !Task.isCancelled {
                // When a read fails, keep the last good value: not declaring a file removes it.
                if let files = StateFile.read(path) {
                    fixture.files = files
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return fixture
    }
}

/// `/tmp/astrolabe-staging/state.json`: `{"<name>": "<contents>", …}`.
///
/// The daemon runs as root, so it only trusts the directory and the file when they are real,
/// root-owned, and not writable by group or others, and it only accepts plain file names.
/// Otherwise anyone could make root write files anywhere.
enum StateFile {
    static let directory = "/tmp/astrolabe-staging"
    static let path = "\(directory)/state.json"

    static func read(_ path: String) -> [String: String]? {
        let directory = (path as NSString).deletingLastPathComponent
        guard isTrusted(directory, directory: true),
              isTrusted(path, directory: false),
              let data = FileManager.default.contents(atPath: path),
              let files = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return files.filter { isPlainFileName($0.key) && $0.key != (path as NSString).lastPathComponent }
    }

    private static func isTrusted(_ path: String, directory: Bool) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        return info.st_uid == 0
            && type == (directory ? S_IFDIR : S_IFREG)
            && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func isPlainFileName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !name.isEmpty
            && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}
