/// Maps `kind` strings to Swift types, so snapshots in `records.json` can be decoded after a
/// restart.
///
/// Filled at launch with every `@Resource` type linked into the binary, plus every type seen in
/// a declaration. Two types claiming the same `kind` would make records ambiguous: at launch
/// that's a fatal error, in a declaration the later type is refused.
struct ResourceRegistry {
    private var types: [String: any Resource.Type] = [:]

    /// Registers `types`, or reports the first `kind` claimed by two different types.
    init(_ types: [any Resource.Type]) throws(Conflict) {
        for type in types {
            if case .conflict(let existing) = register(type) {
                throw Conflict(kind: type.kind, existing: existing, new: type)
            }
        }
    }

    enum Registration {
        /// `kind` wasn't known before.
        case new
        /// `kind` was already registered to this type.
        case known
        /// `kind` is registered to a different type, which stays registered.
        case conflict(existing: any Resource.Type)
    }

    @discardableResult
    mutating func register(_ type: any Resource.Type) -> Registration {
        guard let existing = types[type.kind] else {
            types[type.kind] = type
            return .new
        }
        return existing == type ? .known : .conflict(existing: existing)
    }

    func type(for kind: String) -> (any Resource.Type)? {
        types[kind]
    }

    struct Conflict: Error, CustomStringConvertible {
        let kind: String
        let existing: any Resource.Type
        let new: any Resource.Type

        var description: String {
            "Resource kind \"\(kind)\" is claimed by both \(existing) and \(new)"
        }
    }
}
