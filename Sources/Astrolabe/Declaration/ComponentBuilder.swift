/// Composes components and resources: blocks, `if`, `if let`, `if`/`else`, `switch`, and `for`.
///
/// There are no modifiers. Anything per-resource, such as its retry policy, is a static on the
/// resource type.
@resultBuilder
@MainActor
public enum ComponentBuilder {
    /// Passes a component through unchanged.
    public static func buildExpression<C: Component>(_ component: C) -> C {
        component
    }

    /// Wraps a resource. `Resource` is not a `Component`: it is `Codable` and `Sendable`, and must
    /// never hold a reference to state.
    public static func buildExpression<R: Resource>(_ resource: R) -> ResourceLeaf<R> {
        ResourceLeaf(resource: resource)
    }

    /// An empty body.
    public static func buildBlock() -> EmptyComponent {
        EmptyComponent()
    }

    /// A single component, unchanged.
    public static func buildBlock<C: Component>(_ component: C) -> C {
        component
    }

    /// Several components in sequence.
    public static func buildBlock<each C: Component>(
        _ components: repeat each C
    ) -> ComponentSequence<repeat each C> {
        ComponentSequence(components: (repeat each components))
    }

    /// `if condition { … }` and `if let x { … }` without an `else`.
    public static func buildOptional<C: Component>(_ component: C?) -> OptionalComponent<C> {
        OptionalComponent(wrapped: component)
    }

    /// `if`/`else` and `switch`: the first branch.
    public static func buildEither<First: Component, Second: Component>(
        first component: First
    ) -> ConditionalComponent<First, Second> {
        .first(component)
    }

    /// `if`/`else` and `switch`: the second branch.
    public static func buildEither<First: Component, Second: Component>(
        second component: Second
    ) -> ConditionalComponent<First, Second> {
        .second(component)
    }

    /// `for … in` loops.
    public static func buildArray<C: Component>(_ components: [C]) -> ForEachComponent<C> {
        ForEachComponent(elements: components)
    }
}
