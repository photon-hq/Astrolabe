import Foundation

/// A type-erased resource. `Self` appears as a parameter of every `Resource` requirement, so the
/// engine opens the existential through the generic helpers below.
struct AnyResource: Sendable {
    let base: any Resource

    init(_ base: any Resource) {
        self.base = base
    }

    var id: String { base.id }
    var type: any Resource.Type { Swift.type(of: base) }
    var kind: String { type.kind }
    var policy: RetryPolicy { type.retryPolicy }
    var timeout: Duration { type.timeout }

    func hash() -> String { Self.hash(base) }

    /// Every `@Monitor` in the snapshot, by name and value, or `nil` when it has none. The engine
    /// keeps it apart from `hash()`: a change reruns `rollout`, but never cancels one.
    func monitorHash() -> String? {
        let monitors = self.monitors
        guard !monitors.isEmpty else { return nil }
        return Hash.of(parts: monitors.flatMap { [$0.name, $0.monitor] as [any HashPart] })
    }

    /// The monitors that read nothing: the resource was built outside a pass.
    var unobservedMonitors: [String] {
        monitors.filter { !$0.monitor.isObserved }.map(\.name)
    }

    /// Found by reflection, the way SwiftUI finds a view's `DynamicProperty` fields, so `@Resource`
    /// needn't list them. Sorted by name: reordering the properties changes nothing.
    private var monitors: [(name: String, monitor: any _AnyMonitor)] {
        var monitors: [(name: String, monitor: any _AnyMonitor)] = []
        var mirror: Mirror? = Mirror(reflecting: base)
        while let current = mirror {
            for case (let label?, let monitor as any _AnyMonitor) in current.children {
                // The wrapper's storage: `_isInstalled` for `isInstalled`.
                monitors.append((label.hasPrefix("_") ? String(label.dropFirst()) : label, monitor))
            }
            mirror = current.superclassMirror
        }
        return monitors.sorted { $0.name < $1.name }
    }

    @concurrent func rollout() async throws { try await Self.rollout(base) }
    @concurrent func remove() async throws { try await Self.remove(base) }

    /// The snapshot as nested JSON, the form `records.json` stores.
    func encode() throws -> JSONValue {
        let data = try JSONEncoder().encode(base)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes a snapshot written by `encode()`, using `registry` to find the Swift type for `kind`.
    static func decode(kind: String, _ json: JSONValue, registry: ResourceRegistry) throws -> AnyResource {
        guard let type = registry.type(for: kind) else {
            throw DecodeError.unknownKind(kind)
        }
        let data = try JSONEncoder().encode(json)
        return AnyResource(try decode(type, from: data))
    }

    enum DecodeError: Error, Equatable {
        case unknownKind(String)
    }

    private static func hash<R: Resource>(_ resource: R) -> String { R.compute(resource) }
    private static func rollout<R: Resource>(_ resource: R) async throws { try await R.rollout(resource) }
    private static func remove<R: Resource>(_ resource: R) async throws { try await R.remove(resource) }

    private static func decode<R: Resource>(_: R.Type, from data: Data) throws -> any Resource {
        try JSONDecoder().decode(R.self, from: data)
    }
}
