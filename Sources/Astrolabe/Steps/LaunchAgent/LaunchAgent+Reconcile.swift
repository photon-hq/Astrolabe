import Foundation

/// Reconciliation logic for `LaunchAgent`.
public struct LaunchAgentInfo: ReconcilableNode {
    public let label: String
    public let programArguments: [String]

    public var displayName: String { "launchd agent \(label)" }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        let plistPath = "/Library/LaunchAgents/\(label).plist"

        // Build and write plist
        let env = EnvironmentValues.current
        let plist = LaunchctlHelper.buildPlist(label: label, programArguments: programArguments, environment: env)
        let data = try LaunchctlHelper.serializePlist(plist)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)

        // Activate if requested: bootstrap for every logged-in user
        if env.launchdActivate {
            await LaunchctlHelper.activateAgentForAllUsers(label: label, plistPath: plistPath)
        }

        context.payloadStore.set(.launchAgent(label: label), for: identity)
        print("[Astrolabe] Mounted LaunchAgent \(label).")
    }
}
