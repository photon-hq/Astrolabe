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
