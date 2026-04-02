import Foundation

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

extension LaunchDaemon: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let identity = NodeIdentity(path)
        let node = TreeNode(identity: identity, kind: .anchor)

        let label = self.label
        let programArguments = self.programArguments
        let env = environment

        ModifierStore.shared.appendTask(
            TaskModifier {
                var isFirstRun = true
                while !Task.isCancelled {
                    if !isFirstRun {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { break }
                    }
                    isFirstRun = false

                    let plistPath = "/Library/LaunchDaemons/\(label).plist"
                    guard !FileManager.default.fileExists(atPath: plistPath) else { continue }
                    print("[Astrolabe] Bootstrap: \(label) plist not found, reinstalling...")

                    let callbacks = ModifierStore.shared.callbacks(for: identity)
                    let retryConfig = callbacks?.retry
                    let maxAttempts = (retryConfig?.count ?? 0) + 1
                    let retryDelay = retryConfig?.delaySeconds

                    var lastError: (any Error)?
                    for attempt in 1...maxAttempts {
                        do {
                            let plist = LaunchctlHelper.buildPlist(
                                label: label, programArguments: programArguments, environment: env
                            )
                            let data = try LaunchctlHelper.serializePlist(plist)
                            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)

                            if env.launchdActivate {
                                try await LaunchctlHelper.activateDaemon(label: label, plistPath: plistPath)
                            }

                            print("[Astrolabe] Bootstrap: installed LaunchDaemon \(label).")
                            lastError = nil
                            break
                        } catch {
                            lastError = error
                            if attempt < maxAttempts {
                                print("[Astrolabe] Bootstrap install failed (attempt \(attempt)/\(maxAttempts)): \(error)")
                                if let delay = retryDelay {
                                    try? await Task.sleep(for: .seconds(delay))
                                }
                            }
                        }
                    }

                    if let error = lastError {
                        print("[Astrolabe] Bootstrap install failed for \(label): \(error)")
                        if let handlers = callbacks?.onFail {
                            for handler in handlers { await handler.handler(error) }
                        }
                    }
                }
            },
            for: identity
        )

        return node
    }
}
