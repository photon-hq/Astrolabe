import Foundation

/// Side table for closure-bearing modifiers that can't be serialized into `TreeNode`.
///
/// Built alongside the tree each tick. Ephemeral — cleared and rebuilt every `tick()`.
/// Maps `NodeIdentity` to the closures attached via `.task {}`, `.dialog()`, and `.onFail {}`.
public final class ModifierStore: @unchecked Sendable {
    public static let shared = ModifierStore()

    private let lock = NSLock()
    private var entries: [NodeIdentity: Callbacks] = [:]

    /// Non-serializable modifier data for a single node.
    public struct Callbacks: Sendable {
        public var tasks: [TaskModifier] = []
        public var dialogs: [DialogModifier] = []
        public var onFail: [OnFailModifier] = []
    }

    public init() {}

    public func callbacks(for identity: NodeIdentity) -> Callbacks? {
        lock.withLock { entries[identity] }
    }

    func appendTask(_ modifier: TaskModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].tasks.append(modifier)
        }
    }

    func appendDialog(_ modifier: DialogModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].dialogs.append(modifier)
        }
    }

    func appendOnFail(_ modifier: OnFailModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].onFail.append(modifier)
        }
    }

    public func clear() {
        lock.withLock { entries.removeAll() }
    }
}
