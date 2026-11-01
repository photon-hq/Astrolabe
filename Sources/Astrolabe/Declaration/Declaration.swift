/// One pass's declaration: every declared resource by id, with its hash.
///
/// Built synchronously on the main actor: `app.body` → flatten → `compute`. Only built from a
/// pass that read real values for every fact it read, never a default.
struct Declaration {
    struct Item {
        let resource: AnyResource
        let hash: String
        /// `resource.monitorHash()`: `nil` without `@Monitor`s. Never part of `hash`.
        let monitor: String?
    }

    private(set) var items: [String: Item] = [:]

    /// Ids the engine leaves alone this pass: no rollout, no removal. An id is frozen when it is
    /// declared twice differently, or when its type's `kind` is claimed by another type.
    private(set) var frozen: Set<String> = []

    /// Ids declared more than once with different hashes or monitor hashes, with every hash seen.
    private(set) var duplicates: [String: [String]] = [:]

    init(_ resources: [AnyResource]) {
        for resource in resources {
            let id = resource.id
            let hash = resource.hash()
            let monitor = resource.monitorHash()
            if duplicates[id] != nil {
                duplicates[id]?.append(hash)
            } else if let existing = items[id] {
                // Declared twice the same way: deduplicated.
                guard existing.hash != hash || existing.monitor != monitor else { continue }
                duplicates[id] = [existing.hash, hash]
                freeze(id)
            } else {
                items[id] = Item(resource: resource, hash: hash, monitor: monitor)
            }
        }
    }

    mutating func freeze(_ id: String) {
        items[id] = nil
        frozen.insert(id)
    }
}
