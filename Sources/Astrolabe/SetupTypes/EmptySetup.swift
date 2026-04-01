/// A no-op declaration. Used for empty configuration bodies.
public struct EmptySetup: Setup {
    public typealias Body = Never
    public init() {}
}
