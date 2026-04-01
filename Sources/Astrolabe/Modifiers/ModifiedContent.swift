/// A `Setup` declaration with a modifier applied.
///
/// Like SwiftUI's `ModifiedContent` — wraps content and carries modifier metadata.
/// The tree walker extracts the modifier and recurses into the content.
public struct ModifiedContent<Content: Setup, Modifier: SetupModifier>: Setup {
    public typealias Body = Never

    public let content: Content
    public let modifier: Modifier

    public init(content: Content, modifier: Modifier) {
        self.content = content
        self.modifier = modifier
    }
}
