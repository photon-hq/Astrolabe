/// A modifier that overrides the drift-check cadence for a node.
///
/// Defaults come from the node's `ReconcilableNode.loopInterval` (15s for most
/// nodes). Use this to slow down expensive checks or speed up debugging.
public struct LoopIntervalModifier: SetupModifier {
    public let duration: Duration

    public init(duration: Duration) {
        self.duration = duration
    }
}

extension Setup {
    /// Overrides the drift-check cadence for this node.
    ///
    /// ```swift
    /// Sys(.pmset(.displaysleep(15), .sleep(0), on: .charger))
    ///     .loopInterval(.seconds(60))
    /// ```
    public func loopInterval(_ duration: Duration) -> ModifiedContent<Self, LoopIntervalModifier> {
        ModifiedContent(content: self, modifier: LoopIntervalModifier(duration: duration))
    }
}
