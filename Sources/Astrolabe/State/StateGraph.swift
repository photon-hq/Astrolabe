import Foundation

/// Position-keyed store for `@State` values.
///
/// Maps `(NodeIdentity, propertyLabel)` → value. Values survive across
/// tree re-evaluations because the key is structural position + property name,
/// not the ephemeral `Setup` struct instance.
///
/// Before calling `setup.body`, TreeBuilder calls `connect(_:at:)` which uses
/// `Mirror` to discover `@State` properties and link their handles to the graph.
public final class StateGraph: @unchecked Sendable {
    public static let shared = StateGraph()

    private let lock = NSLock()
    private var slots: [SlotKey: any Sendable] = [:]

    private init() {}

    func get<V>(path: NodeIdentity, slot: String) -> V? {
        lock.withLock { slots[SlotKey(path: path, slot: slot)] as? V }
    }

    func set<V: Equatable & Sendable>(path: NodeIdentity, slot: String, value: V) -> Bool {
        lock.withLock {
            let key = SlotKey(path: path, slot: slot)
            if let existing = slots[key] as? V, existing == value { return false }
            slots[key] = value
            return true
        }
    }

    /// Connect all `@State` properties on a Setup to the graph.
    /// Called by TreeBuilder before body evaluation.
    func connect<S: Setup>(_ setup: S, at path: NodeIdentity) {
        let mirror = Mirror(reflecting: setup)
        for child in mirror.children {
            guard let label = child.label,
                  let state = child.value as? any _StateProperty else { continue }
            state._connect(path: path, slot: label)
        }
    }
}

struct SlotKey: Hashable {
    let path: NodeIdentity
    let slot: String
}

/// Internal protocol so `StateGraph.connect()` can discover `@State` properties via Mirror.
protocol _StateProperty {
    func _connect(path: NodeIdentity, slot: String)
}
