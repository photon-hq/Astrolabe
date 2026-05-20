import Foundation

/// Declares a macOS LaunchAgent (per-user service in `/Library/LaunchAgents/`).
///
/// ```swift
/// LaunchAgent("com.example.myagent", program: "/usr/local/bin/myagent")
///     .runAtLoad()
///     .activate()  // bootstraps for the active console user
/// ```
public struct LaunchAgent: Setup, Installable {
    public typealias Body = Never

    public let label: String
    public let programArguments: [String]

    public init(_ label: String, program: String, arguments: [String] = []) {
        self.label = label
        self.programArguments = [program] + arguments
    }
}

extension LaunchAgent: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let identity = NodeIdentity([.named("launchAgent:\(label)")])
        let info = LaunchAgentInfo(
            label: label,
            programArguments: programArguments,
            environment: environment
        )
        return TreeNode(identity: identity, kind: .leaf(info))
    }
}
