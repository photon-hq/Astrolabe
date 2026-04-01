/// A modifier that invokes a callback when reconciliation fails.
public struct OnFailModifier: SetupModifier, @unchecked Sendable {
    public let handler: @Sendable (any Error) async -> Void

    public init(handler: @escaping @Sendable (any Error) async -> Void) {
        self.handler = handler
    }
}

extension Setup {
    /// Calls the handler when reconciliation of this declaration fails.
    public func onFail(
        _ handler: @escaping @Sendable (any Error) async -> Void
    ) -> ModifiedContent<Self, OnFailModifier> {
        ModifiedContent(content: self, modifier: OnFailModifier(handler: handler))
    }
}
