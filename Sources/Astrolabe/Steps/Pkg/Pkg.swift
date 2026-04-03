/// A provider that knows how to install a package.
///
/// Conform to this protocol to add custom package sources:
///
/// ```swift
/// struct MyProvider: PackageProvider {
///     func install() async throws {
///         // custom installation logic
///     }
/// }
///
/// Pkg(MyProvider())
/// ```
public protocol PackageProvider: Sendable {
    /// Stable identity for this provider (used as the node's content-based identity).
    var id: String { get }
    /// Installs the package.
    func install() async throws
    /// Returns whether the package is currently installed.
    func isInstalled() async -> Bool
    /// The payload record to store for unmount cleanup. Return `nil` to skip.
    var payloadRecord: PayloadRecord? { get }
}

extension PackageProvider {
    public var id: String { String(describing: type(of: self)) }
    public func isInstalled() async -> Bool { true }
    public var payloadRecord: PayloadRecord? { nil }
}

/// Declares that a package should be installed via a `PackageProvider`.
///
/// `Pkg` is a leaf declaration — it has no body. The framework reconciles it
/// by calling the provider's `install()` method.
///
/// ```swift
/// Pkg(.catalog(.homebrew))
/// Pkg(.catalog(.commandLineTools))
/// Pkg(.gitHub("org/tool"))
/// Pkg(.gitHub("org/tool", version: .tag("v2.0")))
/// Pkg(MyCustomProvider())
/// ```
public struct Pkg<Provider: PackageProvider>: Setup {
    public typealias Body = Never

    public let provider: Provider

    public init(_ provider: Provider) {
        self.provider = provider
    }
}

extension Pkg: Installable {}

extension Pkg: _TreeExpandable {
    func _buildTree(path: [PathComponent], environment: EnvironmentValues) -> TreeNode {
        let identity = NodeIdentity([.named("pkg:\(provider.id)")])
        let node = TreeNode(identity: identity, kind: .leaf(PkgInfo(providerDescription: provider.id)))

        let provider = self.provider
        ModifierStore.shared.appendTask(
            TaskModifier {
                var isFirstRun = true
                while !Task.isCancelled {
                    if !isFirstRun {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { break }
                    }
                    isFirstRun = false

                    guard await !provider.isInstalled() else { continue }
                    print("[Astrolabe] Bootstrap: \(identity.path) not installed, reinstalling...")

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
                            try await provider.install()
                            if let handlers = callbacks?.postInstall {
                                for handler in handlers { await handler.handler() }
                            }
                            if let record = provider.payloadRecord {
                                PayloadStore.shared.set(record, for: identity)
                            }
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
                        print("[Astrolabe] Bootstrap install failed: \(error)")
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
