import CryptoKit
import Foundation

/// Sets the desktop wallpaper to a static image for the logged-in GUI user(s).
///
/// ```swift
/// Sys(.wallpaper("/Users/Shared/Standard.heic"))
/// Sys(.wallpaper("/Users/Shared/Standard.heic", scaling: .fit))
/// ```
///
/// The wallpaper is a per-GUI-user setting that must be applied inside the user's session,
/// so `check()`/`apply()` re-exec the Astrolabe binary as the user via
/// `LaunchctlHelper.runAsUser` (see `WallpaperHelper`). The declared image is *content-addressed*
/// — staged to `Wallpapers/<sha256>.<ext>` and set from there — so a path comparison is exactly
/// a content comparison and macOS always refreshes when the image bytes change.
public struct WallpaperSetting: SystemSetting {
    /// How the image fills each display. Maps to `NSWorkspace` desktop-image options.
    public enum Scaling: String, Sendable {
        case fill, fit, stretch, center
    }

    /// The source image the operator declared.
    public let path: String
    public let scaling: Scaling

    public init(_ path: String, scaling: Scaling = .fill) {
        self.path = path
        self.scaling = scaling
    }

    public func check() async throws -> Bool {
        let users = LaunchctlHelper.activeGUIUsers()
        guard !users.isEmpty else { return true }                 // nothing to verify
        // Can't read the source → not in the desired state; apply() will surface a clear error.
        guard let staged = try? Self.stagedPath(forSource: path) else { return false }
        let want = (staged as NSString).standardizingPath
        return users.allSatisfy { user in
            let result = LaunchctlHelper.runAsUser(
                uid: user.uid, executable: Self.selfPath, arguments: ["__wallpaper", "get"])
            guard result.terminationStatus == 0 else { return false }
            return (result.output as NSString).standardizingPath == want
        }
    }

    public func apply() async throws {
        let staged = try Self.stageImage(fromSource: path)
        let users = LaunchctlHelper.activeGUIUsers()
        guard !users.isEmpty else { return }
        let arguments = ["__wallpaper", "set", staged, scaling.rawValue]
        for user in users {
            let result = LaunchctlHelper.runAsUser(
                uid: user.uid, executable: Self.selfPath, arguments: arguments)
            guard result.terminationStatus == 0 else {
                throw ReconcileError.processFailed(
                    path: Self.selfPath, arguments: arguments, output: result.output)
            }
        }
    }

    // MARK: - Content-addressed staging

    static let stagingDirectory = "/Library/Application Support/Astrolabe/Wallpapers"

    /// Path to this running binary, re-exec'd as the user to reach NSWorkspace.
    private static var selfPath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "/usr/local/bin/astrolabe"
    }

    /// The content-addressed staged path for `source`, without copying. Throws if unreadable.
    static func stagedPath(forSource source: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        return stagedPath(forContent: data, sourceExtension: (source as NSString).pathExtension)
    }

    static func stagedPath(forContent data: Data, sourceExtension ext: String) -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = ext.isEmpty ? hash : "\(hash).\(ext.lowercased())"
        return "\(stagingDirectory)/\(name)"
    }

    /// Copies `source` to its content-addressed staged path (world-readable) and returns it.
    @discardableResult
    static func stageImage(fromSource source: String) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: source))
        } catch {
            throw ReconcileError.processFailed(
                path: "wallpaper", arguments: [source],
                output: "cannot read image at \(source): \(error.localizedDescription)")
        }
        let staged = stagedPath(forContent: data, sourceExtension: (source as NSString).pathExtension)

        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: stagingDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        if !fm.fileExists(atPath: staged) {
            guard fm.createFile(atPath: staged, contents: data, attributes: [.posixPermissions: 0o644]) else {
                throw ReconcileError.processFailed(
                    path: "wallpaper", arguments: [staged], output: "failed to stage image to \(staged)")
            }
        } else {
            // A prior run may have created it with different perms — keep it user-readable.
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged)
        }
        return staged
    }

    /// Cheap identity token (size + mtime) so re-versioning the source image re-converges via
    /// the tree diff — without hashing the (potentially large) image on every synchronous tick.
    static func contentToken(for source: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source)
        let size = (attrs?[.size] as? Int) ?? -1
        let mtime = (attrs?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? -1
        return "\(size):\(mtime)"
    }
}

extension SystemSetting where Self == WallpaperSetting {
    /// Sets the desktop wallpaper to a static image for the logged-in GUI user(s).
    public static func wallpaper(_ path: String,
                                 scaling: WallpaperSetting.Scaling = .fill) -> WallpaperSetting {
        WallpaperSetting(path, scaling: scaling)
    }
}
