/// Declares a macOS LaunchDaemon (system-level service in `/Library/LaunchDaemons/`).
///
/// ```swift
/// LaunchDaemon("com.example.mydaemon", program: "/usr/local/bin/mydaemon")
///     .keepAlive()
///     .activate()
/// ```
public struct LaunchDaemon: Setup {
    public typealias Body = Never

    public let label: String
    public let programArguments: [String]

    public init(_ label: String, program: String, arguments: [String] = []) {
        self.label = label
        self.programArguments = [program] + arguments
    }
}

extension LaunchDaemon: _LeafNode {
    var _reconcilable: (any ReconcilableNode)? {
        LaunchDaemonInfo(label: label, programArguments: programArguments)
    }
}
