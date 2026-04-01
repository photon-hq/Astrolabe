/// A sequential group of declarations, produced by `SetupBuilder.buildBlock`.
///
/// Analogous to SwiftUI's `TupleView`. The framework destructures it by index
/// to walk its children.
public struct SetupSequence<each S: Setup>: Setup {
    public typealias Body = Never

    public let steps: (repeat each S)

    public init(steps: (repeat each S)) {
        self.steps = (repeat each steps)
    }
}
