/// A modifier that injects an environment value into the subtree.
public struct EnvironmentModifier<Value: Sendable>: SetupModifier, @unchecked Sendable {
    public let keyPath: WritableKeyPath<EnvironmentValues, Value>
    public let value: Value

    public init(keyPath: WritableKeyPath<EnvironmentValues, Value>, value: Value) {
        self.keyPath = keyPath
        self.value = value
    }

    /// Applies this modifier to the given environment.
    public func apply(to environment: inout EnvironmentValues) {
        environment[keyPath: keyPath] = value
    }
}

extension Setup {
    /// Sets an environment value for this declaration and all its children.
    public func environment<V: Sendable>(
        _ keyPath: WritableKeyPath<EnvironmentValues, V>,
        _ value: V
    ) -> ModifiedContent<Self, EnvironmentModifier<V>> {
        ModifiedContent(content: self, modifier: EnvironmentModifier(keyPath: keyPath, value: value))
    }
}
