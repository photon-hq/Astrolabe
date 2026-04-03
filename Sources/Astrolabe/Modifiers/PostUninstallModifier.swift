/// A modifier that invokes a callback after a successful unmount (uninstall).
public struct PostUninstallModifier: SetupModifier, @unchecked Sendable {
    public let handler: @Sendable () async -> Void

    public init(handler: @escaping @Sendable () async -> Void) {
        self.handler = handler
    }
}

extension Setup {
    /// Runs an async closure immediately after this declaration is successfully uninstalled.
    public func postUninstall(
        _ handler: @escaping @Sendable () async -> Void
    ) -> ModifiedContent<Self, PostUninstallModifier> {
        ModifiedContent(content: self, modifier: PostUninstallModifier(handler: handler))
    }
}
