/// Groups multiple steps together.
///
/// Useful for applying modifiers to a set of steps:
///
/// ```swift
/// Group {
///     PackageInstaller(.gitHub("private/repo1"))
///     PackageInstaller(.gitHub("private/repo2"))
/// }
/// .environment(\.gitHubToken, "ghp_xxx")
/// ```
public struct Group<Content: Setup>: Setup {
    public let content: Content

    public init(@SetupBuilder content: () -> Content) {
        self.content = content()
    }

    public func execute() async throws {
        try await content.execute()
    }
}
