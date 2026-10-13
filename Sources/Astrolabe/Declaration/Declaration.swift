/// One pass's declaration: every declared resource by id, with its hash.
///
/// Built synchronously on the main actor: `app.body` → flatten → `compute`. Only built from a
/// pass that read real values for every fact it read, never a default.
struct Declaration {
    struct Item {
        let resource: AnyResource
        let hash: String
    }

    private(set) var items: [String: Item] = [:]

    /// Ids the engine leaves alone this pass: no rollout, no removal. An id is frozen when it is
    /// declared twice with different hashes, or when its type's `kind` is claimed by another type.
    private(set) var frozen: Set<String> = []

    /// Ids declared more than once with different hashes, with every hash seen.
    private(set) var duplicates: [String: [String]] = [:]

    init(_ resources: [AnyResource]) {
        for resource in resources {
            let id = resource.id
            let hash = resource.hash()
            if duplicates[id] != nil {
                duplicates[id]?.append(hash)
            } else if let existing = items[id] {
                // Declared twice the same way: deduplicated.
                guard existing.hash != hash else { continue }
                duplicates[id] = [existing.hash, hash]
                freeze(id)
            } else {
                items[id] = Item(resource: resource, hash: hash)
            }
        }
    }

    mutating func freeze(_ id: String) {
        items[id] = nil
        frozen.insert(id)
    }
}
