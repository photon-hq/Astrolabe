/// Represents an optional declaration (if without else), produced by `SetupBuilder.buildOptional`.
public struct OptionalSetup<Wrapped: Setup>: Setup {
    public typealias Body = Never

    public let wrapped: Wrapped?

    public init(wrapped: Wrapped?) {
        self.wrapped = wrapped
    }
}
