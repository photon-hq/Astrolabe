/// Metadata + reconciliation logic for a `Jamf` leaf node.
public struct JamfInfo: ReconcilableNode {
    public let source: JamfSource

    public enum JamfSource: Sendable {
        case computerName(name: String)
        case custom(typeName: String)
    }

    public var displayName: String {
        switch source {
        case .computerName(let n): "jamf computerName \(n)"
        case .custom(let t): "jamf custom \(t)"
        }
    }

    /// Reconstructs the concrete `JamfSetting` from the persisted source.
    /// Returns `nil` for `.custom` — those can't be revived from the tree alone.
    private func makeSetting() -> (any JamfSetting)? {
        switch source {
        case .computerName(let name): return ComputerNameSetting(name)
        case .custom: return nil
        }
    }

    private var payloadKey: String {
        switch source {
        case .computerName(let name): "jamf-computerName:\(name)"
        case .custom(let typeName): "jamf-custom:\(typeName)"
        }
    }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        guard let setting = makeSetting() else {
            if case .custom(let typeName) = source {
                print("[Astrolabe] Cannot reconcile custom Jamf setting \(typeName) from persisted tree.")
            }
            return
        }
        if try await setting.check() {
            print("[Astrolabe] \(displayName) already configured, skipping.")
        } else {
            print("[Astrolabe] Applying \(displayName)...")
            try await setting.apply()
            print("[Astrolabe] Applied \(displayName).")
        }
        context.payloadStore.set(.sys(setting: payloadKey), for: identity)
    }

    public func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome {
        // `.custom` settings can't be verified from the persisted form.
        guard let setting = makeSetting() else { return .healthy }
        return try await setting.check() ? .healthy : .drifted(reason: "\(displayName) drifted")
    }
}
