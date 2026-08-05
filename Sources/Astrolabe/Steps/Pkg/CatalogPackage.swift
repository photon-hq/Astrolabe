import Foundation
import Semaphore

/// Installs a well-known macOS package from the Astrolabe catalog.
///
/// ```swift
/// PackageInstaller(.catalog(.homebrew))
/// PackageInstaller(.catalog(.commandLineTools))
/// ```
public struct CatalogPackage: PackageProvider {
    /// A predefined package in the Astrolabe catalog.
    public enum Item: Sendable, Equatable {
        /// The Homebrew package manager. Automatically installs Xcode Command Line Tools first.
        case homebrew
        /// Xcode Command Line Tools, installed via `softwareupdate`.
        case commandLineTools
    }

    private static let homebrewLock = AsyncSemaphore(value: 1)
    private static let cltLock = AsyncSemaphore(value: 1)

    public let item: Item

    public var id: String {
        switch item {
        case .homebrew: "catalog:homebrew"
        case .commandLineTools: "catalog:commandLineTools"
        }
    }

    public init(_ item: Item) {
        self.item = item
    }

    public func install() async throws {
        switch item {
        case .homebrew:
            try await installHomebrew()
        case .commandLineTools:
            try await installCommandLineTools()
        }
    }

    public func isInstalled() async -> Bool {
        switch item {
        case .homebrew: homebrewInstalled()
        case .commandLineTools: await commandLineToolsInstalled()
        }
    }

    public var payloadRecord: PayloadRecord? {
        switch item {
        case .homebrew: .catalog(item: "homebrew")
        case .commandLineTools: .catalog(item: "commandLineTools")
        }
    }
}

// MARK: - Homebrew

extension CatalogPackage {
    private func installHomebrew() async throws {
        await Self.homebrewLock.wait()
        defer { Self.homebrewLock.signal() }

        try await installCommandLineTools()

        if homebrewInstalled() {
            print("[Astrolabe] Homebrew already installed.")
            return
        }

        print("[Astrolabe] Installing Homebrew...")
        let github = GitHubPackage(repo: "Homebrew/brew")
        try await github.install()
    }

    private func homebrewInstalled() -> Bool {
        #if arch(arm64)
        let brewPath = "/opt/homebrew/bin/brew"
        #else
        let brewPath = "/usr/local/bin/brew"
        #endif
        return FileManager.default.fileExists(atPath: brewPath)
    }
}

// MARK: - Command Line Tools

extension CatalogPackage {
    private func installCommandLineTools() async throws {
        await Self.cltLock.wait()
        defer { Self.cltLock.signal() }

        if await commandLineToolsInstalled() {
            print("[Astrolabe] Xcode Command Line Tools already installed.")
            return
        }

        print("[Astrolabe] Installing Xcode Command Line Tools...")

        let triggerFile = "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
        FileManager.default.createFile(atPath: triggerFile, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: triggerFile) }

        let productName = try await findCommandLineToolsProduct()
        try await installSoftwareUpdate(productName)

        print("[Astrolabe] Xcode Command Line Tools installed successfully.")
    }

    private func commandLineToolsInstalled() async -> Bool {
        let result = try? await ProcessRunner.capture("/usr/bin/xcode-select", arguments: ["-p"])
        return result?.isSuccess ?? false
    }

    private func findCommandLineToolsProduct() async throws -> String {
        // `softwareupdate -l` puts its listing on stderr on several macOS versions, which is
        // why the old code merged the pipes. Keep reading the merged view, and keep ignoring
        // the exit status — the parse result is the authority on whether a product was found.
        let output = try await ProcessRunner.capture(
            "/usr/sbin/softwareupdate",
            arguments: ["-l"],
            timeout: ProcessRunner.Timeout.install
        ).combined

        guard let product = output
            .components(separatedBy: "\n")
            .compactMap({ line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("* Label: ") {
                    let name = String(trimmed.dropFirst("* Label: ".count))
                    if name.contains("Command Line Tools") { return name }
                } else if trimmed.hasPrefix("* ") {
                    let name = String(trimmed.dropFirst("* ".count))
                    if name.contains("Command Line Tools") { return name }
                }
                return nil
            })
            .last
        else {
            throw CatalogError.productNotFound("Command Line Tools")
        }

        return product
    }

    private func installSoftwareUpdate(_ productName: String) async throws {
        // `--verbose` is exactly the case that deadlocked the old drain-after-wait code:
        // stream it, and echo progress rather than going silent for several minutes.
        do {
            try await ProcessRunner.stream(
                "/usr/sbin/softwareupdate",
                arguments: ["-i", productName, "--agree-to-license", "--verbose"]
            ) { line in
                print("[Astrolabe] softwareupdate: \(line)")
            }
        } catch let error as ReconcileError {
            guard case .processFailed(_, _, let output) = error else { throw error }
            throw CatalogError.installFailed(item: .commandLineTools, output: output)
        }
    }
}

// MARK: - Errors

public enum CatalogError: Error, Sendable {
    /// The software update product could not be found in `softwareupdate -l` output.
    case productNotFound(String)
    /// Installation of a catalog item failed.
    case installFailed(item: CatalogPackage.Item, output: String)
}

// MARK: - Dot Syntax

extension PackageProvider where Self == CatalogPackage {
    /// A well-known package from the Astrolabe catalog.
    public static func catalog(_ item: CatalogPackage.Item) -> CatalogPackage {
        CatalogPackage(item)
    }
}

