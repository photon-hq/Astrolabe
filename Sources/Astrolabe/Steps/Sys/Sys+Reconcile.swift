/// Metadata + reconciliation logic for a `Sys` leaf node.
public struct SysInfo: ReconcilableNode {
    public let source: SysSource

    public enum SysSource: Sendable {
        case hostname(name: String)
        case custom(typeName: String)
    }

    public var displayName: String {
        switch source {
        case .hostname(let n): "sys hostname \(n)"
        case .custom(let t): "sys custom \(t)"
        }
    }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        switch source {
        case .hostname(let name):
            let setting = HostnameSetting(name)
            if try await setting.check() {
                print("[Astrolabe] Hostname already \(name), skipping.")
            } else {
                print("[Astrolabe] Setting hostname to \(name)...")
                try await setting.apply()
                print("[Astrolabe] Hostname set to \(name).")
            }
            context.payloadStore.set(.sys(setting: "hostname:\(name)"), for: identity)

        case .custom(let typeName):
            print("[Astrolabe] Cannot reconcile custom system setting \(typeName) from persisted tree.")
        }
    }
}
