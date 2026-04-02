/// A modifier that invokes a callback after a successful mount (install).
public struct PostInstallModifier: SetupModifier, @unchecked Sendable {
    public let handler: @Sendable () async -> Void

    public init(handler: @escaping @Sendable () async -> Void) {
        self.handler = handler
    }
}

extension Setup {
    /// Runs an async closure immediately after this declaration is successfully installed.
    public func postInstall(
        _ handler: @escaping @Sendable () async -> Void
    ) -> ModifiedContent<Self, PostInstallModifier> {
        ModifiedContent(content: self, modifier: PostInstallModifier(handler: handler))
    }
}
