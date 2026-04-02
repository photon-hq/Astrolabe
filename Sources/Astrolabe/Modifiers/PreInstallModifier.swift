/// A modifier that invokes a callback before mount (install).
public struct PreInstallModifier: SetupModifier, @unchecked Sendable {
    public let handler: @Sendable () async throws -> Void

    public init(handler: @escaping @Sendable () async throws -> Void) {
        self.handler = handler
    }
}

extension Setup {
    /// Runs an async closure immediately before this declaration is installed.
    /// If the closure throws, mount is skipped (treated as a mount failure).
    public func preInstall(
        _ handler: @escaping @Sendable () async throws -> Void
    ) -> ModifiedContent<Self, PreInstallModifier> {
        ModifiedContent(content: self, modifier: PreInstallModifier(handler: handler))
    }
}
