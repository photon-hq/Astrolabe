/// A no-op setup step. Used for empty configuration bodies.
public struct EmptySetup: Setup {
    public init() {}

    public func execute() async throws {}
}
