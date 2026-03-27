/// A result builder that enables declarative composition of setup steps.
@resultBuilder
public struct SetupBuilder {
    /// Combines multiple setup steps into a sequential group.
    public static func buildBlock<each S: Setup>(
        _ steps: repeat each S
    ) -> SetupSequence<repeat each S> {
        SetupSequence(steps: (repeat each steps))
    }

    /// Handles an empty body.
    public static func buildBlock() -> EmptySetup {
        EmptySetup()
    }

    /// Supports `if condition { ... } else { ... }` — true branch.
    public static func buildEither<First: Setup, Second: Setup>(
        first component: First
    ) -> ConditionalSetup<First, Second> {
        .first(component)
    }

    /// Supports `if condition { ... } else { ... }` — false branch.
    public static func buildEither<First: Setup, Second: Setup>(
        second component: Second
    ) -> ConditionalSetup<First, Second> {
        .second(component)
    }

    /// Supports `if condition { ... }` without an else branch.
    public static func buildOptional<S: Setup>(
        _ component: S?
    ) -> OptionalSetup<S> {
        OptionalSetup(wrapped: component)
    }

    /// Supports a single expression body.
    public static func buildExpression<S: Setup>(
        _ expression: S
    ) -> S {
        expression
    }
}
