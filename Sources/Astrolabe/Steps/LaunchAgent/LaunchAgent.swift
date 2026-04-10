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
        let node = TreeNode(identity: identity, kind: .leaf(LaunchAgentInfo(label: label)))

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
                    let wasFirstRun = isFirstRun
                    isFirstRun = false
                    defer {
                        if wasFirstRun { PriorityGate.shared.markReady(identity) }
                    }

                    let plistPath = "/Library/LaunchAgents/\(label).plist"
                    let plistMissing = !FileManager.default.fileExists(atPath: plistPath)
                    let needsActivation = env.launchdActivate && !LaunchctlHelper.isAgentLoadedForActiveGUIUsers(label: label)

                    guard plistMissing || needsActivation else { continue }

                    if plistMissing {
                        print("[Astrolabe] Bootstrap: \(label) plist not found, reinstalling...")
                    } else {
                        print("[Astrolabe] Bootstrap: \(label) not running for active GUI user(s), reactivating...")
                    }

                    let callbacks = ModifierStore.shared.callbacks(for: identity)
                    let retryConfig = callbacks?.retry
                    let maxAttempts = (retryConfig?.count ?? 0) + 1
                    let retryDelay = retryConfig?.delaySeconds

                    var lastError: (any Error)?
                    for attempt in 1...maxAttempts {
                        do {
                            if let handlers = callbacks?.preInstall {
                                for handler in handlers { try await handler.handler() }
                            }

                            if plistMissing {
                                let plist = LaunchctlHelper.buildPlist(
                                    label: label, programArguments: programArguments, environment: env
                                )
                                let data = try LaunchctlHelper.serializePlist(plist)
                                try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
                            }

                            if env.launchdActivate {
                                await LaunchctlHelper.activateAgentForActiveGUIUsers(label: label, plistPath: plistPath)
                            }

                            if let handlers = callbacks?.postInstall {
                                for handler in handlers { await handler.handler() }
                            }

                            print("[Astrolabe] Bootstrap: LaunchAgent \(label) OK.")
                            PayloadStore.shared.set(.launchAgent(label: label), for: identity)
                            lastError = nil
                            break
                        } catch {
                            lastError = error
                            if attempt < maxAttempts {
                                print("[Astrolabe] Bootstrap failed (attempt \(attempt)/\(maxAttempts)): \(error)")
                                if let delay = retryDelay {
                                    try? await Task.sleep(for: .seconds(delay))
                                }
                            }
                        }
                    }

                    if let error = lastError {
                        print("[Astrolabe] Bootstrap failed for \(label): \(error)")
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
