import Foundation

/// Ephemeral local state that triggers body re-evaluation on mutation.
///
/// Like SwiftUI's `@State` — in-memory only, resets on daemon restart.
/// Values are stored in the `StateGraph`, keyed by tree position + property name.
/// The framework discovers `@State` properties via `Mirror` before body evaluation,
/// connecting each handle to its slot in the graph.
///
/// ```swift
/// @State var showWelcome = true
/// ```
@propertyWrapper
public struct State<Value: Equatable & Sendable>: Sendable, _StateProperty {
    private let handle: StateHandle<Value>

    public init(wrappedValue: Value) {
        self.handle = StateHandle(defaultValue: wrappedValue)
    }

    public var wrappedValue: Value {
        get { handle.get() }
        nonmutating set { handle.set(newValue) }
    }

    public var projectedValue: Binding<Value> {
        Binding(
            get: { handle.get() },
            set: { handle.set($0) }
        )
    }

    func _connect(path: NodeIdentity, slot: String) {
        handle.connect(path: path, slot: slot)
    }
}

/// Reference-type backing for `@State`. Holds connection info to the `StateGraph`.
///
/// Before body evaluation, `StateGraph.connect()` calls `connect(path:slot:)` to
/// link this handle to its position-keyed slot. Getters/setters then route through
/// the graph. Before connection, returns the default value.
final class StateHandle<Value: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var localValue: Value
    private var path: NodeIdentity?
    private var slot: String?

    init(defaultValue: Value) {
        self.localValue = defaultValue
    }

    func connect(path: NodeIdentity, slot: String) {
        lock.withLock {
            self.path = path
            self.slot = slot
        }
    }

    func get() -> Value {
        let (p, s) = lock.withLock { (path, slot) }
        guard let p, let s else { return lock.withLock { localValue } }
        return StateGraph.shared.get(path: p, slot: s) ?? lock.withLock { localValue }
    }

    func set(_ newValue: Value) {
        let (p, s) = lock.withLock { (path, slot) }
        guard let p, let s else {
            // Not connected to graph — use local storage
            lock.withLock { localValue = newValue }
            return
        }
        if StateGraph.shared.set(path: p, slot: s, value: newValue) {
            StateNotifier.shared.notifyChange()
        }
    }
}
