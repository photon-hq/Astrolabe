import Foundation
import Semaphore
import SystemConfiguration

/// Performs the actual system changes (install, uninstall) for a single node.
///
/// Called by `TaskQueue` from async tasks. Retry logic is owned here —
/// it reads the node's `.retry` modifier and loops internally.
/// Brew operations are serialized — brew cannot run in parallel.
public struct Reconciler: Sendable {
    /// Serializes all brew operations (brew uses internal locks that conflict under parallelism).
    private let brewSemaphore = AsyncSemaphore(value: 1)

    public init() {}

    // MARK: - Install

    public func install(_ node: TreeNode, payloadStore: PayloadStore) async {
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

        await brewSemaphore.wait()
        defer { brewSemaphore.signal() }

        let user = consoleUser()

        // Check if already installed
        let alreadyInstalled: Bool = switch info.type {
        case .formula: commandExists(info.name) || brewInstalled(info.name, flag: "--formula", user: user)
        case .cask: brewInstalled(info.name, flag: "--cask", user: user)
        }
        if alreadyInstalled {
            print("[Astrolabe] \(info.name) already installed, skipping.")
            let record: PayloadRecord = info.type == .cask
                ? .cask(name: info.name) : .formula(name: info.name)
            payloadStore.set(record, for: identity)
            return
        }

        let userDesc = user.map { "as \($0.name)" } ?? "as root"
        switch info.type {
        case .formula:
            print("[Astrolabe] Installing formula \(info.name) \(userDesc)...")
            try await runBrewProcess(["install", info.name], user: user)
            payloadStore.set(.formula(name: info.name), for: identity)
        case .cask:
            print("[Astrolabe] Installing cask \(info.name) \(userDesc)...")
            try await runBrewProcess(["install", "--cask", info.name], user: user)
            payloadStore.set(.cask(name: info.name), for: identity)
        }
        print("[Astrolabe] Installed \(info.name).")
    }

    private func brewInstalled(_ name: String, flag: String, user: ConsoleUser?) -> Bool {
        let process = Process()
        if let user {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-u", user.name, brewPath, "list", flag, name]
        } else {
            process.executableURL = URL(fileURLWithPath: brewPath)
            process.arguments = ["list", flag, name]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func commandExists(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Pkg Install

    private func installPkg(_ info: NodeKind.PkgInfo, identity: NodeIdentity, payloadStore: PayloadStore) async throws {
        switch info.source {
        case .catalog(let item):
            switch item {
            case .homebrew:
                try await CatalogPackage(.homebrew).install()
                payloadStore.set(.catalog(item: "homebrew"), for: identity)
            case .commandLineTools:
                try await CatalogPackage(.commandLineTools).install()
                payloadStore.set(.catalog(item: "commandLineTools"), for: identity)
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
            payloadStore.set(.pkg(id: repo, files: []), for: identity)
            print("[Astrolabe] Installed github \(repo).")

        case .custom(let typeName):
            print("[Astrolabe] Cannot reconcile custom provider \(typeName) from persisted tree.")
        }
    }

    // MARK: - Uninstall

    public func uninstall(_ identity: NodeIdentity, payloadStore: PayloadStore) async {
        guard let record = payloadStore.record(for: identity) else { return }

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
            payloadStore.remove(for: identity)
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
        await brewSemaphore.wait()
        defer { brewSemaphore.signal() }

        var args = ["uninstall"]
        if cask { args.append("--cask") }
        args.append(name)
        try await runBrewProcess(args, user: consoleUser())
    }

    /// Runs a brew command as the console user (brew refuses to run as root).
    private func runBrewProcess(_ arguments: [String], user: ConsoleUser?) async throws {
        if let user {
            try await runProcess("/usr/bin/sudo", arguments: ["-u", user.name, brewPath] + arguments)
        } else {
            try await runProcess(brewPath, arguments: arguments)
        }
    }

    /// Looks up the current console user.
    private func consoleUser() -> ConsoleUser? {
        var uid: uid_t = 0
        guard let username = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String,
              uid != 0,
              username != "loginwindow"
        else {
            return nil
        }
        return ConsoleUser(name: username, uid: uid)
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
