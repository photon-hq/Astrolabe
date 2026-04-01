/// Groups multiple declarations together.
///
/// Transparent — the group's body IS its content. Useful for applying
/// modifiers to a set of declarations.
///
/// ```swift
/// Group {
///     Pkg(.gitHub("private/repo1"))
///     Pkg(.gitHub("private/repo2"))
/// }
/// .environment(\.gitHubToken, "ghp_xxx")
/// ```
public struct Group<Content: Setup>: Setup {
    public typealias Body = Content

    public let content: Content

    public init(@SetupBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Content { content }
}
