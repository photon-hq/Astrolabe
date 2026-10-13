/// A body that declares nothing.
public struct EmptyComponent: Component {
    public typealias Body = Never
    public init() {}
}

/// Components declared one after another in a block.
public struct ComponentSequence<each C: Component>: Component {
    public typealias Body = Never
    let components: (repeat each C)
}

/// An `if` without an `else`: the component when the condition held, nothing otherwise.
public struct OptionalComponent<Wrapped: Component>: Component {
    public typealias Body = Never
    let wrapped: Wrapped?
}

/// One branch of an `if`/`else` or `switch`.
public enum ConditionalComponent<First: Component, Second: Component>: Component {
    public typealias Body = Never
    case first(First)
    case second(Second)
}

/// The components produced by a `for … in` loop.
public struct ForEachComponent<Element: Component>: Component {
    public typealias Body = Never
    let elements: [Element]
}

/// A resource in a declaration. The builder wraps every resource expression in one.
public struct ResourceLeaf<R: Resource>: Component {
    public typealias Body = Never
    let resource: R
}
