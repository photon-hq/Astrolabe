import Foundation

/// Configures macOS power management settings via `pmset`.
///
/// ```swift
/// Sys(.pmset(.displaysleep(15), .sleep(0), on: .charger))
/// ```
public struct PmsetSetting: SystemSetting {
    public let settings: [PMSetting]
    public let source: PowerSource

    public init(_ settings: [PMSetting], on source: PowerSource = .all) {
        self.settings = settings
        self.source = source
    }

    // MARK: - SystemSetting

    public func check() async throws -> Bool {
        let output = try await captureOutput("/usr/bin/pmset", ["-g", "custom"])
        let sections = Self.parseSections(output)

        let targetSections: [String: [String: Int]]
        switch source {
        case .all:
            targetSections = sections
        case .battery:
            targetSections = sections.filter { $0.key == "Battery Power" }
        case .charger:
            targetSections = sections.filter { $0.key == "AC Power" }
        case .ups:
            targetSections = sections.filter { $0.key == "UPS Power" }
        }

        // No matching sections (e.g., desktop has no battery) — nothing to check.
        guard !targetSections.isEmpty else { return true }

        for (_, sectionValues) in targetSections {
            for setting in settings {
                guard let current = sectionValues[setting.key] else {
                    return false
                }
                if current != setting.intValue {
                    return false
                }
            }
        }
        return true
    }

    public func apply() async throws {
        var arguments = [source.rawValue]
        for setting in settings {
            arguments.append(setting.key)
            arguments.append(String(setting.intValue))
        }
        try await run("/usr/bin/pmset", arguments)
    }

    // MARK: - Parsing

