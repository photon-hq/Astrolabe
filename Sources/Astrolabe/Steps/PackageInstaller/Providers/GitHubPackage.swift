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

    public let repo: String
    public let version: Version

    public init(repo: String, version: Version = .latest) {
        self.repo = repo
        self.version = version
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

        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }) else {
            throw GitHubError.noPkgAsset(repo: repo, tag: release.tagName)
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
        process.arguments = ["-pkg", pkgPath.path, "-target", "/"]

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

        if let token = EnvironmentValues.current.gitHubToken {
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
    case noPkgAsset(repo: String, tag: String)
    case installFailed(package: String, output: String)
}

// MARK: - Dot Syntax

extension PackageProvider where Self == GitHubPackage {
    /// A package from a GitHub release.
    ///
    /// - Parameters:
    ///   - repo: Repository in `"owner/repo"` format.
    ///   - version: Which release to fetch. Defaults to `.latest`.
    public static func gitHub(_ repo: String, version: GitHubPackage.Version = .latest) -> GitHubPackage {
        GitHubPackage(repo: repo, version: version)
    }
}
