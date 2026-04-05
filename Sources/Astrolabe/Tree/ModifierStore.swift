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
        public var listDialogs: [ListDialogModifier] = []
        public var onFail: [OnFailModifier] = []
        public var preInstall: [PreInstallModifier] = []
        public var postInstall: [PostInstallModifier] = []
        public var preUninstall: [PreUninstallModifier] = []
        public var postUninstall: [PostUninstallModifier] = []
        var onChanges: [any _OnChangeExecutable] = []
        public var retry: (count: Int, delaySeconds: Double?)? = nil
        public var priority: Int? = nil
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

    func appendListDialog(_ modifier: ListDialogModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].listDialogs.append(modifier)
        }
    }

    func appendOnFail(_ modifier: OnFailModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].onFail.append(modifier)
        }
    }

    func appendPreInstall(_ modifier: PreInstallModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].preInstall.append(modifier)
        }
    }

    func prependPreInstall(_ modifier: PreInstallModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].preInstall.insert(modifier, at: 0)
        }
    }

    func appendPostInstall(_ modifier: PostInstallModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].postInstall.append(modifier)
        }
    }

    func appendPreUninstall(_ modifier: PreUninstallModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].preUninstall.append(modifier)
        }
    }

    func prependPreUninstall(_ modifier: PreUninstallModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].preUninstall.insert(modifier, at: 0)
        }
    }

    func appendPostUninstall(_ modifier: PostUninstallModifier, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].postUninstall.append(modifier)
        }
    }

    func appendOnChange(_ modifier: any _OnChangeExecutable, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].onChanges.append(modifier)
        }
    }

    func setRetry(count: Int, delaySeconds: Double?, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].retry = (count, delaySeconds)
        }
    }

    func setPriority(_ value: Int, for identity: NodeIdentity) {
        lock.withLock {
            entries[identity, default: Callbacks()].priority = value
        }
    }

    public func clear() {
        lock.withLock { entries.removeAll() }
    }
}
