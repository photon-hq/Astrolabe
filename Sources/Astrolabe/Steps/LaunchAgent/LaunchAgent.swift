/// Declares a macOS LaunchAgent (per-user service in `/Library/LaunchAgents/`).
///
/// ```swift
/// LaunchAgent("com.example.myagent", program: "/usr/local/bin/myagent")
///     .runAtLoad()
///     .activate()  // bootstraps for every logged-in user
/// ```
public struct LaunchAgent: Setup {
    public typealias Body = Never

    public let label: String
    public let programArguments: [String]

    public init(_ label: String, program: String, arguments: [String] = []) {
        self.label = label
        self.programArguments = [program] + arguments
    }
}

extension LaunchAgent: _LeafNode {
    var _reconcilable: (any ReconcilableNode)? {
        LaunchAgentInfo(label: label, programArguments: programArguments)
    }
}