    /// Parses `pmset -g custom` output into per-source sections.
    static func parseSections(_ output: String) -> [String: [String: Int]] {
        var sections: [String: [String: Int]] = [:]
        var currentSection: String?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") {
                currentSection = String(trimmed.dropLast())
                sections[currentSection!] = [:]
            } else if let section = currentSection {
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, let value = Int(parts[parts.count - 1]) {
                    sections[section]?[String(parts[0])] = value
                }
            }
        }
        return sections
    }

    // MARK: - Process Helpers

    private func run(_ path: String, _ arguments: [String]) async throws {
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

    private func captureOutput(_ path: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReconcileError.processFailed(path: path, arguments: arguments, output: "")
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - PowerSource

extension PmsetSetting {
    /// The power source a `pmset` setting applies to.
    public enum PowerSource: String, Sendable, Equatable {
        /// All power sources (`-a`).
        case all = "-a"
        /// Battery power (`-b`).
        case battery = "-b"
        /// AC / charger power (`-c`).
        case charger = "-c"
        /// UPS power (`-u`).
        case ups = "-u"
    }
}

// MARK: - PMSetting

extension PmsetSetting {
    /// An individual power management setting.
    public enum PMSetting: Sendable, Equatable {
        // Timer settings (minutes, 0 = never)

        /// Minutes before the display sleeps (0 = never).
        case displaysleep(Int)
        /// Minutes before the disk sleeps (0 = never).
        case disksleep(Int)
        /// Minutes before the system sleeps (0 = never).
        case sleep(Int)

        // Boolean toggles

        /// Wake on Magic Packet (Wake-on-LAN).
        case womp(Bool)
        /// Power Nap.
        case powernap(Bool)
        /// Wake for network proximity.
        case proximitywake(Bool)
        /// Automatically restart after power loss.
        case autorestart(Bool)
        /// Wake when the lid is opened.
        case lidwake(Bool)
        /// Wake when AC power is connected.
        case acwake(Bool)
        /// Slightly dim the display on battery.
        case lessbright(Bool)
        /// Dim the display before sleep.
        case halfdim(Bool)
        /// Keep TCP connections alive during sleep.
        case tcpkeepalive(Bool)
        /// Prevent sleep while a TTY session is active.
        case ttyskeepawake(Bool)
        /// Enable standby mode.
        case standby(Bool)
        /// Enable auto power off.
        case autopoweroff(Bool)

        // Special

        /// Hibernate mode.
        case hibernatemode(HibernateMode)
        /// Seconds before entering standby.
        case standbydelay(Int)
        /// Seconds before auto power off.
        case autopoweroffdelay(Int)
        /// Battery percentage threshold for high standby.
        case highstandbythreshold(Int)
    }

    /// macOS hibernate mode.
    public enum HibernateMode: Int, Sendable, Equatable {
        /// No hibernation (RAM only).
        case off = 0
        /// Safe sleep — write RAM to disk, keep RAM powered (default for desktops).
        case standard = 3
        /// Full hibernate — write RAM to disk, power off RAM (default for portables).
        case full = 25
    }
}

// MARK: - PMSetting Key / Value

extension PmsetSetting.PMSetting {
    /// The key name used by `pmset`.
    var key: String {
        switch self {
        case .displaysleep: "displaysleep"
        case .disksleep:    "disksleep"
        case .sleep:        "sleep"
        case .womp:         "womp"
        case .powernap:     "powernap"
        case .proximitywake: "proximitywake"
        case .autorestart:  "autorestart"
        case .lidwake:      "lidwake"
        case .acwake:       "acwake"
        case .lessbright:   "lessbright"
        case .halfdim:      "halfdim"
        case .tcpkeepalive: "tcpkeepalive"
        case .ttyskeepawake: "ttyskeepawake"
        case .standby:      "standby"
        case .autopoweroff: "autopoweroff"
        case .hibernatemode: "hibernatemode"
        case .standbydelay: "standbydelay"
        case .autopoweroffdelay: "autopoweroffdelay"
        case .highstandbythreshold: "highstandbythreshold"
        }
    }

    /// The integer value to pass to `pmset`.
    var intValue: Int {
        switch self {
        case .displaysleep(let v), .disksleep(let v), .sleep(let v):
            v
        case .womp(let b), .powernap(let b), .proximitywake(let b),
             .autorestart(let b), .lidwake(let b), .acwake(let b),
             .lessbright(let b), .halfdim(let b), .tcpkeepalive(let b),
             .ttyskeepawake(let b), .standby(let b), .autopoweroff(let b):
            b ? 1 : 0
        case .hibernatemode(let mode):
            mode.rawValue
        case .standbydelay(let v), .autopoweroffdelay(let v),
             .highstandbythreshold(let v):
            v
        }
    }

    /// Reconstructs a `PMSetting` from a key name and integer value.
    static func from(key: String, value: Int) -> PmsetSetting.PMSetting? {
        switch key {
        case "displaysleep": .displaysleep(value)
        case "disksleep":    .disksleep(value)
        case "sleep":        .sleep(value)
        case "womp":         .womp(value != 0)
        case "powernap":     .powernap(value != 0)
        case "proximitywake": .proximitywake(value != 0)
        case "autorestart":  .autorestart(value != 0)
        case "lidwake":      .lidwake(value != 0)
        case "acwake":       .acwake(value != 0)
        case "lessbright":   .lessbright(value != 0)
        case "halfdim":      .halfdim(value != 0)
        case "tcpkeepalive": .tcpkeepalive(value != 0)
        case "ttyskeepawake": .ttyskeepawake(value != 0)
        case "standby":      .standby(value != 0)
        case "autopoweroff": .autopoweroff(value != 0)
        case "hibernatemode": PmsetSetting.HibernateMode(rawValue: value).map { .hibernatemode($0) }
        case "standbydelay": .standbydelay(value)
        case "autopoweroffdelay": .autopoweroffdelay(value)
        case "highstandbythreshold": .highstandbythreshold(value)
        default: nil
        }
    }
}

// MARK: - Static Factory

extension SystemSetting where Self == PmsetSetting {
    /// Configures macOS power management settings.
    ///
    /// ```swift
    /// Sys(.pmset(.displaysleep(15), .sleep(0)))
    /// Sys(.pmset(.displaysleep(5), on: .battery))
    /// ```
    public static func pmset(
        _ settings: PmsetSetting.PMSetting...,
        on source: PmsetSetting.PowerSource = .all
    ) -> PmsetSetting {
        PmsetSetting(settings, on: source)
    }
}
