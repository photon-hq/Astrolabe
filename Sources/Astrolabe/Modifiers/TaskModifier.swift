/// A modifier that runs async work tied to a declaration's lifecycle.
///
/// Like SwiftUI's `.task` — starts when the declaration enters the tree,
/// cancelled when it leaves.
public struct TaskModifier: SetupModifier, @unchecked Sendable {
    public let id: AnyHashable?
    public let action: @Sendable () async -> Void

    public init(id: AnyHashable? = nil, action: @escaping @Sendable () async -> Void) {
        self.id = id
        self.action = action
    }
}

extension Setup {
    /// Runs async work when this declaration enters the tree.
    public func task(
        _ action: @escaping @Sendable () async -> Void
    ) -> ModifiedContent<Self, TaskModifier> {
        ModifiedContent(content: self, modifier: TaskModifier(action: action))
    }

    /// Runs async work when this declaration enters the tree, restarting when `id` changes.
    public func task<ID: Hashable & Sendable>(
        id: ID,
        _ action: @escaping @Sendable () async -> Void
    ) -> ModifiedContent<Self, TaskModifier> {
        ModifiedContent(content: self, modifier: TaskModifier(id: AnyHashable(id), action: action))
    }
}
