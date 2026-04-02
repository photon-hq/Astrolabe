/// Declares that a Homebrew package should be installed.
///
/// ```swift
/// Brew("wget")
/// Brew("firefox", type: .cask)
/// ```
public struct Brew: Setup {
    public typealias Body = Never

    public enum PackageType: Sendable, Equatable {
        case formula
        case cask
    }

    public let name: String
    public let type: PackageType

    public init(_ name: String, type: PackageType = .formula) {
        self.name = name
        self.type = type
    }
}

extension Brew: Installable {}

extension Brew: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let identity = NodeIdentity(path)
        let node = TreeNode(identity: identity, kind: .anchor)

        let name = self.name
        let type = self.type

        ModifierStore.shared.appendTask(
            TaskModifier {
                var isFirstRun = true
                while !Task.isCancelled {
                    if !isFirstRun {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { break }
                    }
                    isFirstRun = false

                    // Fast PATH check for formulas
                    if type == .formula, ProcessRunner.commandExists(name) { continue }
                    // Full brew list check
                    let flag = type == .cask ? "--cask" : "--formula"
                    let user = BrewHelper.consoleUser()
                    if BrewHelper.isInstalled(name, flag: flag, user: user) { continue }

                    print("[Astrolabe] Bootstrap: brew \(name) not installed, reinstalling...")

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
                            try await CatalogPackage(.homebrew).install()
                            try await BrewHelper.installIfNeeded(name, type: type, user: BrewHelper.consoleUser())
                            if let handlers = callbacks?.postInstall {
                                for handler in handlers { await handler.handler() }
                            }
                            let record: PayloadRecord = type == .cask ? .cask(name: name) : .formula(name: name)
                            PayloadStore.shared.set(record, for: identity)
                            print("[Astrolabe] Bootstrap: brew \(name) OK.")
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
                        print("[Astrolabe] Bootstrap install failed for brew \(name): \(error)")
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
