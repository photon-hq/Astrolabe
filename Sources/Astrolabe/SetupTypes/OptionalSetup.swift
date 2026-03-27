/// Represents an optional setup (if without else), produced by `SetupBuilder.buildOptional`.
public struct OptionalSetup<Wrapped: Setup>: Setup {
    public let wrapped: Wrapped?

    public func execute() async throws {
        try await wrapped?.execute()
    }
}
