import Foundation

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

    public let item: Item

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
}

// MARK: - Homebrew

extension CatalogPackage {
    private func installHomebrew() async throws {
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
        if commandLineToolsInstalled() {
            print("[Astrolabe] Xcode Command Line Tools already installed.")
            return
        }

        print("[Astrolabe] Installing Xcode Command Line Tools...")

        let triggerFile = "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
        FileManager.default.createFile(atPath: triggerFile, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: triggerFile) }

        let productName = try findCommandLineToolsProduct()
        try installSoftwareUpdate(productName)

        print("[Astrolabe] Xcode Command Line Tools installed successfully.")
    }

    private func commandLineToolsInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func findCommandLineToolsProduct() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        process.arguments = ["-l"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

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

    private func installSoftwareUpdate(_ productName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        process.arguments = ["-i", productName, "--agree-to-license", "--verbose"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
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

