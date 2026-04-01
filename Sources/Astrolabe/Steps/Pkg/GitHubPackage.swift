import Foundation

/// Installs a `.pkg` from a GitHub release.
///
/// ```swift
/// PackageInstaller(.gitHub("owner/repo"))
/// PackageInstaller(.gitHub("owner/repo", version: .tag("v1.0.0")))
/// ```
public struct GitHubPackage: PackageProvider {
    public enum Version: Sendable, Equatable {
        case latest
        case tag(String)
    }

    /// How to match an asset filename in the release.
    public enum AssetFilter: Sendable {
        /// Matches the first asset ending in `.pkg`.
        case pkg
        /// Matches an exact filename.
        case filename(String)
        /// Matches filenames against a regex pattern.
        case regex(String)
    }

    public let repo: String
    public let version: Version
    public let asset: AssetFilter

    public init(repo: String, version: Version = .latest, asset: AssetFilter = .pkg) {
        self.repo = repo
        self.version = version
        self.asset = asset
    }

    public func install() async throws {
        print("[Astrolabe] Fetching release for \(repo)...")

        let request = makeReleaseRequest()
        let (releaseData, releaseResponse) = try await URLSession.shared.data(for: request)

        guard let httpResponse = releaseResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.releaseNotFound(repo: repo, version: version)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)

        guard let asset = findAsset(in: release.assets) else {
            throw GitHubError.noMatchingAsset(repo: repo, tag: release.tagName, filter: asset)
        }

        print("[Astrolabe] Downloading \(asset.name)...")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrolabe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pkgPath = tempDir.appendingPathComponent(asset.name)
        let (downloadURL, _) = try await URLSession.shared.download(from: asset.downloadURL)
        try FileManager.default.moveItem(at: downloadURL, to: pkgPath)

        print("[Astrolabe] Installing \(asset.name)...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        var arguments = ["-pkg", pkgPath.path, "-target", "/"]
        if EnvironmentValues.current.allowUntrusted {
            arguments.insert("-allowUntrusted", at: 0)
        }
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GitHubError.installFailed(package: asset.name, output: output)
        }

        print("[Astrolabe] Installed \(asset.name) successfully.")
    }

    private func findAsset(in assets: [GitHubAsset]) -> GitHubAsset? {
        switch asset {
        case .pkg:
            return assets.first { $0.name.hasSuffix(".pkg") }
        case .filename(let name):
            return assets.first { $0.name == name }
        case .regex(let pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return assets.first { asset in
                let range = NSRange(asset.name.startIndex..., in: asset.name)
                return regex.firstMatch(in: asset.name, range: range) != nil
            }
        }
    }

    private func makeReleaseRequest() -> URLRequest {
        let base = "https://api.github.com/repos/\(repo)/releases"
        let url: URL = switch version {
        case .latest:
            URL(string: "\(base)/latest")!
        case .tag(let tag):
            URL(string: "\(base)/tags/\(tag)")!
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        if let token = EnvironmentValues.current.githubToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }
}

// MARK: - GitHub API Models

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct GitHubAsset: Decodable, Sendable {
    let name: String
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

// MARK: - Errors

public enum GitHubError: Error, Sendable {
    case releaseNotFound(repo: String, version: GitHubPackage.Version)
    case noMatchingAsset(repo: String, tag: String, filter: GitHubPackage.AssetFilter)
    case installFailed(package: String, output: String)
}

// MARK: - Dot Syntax

extension PackageProvider where Self == GitHubPackage {
    /// A package from a GitHub release.
    public static func gitHub(
        _ repo: String,
        version: GitHubPackage.Version = .latest,
        asset: GitHubPackage.AssetFilter = .pkg
    ) -> GitHubPackage {
        GitHubPackage(repo: repo, version: version, asset: asset)
    }
}

