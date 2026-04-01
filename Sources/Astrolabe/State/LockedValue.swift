import Foundation

/// Thread-safe mutable value with change detection.
///
/// Used by `StateProvider` implementations to track their previous value
/// and detect when state changes.
final class LockedValue<Value: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        self._value = value
    }

    /// Sets a new value and returns `true` if it differs from the previous value.
    @discardableResult
    func exchange(_ newValue: Value) -> Bool {
        lock.withLock {
            let changed = _value != newValue
            _value = newValue
            return changed
        }
    }
}
