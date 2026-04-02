import Foundation

/// Reconciliation logic for `LaunchDaemon`.
public struct LaunchDaemonInfo: ReconcilableNode {
    public let label: String
    public let programArguments: [String]

    public var displayName: String { "launchd daemon \(label)" }

    public func mount(identity: NodeIdentity, context: ReconcileContext) async throws {
        let plistPath = "/Library/LaunchDaemons/\(label).plist"

        // Build and write plist
        let env = EnvironmentValues.current
        let plist = LaunchctlHelper.buildPlist(label: label, programArguments: programArguments, environment: env)
        let data = try LaunchctlHelper.serializePlist(plist)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)

        // Activate if requested: bootout → enable → bootstrap
        if env.launchdActivate {
            try await LaunchctlHelper.activateDaemon(label: label, plistPath: plistPath)
        }

        context.payloadStore.set(.launchDaemon(label: label), for: identity)
        print("[Astrolabe] Mounted LaunchDaemon \(label).")
    }
}
