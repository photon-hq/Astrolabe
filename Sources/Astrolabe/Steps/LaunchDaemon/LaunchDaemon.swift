import Foundation

/// Declares a macOS LaunchDaemon (system-level service in `/Library/LaunchDaemons/`).
///
/// ```swift
/// LaunchDaemon("com.example.mydaemon", program: "/usr/local/bin/mydaemon")
///     .keepAlive()
///     .activate()
/// ```
public struct LaunchDaemon: Setup, Installable {
    public typealias Body = Never

    public let label: String
    public let programArguments: [String]

    public init(_ label: String, program: String, arguments: [String] = []) {
        self.label = label
        self.programArguments = [program] + arguments
    }
}

extension LaunchDaemon: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let identity = NodeIdentity([.named("launchDaemon:\(label)")])
        let info = LaunchDaemonInfo(
            label: label,
            programArguments: programArguments,
            environment: environment
        )
        return TreeNode(identity: identity, kind: .leaf(info))
    }
}
