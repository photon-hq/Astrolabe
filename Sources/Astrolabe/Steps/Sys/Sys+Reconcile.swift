/// Metadata + reconciliation logic for a `Sys` leaf node.
public struct SysInfo: ReconcilableNode {
    public let source: SysSource

    public enum SysSource: Sendable {
        case hostname(name: String)
        case pmset(pairs: [String], source: String)
        case wallpaper(path: String, scaling: String)
        case custom(typeName: String)
    }

    public var displayName: String {
        switch source {
        case .hostname(let n): "sys hostname \(n)"
        case .pmset(let pairs, let src): "sys pmset \(src) \(pairs.joined(separator: " "))"
        case .wallpaper(let p, let s): "sys wallpaper \(p) (\(s))"
        case .custom(let t): "sys custom \(t)"
        }
    }

    /// Reconstructs the concrete `SystemSetting` from the persisted source.
    /// Returns `nil` for `.custom` — those can't be revived from the tree alone.
    private func makeSetting() -> (any SystemSetting)? {
        switch source {
        case .hostname(let name):
            return HostnameSetting(name)
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
            return PmsetSetting(pmSettings, on: powerSource)
        case .wallpaper(let path, let scaling):
            return WallpaperSetting(path, scaling: WallpaperSetting.Scaling(rawValue: scaling) ?? .fill)
        case .custom:
            return nil
        }
    }

    private var payloadKey: String {
        switch source {
        case .hostname(let name): "hostname:\(name)"
        case .pmset(let pairs, let src): "pmset:\(src):\(pairs.joined(separator: ","))"
        case .wallpaper(let path, let scaling): "wallpaper:\(path):\(scaling)"
        case .custom(let typeName): "custom:\(typeName)"
        }
    }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        guard let setting = makeSetting() else {
            if case .custom(let typeName) = source {
                print("[Astrolabe] Cannot reconcile custom system setting \(typeName) from persisted tree.")
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
