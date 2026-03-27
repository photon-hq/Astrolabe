/// Represents a conditional setup (if/else), produced by `SetupBuilder.buildEither`.
public enum ConditionalSetup<TrueSetup: Setup, FalseSetup: Setup>: Setup {
    case first(TrueSetup)
    case second(FalseSetup)

    public func execute() async throws {
        switch self {
        case .first(let setup):
            try await setup.execute()
        case .second(let setup):
            try await setup.execute()
        }
    }
}
