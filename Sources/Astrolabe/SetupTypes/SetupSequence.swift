/// A sequential group of setup steps, produced by `SetupBuilder.buildBlock`.
public struct SetupSequence<each S: Setup>: Setup {
    public let steps: (repeat each S)

    public init(steps: (repeat each S)) {
        self.steps = (repeat each steps)
    }

    public func execute() async throws {
        for step in repeat each steps {
            try await step.execute()
        }
    }
}
