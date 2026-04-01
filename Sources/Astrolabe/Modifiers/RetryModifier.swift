/// A modifier that retries reconciliation on failure.
public struct RetryModifier: SetupModifier {
    public let count: Int
    public let delay: Duration?

    public init(count: Int, delay: Duration? = nil) {
        self.count = count
        self.delay = delay
    }
}

extension Setup {
    /// Retries reconciliation up to `count` times on failure.
    public func retry(_ count: Int, delay: Duration? = nil) -> ModifiedContent<Self, RetryModifier> {
        ModifiedContent(content: self, modifier: RetryModifier(count: count, delay: delay))
    }
}
