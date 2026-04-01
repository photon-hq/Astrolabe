import Foundation

/// Installs a Homebrew package.
///
/// ```swift
/// Brew("wget")
/// Brew("firefox", type: .cask)
/// ```
public struct Brew: Setup {
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

    public func execute() async throws {
        try await CatalogPackage(.homebrew).install()

        let brewPath = brewExecutable()

        print("[Astrolabe] Installing \(name) (\(type))...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = arguments()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BrewError.installFailed(package: name, output: output)
        }

        print("[Astrolabe] Installed \(name).")
    }

    private func arguments() -> [String] {
        switch type {
        case .formula:
            ["install", name]
        case .cask:
            ["install", "--cask", name]
        }
    }

    private func brewExecutable() -> String {
        #if arch(arm64)
        "/opt/homebrew/bin/brew"
        #else
        "/usr/local/bin/brew"
        #endif
    }
}

public enum BrewError: Error, Sendable {
    case installFailed(package: String, output: String)
}
