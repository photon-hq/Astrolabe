/// Metadata + reconciliation logic for a `Sys` leaf node.
public struct SysInfo: ReconcilableNode {
    public let source: SysSource

    public enum SysSource: Sendable {
        case hostname(name: String)
        case pmset(pairs: [String], source: String)
        case custom(typeName: String)
    }

    public var displayName: String {
        switch source {
        case .hostname(let n): "sys hostname \(n)"
        case .pmset(let pairs, let src): "sys pmset \(src) \(pairs.joined(separator: " "))"
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

        case .pmset(let pairs, let sourceFlag):
            var pmSettings: [PmsetSetting.PMSetting] = []
            var i = 0
            while i + 1 < pairs.count {
                if let setting = PmsetSetting.PMSetting.from(key: pairs[i], value: Int(pairs[i + 1]) ?? 0) {
                    pmSettings.append(setting)
                }
                i += 2
            }
            let powerSource = PmsetSetting.PowerSource(rawValue: sourceFlag) ?? .all
            let setting = PmsetSetting(pmSettings, on: powerSource)

            if try await setting.check() {
                print("[Astrolabe] pmset \(sourceFlag) already configured, skipping.")
            } else {
                print("[Astrolabe] Applying pmset \(sourceFlag) settings...")
                try await setting.apply()
                print("[Astrolabe] pmset \(sourceFlag) settings applied.")
            }
            context.payloadStore.set(.sys(setting: "pmset:\(sourceFlag):\(pairs.joined(separator: ","))"), for: identity)

        case .custom(let typeName):
            print("[Astrolabe] Cannot reconcile custom system setting \(typeName) from persisted tree.")
        }
    }
}
