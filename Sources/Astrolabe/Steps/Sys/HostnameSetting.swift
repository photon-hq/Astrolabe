import Foundation
import SystemConfiguration
import os

/// Sets the Mac's hostname (ComputerName, HostName, and LocalHostName).
///
/// ```swift
/// Sys(.hostname("dev-mac"))
/// ```
///
/// - Note: This writes `ComputerName`, which `Jamf(.computerName(_:))` also
///   owns (with tolerant `contains` matching). Declaring both for the same Mac
///   means two independent loops drive `ComputerName` — avoid, or expect them
///   to take turns. Reconciling ownership is tracked as a separate follow-up.
public struct HostnameSetting: SystemSetting {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    /// Names currently in an unwinnable *live* collision — a peer on the network
    /// keeps reclaiming the name, so `apply()` can't make it stick. Latched by
    /// `apply()` once a write bounces back to a suffix, and read by `check()`,
    /// which then accepts the suffixed state as converged so the loop stops
    /// re-mounting and re-applying (and re-logging) every tick. Process-wide
    /// because the setting struct is rebuilt fresh each tick; cleared once a
    /// write sticks. Not persisted — a fresh process re-probes (the peer may be
    /// gone by then).
    private static let liveCollisions = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Verifies all three name facets `apply()` writes — checking only `HostName`
    /// (as before) left `LocalHostName`/`ComputerName` drift, e.g. Bonjour
    /// collision suffixes like "host-2" / "host (4)", silently unremediated.
    ///
    /// `ComputerName`/`LocalHostName` are read natively from the dynamic store
    /// (`SCDynamicStoreCopy*`) — the same source `scutil --get` reads, but live
    /// and subprocess-free; `nil` (unset) reads cleanly as drifted. `HostName`
    /// has no dynamic-store accessor, so it stays on `scutil`.
    ///
    /// A collision suffix normally counts as drift, so `apply()` runs and cleans
    /// a *stale* suffix. But once `apply()` has confirmed the suffix is a *live*
    /// collision it can't win (latched in `liveCollisions`), the suffixed state
    /// is accepted as converged — otherwise the loop would re-mount and re-apply
    /// forever against an unachievable target.
    public func check() async throws -> Bool {
        let live = Self.liveCollisions.withLock { $0.contains(name) }
        guard facetConverged(SCDynamicStoreCopyComputerName(nil, nil) as String?, .computerName, live: live)
        else { return false }
        guard facetConverged(SCDynamicStoreCopyLocalHostName(nil) as String?, .localHostName, live: live)
        else { return false }

        // `scutil --get HostName` exits non-zero ("HostName: not set") when the
        // key is unset; treat that as drifted so apply() runs. (ProcessInfo's
        // hostName is cached at process start, so it can't be used here — it
        // would never observe a successful apply() and we'd remediate forever.)
        // HostName is never Bonjour-suffixed, so it's always an exact match.
        let result = try await capture("/usr/sbin/scutil", ["--get", "HostName"])
        guard result.status == 0 else { return false }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == name
    }

    /// Whether an observed Bonjour-managed facet value counts as converged. A
    /// collision suffix is tolerated only when `live` — i.e. `apply()` has already
    /// confirmed and latched an unwinnable collision; otherwise it's drift.
    func facetConverged(_ observed: String?, _ facet: Facet, live: Bool) -> Bool {
        switch HostnameSetting.classify(observed: observed, desired: name, facet: facet) {
        case .matches: return true
        case .collisionSuffix: return live
        case .wrong: return false
        }
    }

    public func apply() async throws {
        try await run("/usr/sbin/scutil", ["--set", "ComputerName", name])
        try await run("/usr/sbin/scutil", ["--set", "HostName", name])
        try await run("/usr/sbin/scutil", ["--set", "LocalHostName", name])

        // Re-read the two Bonjour-managed facets right after writing. A *stale*
        // collision suffix is gone now that we've written the bare name; a suffix
        // still present means a live peer on the network is reclaiming the name.
        let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let localHostName = SCDynamicStoreCopyLocalHostName(nil) as String?
        let collided = Self.classify(observed: computerName, desired: name, facet: .computerName) == .collisionSuffix
            || Self.classify(observed: localHostName, desired: name, facet: .localHostName) == .collisionSuffix

        if collided {
            // Latch so check() accepts this state as converged and stops the loop
            // re-mounting/re-applying every tick. Warn only on the transition into
            // collision, not on every attempt. (If Bonjour re-suffixes slower than
            // this read we miss the bounce here, don't latch, and re-mount once
            // more next tick — it latches within a tick or two.)
            let newlyLatched = Self.liveCollisions.withLock { $0.insert(name).inserted }
            if newlyLatched {
                print("[Astrolabe] hostname '\(name)': name collision on the network "
                    + "(ComputerName=\(computerName ?? "nil"), LocalHostName=\(localHostName ?? "nil")). "
                    + "Another device is advertising '\(name)'. Manual intervention required.")
            }
        } else {
            // Write stuck (or a stale suffix was just cleaned) — clear any latch
            // so a fresh collision episode warns again.
            Self.liveCollisions.withLock { _ = $0.remove(name) }
        }
    }

    private func run(_ path: String, _ arguments: [String]) async throws {
        let result = try await capture(path, arguments)
        guard result.status == 0 else {
            throw ReconcileError.processFailed(path: path, arguments: arguments, output: result.output)
        }
    }

    private func capture(_ path: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}

// MARK: - Facet classification (pure, unit-tested)

extension HostnameSetting {
    /// One of the three name facets the setting writes.
    enum Facet: Sendable { case computerName, localHostName, hostName }

    /// How an observed facet value relates to the desired bare `name`.
    enum FacetState: Equatable, Sendable {
        /// Exactly the desired name — converged.
        case matches
        /// The desired name plus a Bonjour collision suffix (`name-N` for
        /// LocalHostName, `name (N)` for ComputerName). Indicates a network
        /// name conflict, not arbitrary drift.
        case collisionSuffix
        /// Unset, or an unrelated value.
        case wrong
    }

    /// Pure classifier over plain values — the unit-test seam (no system access).
    ///
    /// macOS appends a collision suffix when another device advertises the same
    /// name: `-N` to LocalHostName, ` (N)` to ComputerName. HostName is never
    /// Bonjour-managed, so only an exact match is ever valid for it.
    static func classify(observed: String?, desired: String, facet: Facet) -> FacetState {
        guard let observed else { return .wrong }
        if observed == desired { return .matches }
        switch facet {
        case .localHostName:
            return hasCollisionSuffix(observed, base: desired, open: "-", close: "") ? .collisionSuffix : .wrong
        case .computerName:
            return hasCollisionSuffix(observed, base: desired, open: " (", close: ")") ? .collisionSuffix : .wrong
        case .hostName:
            return .wrong
        }
    }

    /// True iff `value` is exactly `base + open + <one-or-more digits> + close`.
    private static func hasCollisionSuffix(_ value: String, base: String, open: String, close: String) -> Bool {
        let prefix = base + open
        guard value.hasPrefix(prefix), value.hasSuffix(close),
              value.count > prefix.count + close.count else { return false }
        let digits = value.dropFirst(prefix.count).dropLast(close.count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}

extension SystemSetting where Self == HostnameSetting {
    /// Sets the Mac's hostname.
    public static func hostname(_ name: String) -> HostnameSetting {
        HostnameSetting(name)
    }
}
