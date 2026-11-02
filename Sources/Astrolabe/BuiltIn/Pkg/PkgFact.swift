import Foundation

extension Facts {
    /// Facts about the `.pkg`s `Pkg` installed. Reads nothing by itself.
    public var pkgs: PkgFacts { PkgFacts(facts: self) }
}

/// Which of the `.pkg`s `Pkg` installed are still on the Mac: `installed`, and one `Bool` per
/// key through `[installed:]`.
public struct PkgFacts: FactNamespace {
    public let facts: Facts

    /// The keys (`PkgSource.key`) whose marker is there and whose receipts are all on the Mac.
    /// A `pkgutil --forget` takes a key out.
    ///
    /// Reads the marker directory and the receipt databases: no subprocess and no lock, so every
    /// minute is cheap. It only feeds `@Monitor`s, and a value caught mid-install just reruns a
    /// rollout that checks again under the lock.
    @FactEntry(schedule: .every(.seconds(60)), read: { try PkgReads.installed() })
    public var installed: Set<String> = []

    /// Whether the package keyed `key` is installed. Tracked through `installed`. What
    /// `PkgInstall` monitors: one `Bool` per package, so installing one reruns no other.
    public subscript(installed key: String) -> Bool {
        installed.contains(key)
    }

    /// The tag of every `.latest` checked so far, whether or not this launch declared it yet.
    ///
    /// Every minute it asks GitHub for each declared query whose tag is over an hour old, or
    /// that has never been checked; a query that failed waits 5 minutes. What it learns is
    /// saved, so after a restart the first read has every tag already, and a GitHub outage never
    /// uninstalls a package.
    @FactEntry(schedule: .every(.seconds(60)), timeout: .seconds(10 * 60), read: { try await PkgReads.latestTags() })
    var latestTags: [LatestTagQuery: String] = [:]

    /// The tag `query` resolves to, or `nil` until its first check lands. Declares the query, so
    /// the `latestTags` read after this pass checks it. Tracked through `latestTags`.
    subscript(latest query: LatestTagQuery) -> String? {
        _ = PkgContext.current.latestQueries.withLock { $0.insert(query) }
        return latestTags[query]
    }
}

/// The reads behind `PkgFacts`, on the task-local context.
enum PkgReads {
    static func installed() throws -> Set<String> {
        let system = PkgContext.current.system
        let receipts = try system.receipts()
        return Set(try system.markers().filter { Set($0.receipts).isSubset(of: receipts) }.map(\.key))
    }

    /// How old a tag may be before it's checked again.
    static let latestRefresh: TimeInterval = 3600
    /// How long a failed check waits before the next.
    static let latestRetry: TimeInterval = 5 * 60

    /// Checks the declared queries that are due, saves what it learned, and returns every tag
    /// known. Never drops a tag: an undeclared one may be declared again in the next pass.
    static func latestTags() async throws -> [LatestTagQuery: String] {
        let context = PkgContext.current
        let system = context.system
        var cache = try system.latestTagCache()
        let queries = context.latestQueries.withLock { $0 }
        var learned = false
        for query in queries.sorted(by: { $0.repo < $1.repo }) {
            let now = system.now()
            if let entry = cache[query], now.timeIntervalSince(entry.checkedAt) < latestRefresh { continue }
            if let failed = context.latestFailures.withLock({ $0[query] }), now.timeIntervalSince(failed) < latestRetry { continue }
            do {
                let tag = try await system.latestTag(query)
                if cache[query]?.tag != tag { print("[Astrolabe] pkg \(query.repo): latest is \(tag)") }
                cache[query] = LatestTagEntry(tag: tag, checkedAt: now)
                learned = true
                _ = context.latestFailures.withLock { $0.removeValue(forKey: query) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let kept = cache[query].map { "keeping \($0.tag)" } ?? "nothing declared until it succeeds"
                print("[Astrolabe] pkg \(query.repo): checking the latest release failed, \(kept): \(error)")
                context.latestFailures.withLock { $0[query] = now }
            }
        }
        if learned { try system.writeLatestTagCache(cache) }
        return cache.mapValues(\.tag)
    }
}
