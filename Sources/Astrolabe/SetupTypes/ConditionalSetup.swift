/// Represents a conditional declaration (if/else), produced by `SetupBuilder.buildEither`.
///
/// Analogous to SwiftUI's `_ConditionalContent`.
public enum ConditionalSetup<TrueSetup: Setup, FalseSetup: Setup>: Setup {
    public typealias Body = Never

    case first(TrueSetup)
    case second(FalseSetup)
}
