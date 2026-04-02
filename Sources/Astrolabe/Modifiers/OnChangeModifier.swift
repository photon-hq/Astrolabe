/// Internal protocol for type-erased onChange execution.
///
/// Allows `ModifierStore` and `LifecycleEngine` to work with `OnChangeModifier<Value>`
/// without knowing the concrete `Value` type. Same pattern as `_EnvironmentApplicable`.
protocol _OnChangeExecutable: Sendable {
    /// Compares the current value against `previousValue`, fires the action if different,
    /// and returns the current value for storage as the next "previous".
    func _execute(previousValue: (any Sendable)?) -> any Sendable
}

/// A modifier that fires a closure when a value changes between ticks.
///
/// Like SwiftUI's `.onChange(of:)` — compares the value from the current tick against
/// the previous tick. Does NOT fire on initial appearance (first tick sees no previous value).
///
/// ```swift
/// Brew("git")
///     .onChange(of: isEnrolled) { oldValue, newValue in
///         print("Enrollment changed: \(oldValue) → \(newValue)")
///     }
/// ```
public struct OnChangeModifier<Value: Equatable & Sendable>: SetupModifier, _OnChangeExecutable, @unchecked Sendable {
    let value: Value
    let action: @Sendable (Value, Value) -> Void

    func _execute(previousValue: (any Sendable)?) -> any Sendable {
        if let prev = previousValue as? Value, prev != value {
            action(prev, value)
        }
        return value
    }
}

extension Setup {
    /// Fires the closure when `value` changes between ticks.
    ///
    /// The closure receives `(oldValue, newValue)`. Does not fire on the first tick
    /// (no previous value to compare against).
    /// Fires the closure with `(oldValue, newValue)` when `value` changes between ticks.
    public func onChange<Value: Equatable & Sendable>(
        of value: Value,
        _ action: @escaping @Sendable (Value, Value) -> Void
    ) -> ModifiedContent<Self, OnChangeModifier<Value>> {
        ModifiedContent(content: self, modifier: OnChangeModifier(value: value, action: action))
    }

    /// Fires the closure when `value` changes between ticks.
    public func onChange<Value: Equatable & Sendable>(
        of value: Value,
        _ action: @escaping @Sendable () -> Void
    ) -> ModifiedContent<Self, OnChangeModifier<Value>> {
        ModifiedContent(content: self, modifier: OnChangeModifier(value: value, action: { _, _ in action() }))
    }
}
