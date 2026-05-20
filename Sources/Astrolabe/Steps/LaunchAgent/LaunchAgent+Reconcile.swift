import Foundation

/// Reconciliation metadata for a `LaunchAgent` leaf node.
///
/// `programArguments` and `environment` are captured at `_buildTree` time to
/// drive plist generation and activation. The persisted-form initializer leaves
/// them empty; the first tick after a daemon restart replaces this with a
/// fully-equipped instance via the supervisor's `refresh(...)`.
public struct LaunchAgentInfo: ReconcilableNode {
    public let label: String
    let programArguments: [String]
    let environment: EnvironmentValues

    public var displayName: String { "launchAgent \(label)" }

    public init(label: String) {
        self.label = label
        self.programArguments = []
        self.environment = EnvironmentValues()
    }

    init(label: String, programArguments: [String], environment: EnvironmentValues) {
        self.label = label
        self.programArguments = programArguments
        self.environment = environment
    }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        // Degraded persisted-form: don't write an empty plist. The next tick
        // refreshes the supervisor with the freshly-built node.
        guard !programArguments.isEmpty else { return }

        if let handlers = context.callbacks?.preInstall {
            for handler in handlers { try await handler.handler() }
        }

        let plistPath = "/Library/LaunchAgents/\(label).plist"
        if !FileManager.default.fileExists(atPath: plistPath) {
            let plist = LaunchctlHelper.buildPlist(
                label: label, programArguments: programArguments, environment: environment
            )
            let data = try LaunchctlHelper.serializePlist(plist)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        }

        if environment.launchdActivate {
            await LaunchctlHelper.activateAgentForActiveGUIUsers(label: label, plistPath: plistPath)
        }

        if let handlers = context.callbacks?.postInstall {
            for handler in handlers { await handler.handler() }
        }

        context.payloadStore.set(.launchAgent(label: label), for: identity)
    }

    public func loop(identity: NodeIdentity, context: ReconcileContext) async throws -> LoopOutcome {
        let plistPath = "/Library/LaunchAgents/\(label).plist"
        if !FileManager.default.fileExists(atPath: plistPath) {
            return .drifted(reason: "plist missing")
        }
        if environment.launchdActivate, !LaunchctlHelper.isAgentLoadedForActiveGUIUsers(label: label) {
            return .drifted(reason: "agent not loaded for active GUI users")
        }
        return .healthy
    }

    public func unmount(identity: NodeIdentity, context: ReconcileContext) async throws {
        if let handlers = context.callbacks?.preUninstall {
            for handler in handlers {
                do { try await handler.handler() }
                catch { print("[Astrolabe] preUninstall hook failed for \(identity.path): \(error)") }
            }
        }

        await LaunchctlHelper.deactivateAgentForAllUsers(label: label)
        try? FileManager.default.removeItem(atPath: "/Library/LaunchAgents/\(label).plist")
        context.payloadStore.remove(for: identity)

        if let handlers = context.callbacks?.postUninstall {
            for handler in handlers { await handler.handler() }
        }
    }
}
