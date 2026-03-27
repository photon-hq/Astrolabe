/// A setup step that injects an environment value before executing its content.
public struct ModifiedSetup<Content: Setup, Value: Sendable>: Setup, @unchecked Sendable {
    public let content: Content
    public let keyPath: WritableKeyPath<EnvironmentValues, Value>
    public let value: Value

    public func execute() async throws {
        var env = EnvironmentValues.current
        env[keyPath: keyPath] = value
        try await EnvironmentValues.$current.withValue(env) {
            try await content.execute()
        }
    }
}

extension Setup {
    /// Sets an environment value for this step and all its children.
    ///
    /// ```swift
    /// Group {
    ///     PackageInstaller(.gitHub("private/repo"))
    /// }
    /// .environment(\.gitHubToken, "ghp_xxx")
    /// ```
    public func environment<V: Sendable>(
        _ keyPath: WritableKeyPath<EnvironmentValues, V>,
        _ value: V
    ) -> ModifiedSetup<Self, V> {
        ModifiedSetup(content: self, keyPath: keyPath, value: value)
    }
}
