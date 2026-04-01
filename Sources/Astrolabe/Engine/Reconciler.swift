import Foundation

/// Reconciles a single declaration node against reality.
///
/// Given a diff action, performs the actual system change (install, uninstall)
/// and updates the payload store.
public struct Reconciler: Sendable {
    public init() {}

    /// Reconciles a single diff action.
    public func reconcile(_ action: DiffAction, payloadStore: PayloadStore) async {
        switch action {
        case .install(let node):
            await install(node, payloadStore: payloadStore)
        case .uninstall(let identity):
            await uninstall(identity, payloadStore: payloadStore)
        case .unchanged:
            break
        }
    }

    // MARK: - Install

    private func install(_ node: TreeNode, payloadStore: PayloadStore) async {
        let retryConfig = node.modifiers.compactMap { modifier -> (Int, Double?)? in
            if case .retry(let count, let delay) = modifier {
                return (count, delay)
            }
            return nil
        }.first

        let maxAttempts = (retryConfig?.0 ?? 0) + 1
        let retryDelay = retryConfig?.1

        for attempt in 1...maxAttempts {
            do {
                try await performInstall(node, payloadStore: payloadStore)
                return
            } catch {
                let desc = describe(node.kind)
                if attempt < maxAttempts {
                    print("[Astrolabe] Install failed for \(desc) (attempt \(attempt)/\(maxAttempts)): \(error)")
                    if let delay = retryDelay {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                } else {
                    print("[Astrolabe] Install failed for \(desc): \(error)")
                }
            }
        }
    }

    private func performInstall(_ node: TreeNode, payloadStore: PayloadStore) async throws {
        switch node.kind {
        case .brew(let info):
            try await installBrew(info, identity: node.identity, payloadStore: payloadStore)
        case .pkg(let info):
            try await installPkg(info, identity: node.identity, payloadStore: payloadStore)
        default:
            break
        }
    }

    // MARK: - Brew Install

    private func installBrew(_ info: NodeKind.BrewInfo, identity: NodeIdentity, payloadStore: PayloadStore) async throws {
        try await CatalogPackage(.homebrew).install()
        switch info.type {
        case .formula:
            print("[Astrolabe] Installing formula \(info.name)...")
            try await runProcess(brewPath, arguments: ["install", info.name])
            await payloadStore.set(.formula(name: info.name), for: identity)
        case .cask:
            print("[Astrolabe] Installing cask \(info.name)...")
            try await runProcess(brewPath, arguments: ["install", "--cask", info.name])
            await payloadStore.set(.cask(name: info.name), for: identity)
        }
        print("[Astrolabe] Installed \(info.name).")
    }

    // MARK: - Pkg Install

    private func installPkg(_ info: NodeKind.PkgInfo, identity: NodeIdentity, payloadStore: PayloadStore) async throws {
        switch info.source {
        case .catalog(let item):
            switch item {
            case .homebrew:
                try await CatalogPackage(.homebrew).install()
                await payloadStore.set(.catalog(item: "homebrew"), for: identity)
            case .commandLineTools:
                try await CatalogPackage(.commandLineTools).install()
                await payloadStore.set(.catalog(item: "commandLineTools"), for: identity)
            }
            print("[Astrolabe] Installed catalog \(item).")

        case .gitHub(let repo, let version, let asset):
            let ghVersion: GitHubPackage.Version = switch version {
            case .latest: .latest
            case .tag(let t): .tag(t)
            }
            let ghAsset: GitHubPackage.AssetFilter = switch asset {
            case .pkg: .pkg
            case .filename(let f): .filename(f)
            case .regex(let r): .regex(r)
            }
            let gh = GitHubPackage(repo: repo, version: ghVersion, asset: ghAsset)
            try await gh.install()
            await payloadStore.set(.pkg(id: repo, files: []), for: identity)
            print("[Astrolabe] Installed github \(repo).")

        case .custom(let typeName):
            print("[Astrolabe] Cannot reconcile custom provider \(typeName) from persisted tree.")
        }
    }

    // MARK: - Uninstall

    private func uninstall(_ identity: NodeIdentity, payloadStore: PayloadStore) async {
        guard let record = await payloadStore.record(for: identity) else { return }

        do {
            switch record {
            case .formula(let name):
                try await uninstallBrew(name, cask: false)
            case .cask(let name):
                try await uninstallBrew(name, cask: true)
            case .pkg(let id, let files):
                try await uninstallPkg(id: id, files: files)
            case .catalog:
                break
            }
            await payloadStore.remove(for: identity)
            print("[Astrolabe] Uninstalled payload for \(identity.path).")
        } catch {
            print("[Astrolabe] Uninstall failed for \(identity.path): \(error)")
        }
    }

    // MARK: - Brew Helpers

    private var brewPath: String {
        #if arch(arm64)
        "/opt/homebrew/bin/brew"
        #else
        "/usr/local/bin/brew"
        #endif
    }

    private func uninstallBrew(_ name: String, cask: Bool) async throws {
        var args = ["uninstall"]
        if cask { args.append("--cask") }
        args.append(name)
        try await runProcess(brewPath, arguments: args)
    }

    // MARK: - .pkg Helpers

    private func uninstallPkg(id: String, files: [String]) async throws {
        for file in files {
            try? FileManager.default.removeItem(atPath: file)
        }
        try await runProcess("/usr/sbin/pkgutil", arguments: ["--forget", id])
    }

    // MARK: - Helpers

    private func runProcess(_ path: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ReconcileError.processFailed(path: path, arguments: arguments, output: output)
        }
    }

    private func describe(_ kind: NodeKind) -> String {
        switch kind {
        case .brew(let info): "brew \(info.name)"
        case .pkg(let info):
            switch info.source {
            case .catalog(let i): "catalog \(i)"
            case .gitHub(let r, _, _): "github \(r)"
            case .custom(let t): "custom \(t)"
            }
        default: "unknown"
        }
    }
}

public enum ReconcileError: Error, Sendable {
    case processFailed(path: String, arguments: [String], output: String)
}
