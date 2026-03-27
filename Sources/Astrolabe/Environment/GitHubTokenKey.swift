/// Environment key for a GitHub personal access token.
public struct GitHubTokenKey: EnvironmentKey {
    public static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// A GitHub token for authenticating API requests to private repositories.
    public var gitHubToken: String? {
        get { self[GitHubTokenKey.self] }
        set { self[GitHubTokenKey.self] = newValue }
    }
}
