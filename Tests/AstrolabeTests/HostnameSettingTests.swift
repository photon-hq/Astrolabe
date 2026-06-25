import Testing
@testable import Astrolabe

// Pure-function coverage for HostnameSetting.classify — the decision logic that
// distinguishes a converged name from a Bonjour collision suffix from arbitrary
// drift. No system access, no root: fully hermetic.

@Test func classifyExactMatchIsHealthy() {
    #expect(HostnameSetting.classify(observed: "system9", desired: "system9", facet: .computerName) == .matches)
    #expect(HostnameSetting.classify(observed: "system9", desired: "system9", facet: .localHostName) == .matches)
    #expect(HostnameSetting.classify(observed: "system9", desired: "system9", facet: .hostName) == .matches)
}

@Test func classifyLocalHostNameCollisionSuffix() {
    #expect(HostnameSetting.classify(observed: "system9-2", desired: "system9", facet: .localHostName) == .collisionSuffix)
    #expect(HostnameSetting.classify(observed: "system9-37", desired: "system9", facet: .localHostName) == .collisionSuffix)
}

@Test func classifyComputerNameCollisionSuffix() {
    #expect(HostnameSetting.classify(observed: "system9 (4)", desired: "system9", facet: .computerName) == .collisionSuffix)
    #expect(HostnameSetting.classify(observed: "system9 (2)", desired: "system9", facet: .computerName) == .collisionSuffix)
}

@Test func classifyCrossGrammarIsWrong() {
    // " (4)" is not a valid LocalHostName suffix; "-2" is not a valid ComputerName suffix.
    #expect(HostnameSetting.classify(observed: "system9 (4)", desired: "system9", facet: .localHostName) == .wrong)
    #expect(HostnameSetting.classify(observed: "system9-2", desired: "system9", facet: .computerName) == .wrong)
}

@Test func classifyHostNameNeverTakesASuffix() {
    // HostName is never Bonjour-managed: a suffixed value is just wrong, not a collision.
    #expect(HostnameSetting.classify(observed: "system9-2", desired: "system9", facet: .hostName) == .wrong)
    #expect(HostnameSetting.classify(observed: "system9 (4)", desired: "system9", facet: .hostName) == .wrong)
}

@Test func classifyUnsetIsWrong() {
    #expect(HostnameSetting.classify(observed: nil, desired: "system9", facet: .computerName) == .wrong)
    #expect(HostnameSetting.classify(observed: nil, desired: "system9", facet: .localHostName) == .wrong)
}

@Test func classifyRejectsMalformedSuffixes() {
    #expect(HostnameSetting.classify(observed: "system9-abc", desired: "system9", facet: .localHostName) == .wrong) // non-numeric
    #expect(HostnameSetting.classify(observed: "system90", desired: "system9", facet: .localHostName) == .wrong)    // no separator
    #expect(HostnameSetting.classify(observed: "system9-", desired: "system9", facet: .localHostName) == .wrong)    // empty digits
    #expect(HostnameSetting.classify(observed: "system9 ()", desired: "system9", facet: .computerName) == .wrong)   // empty digits
}

@Test func classifyDifferentNameIsWrong() {
    #expect(HostnameSetting.classify(observed: "system12", desired: "system9", facet: .localHostName) == .wrong)
    #expect(HostnameSetting.classify(observed: "system12", desired: "system9", facet: .computerName) == .wrong)
}
