/// A setup step that installs a package from a provider.
///
/// ```swift
/// PackageInstaller(.gitHub("owner/repo", version: .latest))
/// PackageInstaller(.gitHub("owner/repo", version: .tag("v1.0.0")))
/// PackageInstaller(.jamf(name: "Google Chrome"))
/// PackageInstaller(.jamf(trigger: "installChrome"))
/// ```
public struct PackageInstaller<Provider: PackageProvider>: Setup {
    public let provider: Provider

    public init(_ provider: Provider) {
        self.provider = provider
    }

    public func execute() async throws {
        try await provider.install()
    }
}
