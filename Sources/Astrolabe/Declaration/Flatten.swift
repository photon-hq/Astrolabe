/// Walks a component down to its resources, in declaration order.
///
/// Structural types (sequences, conditionals, loops, leaves) conform to `_Flattenable`; anything
/// else is a composite, so its `body` is evaluated and walked in turn.
@MainActor
enum Flatten {
    static func resources<C: Component>(of component: C) -> [AnyResource] {
        var resources: [AnyResource] = []
        walk(component, into: &resources)
        return resources
    }

    static func walk<C: Component>(_ component: C, into resources: inout [AnyResource]) {
        if let flattenable = component as? any _Flattenable {
            flattenable._flatten(into: &resources)
            return
        }
        // A primitive the engine does not know how to destructure declares nothing.
        guard C.Body.self != Never.self else { return }
        walk(component.body, into: &resources)
    }
}

/// Framework-internal: types `Flatten` destructures instead of evaluating `body`.
@MainActor
protocol _Flattenable {
    func _flatten(into resources: inout [AnyResource])
}

extension EmptyComponent: _Flattenable {
    func _flatten(into resources: inout [AnyResource]) {}
}

extension ComponentSequence: _Flattenable {
    func _flatten(into resources: inout [AnyResource]) {
        for component in repeat each components {
            Flatten.walk(component, into: &resources)
        }
    }
}

extension OptionalComponent: _Flattenable {
    func _flatten(into resources: inout [AnyResource]) {
        if let wrapped { Flatten.walk(wrapped, into: &resources) }
    }
}

extension ConditionalComponent: _Flattenable {
    func _flatten(into resources: inout [AnyResource]) {
        switch self {
        case .first(let component): Flatten.walk(component, into: &resources)
        case .second(let component): Flatten.walk(component, into: &resources)
        }
    }
}

extension ForEachComponent: _Flattenable {
    func _flatten(into resources: inout [AnyResource]) {
        for element in elements { Flatten.walk(element, into: &resources) }
    }
}

extension ResourceLeaf: _Flattenable {
    func _flatten(into resources: inout [AnyResource]) {
        resources.append(AnyResource(resource))
    }
}
