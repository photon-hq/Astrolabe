/// A modifier that controls scheduling after repeated drift.
public struct RetryPolicyModifier: SetupModifier {
    public let policy: RetryPolicy

    public init(policy: RetryPolicy) {
        self.policy = policy
    }
}

enum RetryPolicyKey: EnvironmentKey {
    static let defaultValue: RetryPolicy? = nil
}

extension Setup {
    /// Sets the retry policy for this declaration and its descendants.
    ///
    /// A policy on a child overrides its enclosing group. Without a modifier,
    /// retries use exponential backoff capped at 15 minutes, without jitter.
    public func retryPolicy(_ policy: RetryPolicy) -> ModifiedContent<Self, RetryPolicyModifier> {
        ModifiedContent(content: self, modifier: RetryPolicyModifier(policy: policy))
    }
}
