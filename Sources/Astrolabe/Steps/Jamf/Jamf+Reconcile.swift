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

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        switch source {
        case .computerName(let name):
            let setting = ComputerNameSetting(name)
            if try await setting.check() {
                print("[Astrolabe] Jamf computer name already \(name), skipping.")
            } else {
                print("[Astrolabe] Setting Jamf computer name to \(name)...")
                try await setting.apply()
                print("[Astrolabe] Jamf computer name set to \(name).")
            }
            context.payloadStore.set(.sys(setting: "jamf-computerName:\(name)"), for: identity)

        case .custom(let typeName):
            print("[Astrolabe] Cannot reconcile custom Jamf setting \(typeName) from persisted tree.")
        }
    }
}
