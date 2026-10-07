import Testing
@testable import Astrolabe

@Test func constantPolicyDoesNotBackOffOrSampleJitter() {
    #expect(RetryPolicy.constant.delay(tickInterval: .seconds(15), consecutiveDrifts: .max, random: {
        Issue.record("Constant policy should not sample jitter")
        return 0
    }) == .seconds(15))
}

@Test func exponentialPolicyNeverShortensTheLoopInterval() {
    for cap in [Duration.seconds(-1), .zero, .seconds(10), .seconds(15)] {
        let policy = RetryPolicy.exponential(maxDelay: cap, jitter: .equal)
        #expect(policy.delay(tickInterval: .seconds(15), consecutiveDrifts: .max, random: { 0 }) == .seconds(15))
    }
}

@Test func exponentialPolicyHandlesHugeDurationsWithoutOverflow() {
    let cap = Duration.seconds(Int64.max)
    let policy = RetryPolicy.exponential(maxDelay: cap)
    #expect(policy.delay(tickInterval: .seconds(Int64.max / 2 + 1), consecutiveDrifts: 2, random: { 0 }) == cap)
    #expect(policy.delay(tickInterval: .nanoseconds(1), consecutiveDrifts: .max, random: { 0 }) == cap)
}

@Test func equalJitterStaysWithinItsWindowAndTheLoopCadence() {
    let policy = RetryPolicy.exponential(maxDelay: .seconds(45), jitter: .equal)
    for (sample, expected) in [(0.0, 22.5), (0.5, 33.75), (1.0, 45.0)] {
        #expect(policy.delay(tickInterval: .seconds(15), consecutiveDrifts: 3, random: { sample }) == .seconds(expected))
    }
    #expect(policy.delay(tickInterval: .seconds(15), consecutiveDrifts: 1, random: { 0 }) == .seconds(15))
    #expect(policy.delay(tickInterval: .seconds(15), consecutiveDrifts: 2, random: { 0 }) == .seconds(15))
    #expect(policy.delay(tickInterval: .seconds(15), consecutiveDrifts: 0, random: { 1 }) == .seconds(15))
}

@Test func defaultExponentialPolicyDoesNotSampleJitter() {
    #expect(RetryPolicy.exponential().delay(tickInterval: .seconds(15), consecutiveDrifts: 3, random: {
        Issue.record("Default policy should not sample jitter")
        return 0
    }) == .seconds(60))
}

private struct PolicyTestNode: Setup, ReconcilableNode, _LeafNode, _ContentIdentifiable {
    typealias Body = Never
    let name: String
    var displayName: String { name }
    var _contentID: String { "policy:\(name)" }
    var _reconcilable: (any ReconcilableNode)? { self }
}

private func declaredPolicy(_ node: TreeNode) -> RetryPolicy? {
    for modifier in node.modifiers {
        if case .retryPolicy(let policy) = modifier { return policy }
    }
    return nil
}

@Test func retryPolicyIsStoredOnTheLeafWithoutChangingIdentity() {
    let node = PolicyTestNode(name: "direct")
    let plain = TreeBuilder.build(node)
    let configured = TreeBuilder.build(node.retryPolicy(.constant))
    #expect(declaredPolicy(plain) == nil)
    #expect(declaredPolicy(configured) == .constant)
    #expect(configured.identity == plain.identity)
}

@Test func retryPolicyInheritsThroughGroupsWithChildOverrides() {
    let tree = TreeBuilder.build(
        Group {
            PolicyTestNode(name: "inherited")
            PolicyTestNode(name: "override").retryPolicy(.constant)
            Group {
                PolicyTestNode(name: "nested")
                PolicyTestNode(name: "nearest").retryPolicy(.exponential(maxDelay: .seconds(60)))
            }.retryPolicy(.constant)
        }.retryPolicy(.exponential(maxDelay: .seconds(300)))
    )

    #expect(tree.leaves().map(declaredPolicy) == [
        .exponential(maxDelay: .seconds(300)), .constant,
        .constant, .exponential(maxDelay: .seconds(60)),
    ])
}

private struct PolicyTestComposite: Setup {
    var body: some Setup {
        Group {
            PolicyTestNode(name: "composite-inherited")
            PolicyTestNode(name: "composite-override").retryPolicy(.constant)
        }
    }
}

@Test func retryPolicyInheritsThroughCompositeBodies() {
    let tree = TreeBuilder.build(PolicyTestComposite().retryPolicy(.exponential(maxDelay: .seconds(90))))
    #expect(tree.leaves().map(declaredPolicy) == [.exponential(maxDelay: .seconds(90)), .constant])
}

@Test func retryPolicyDoesNotLeakAcrossSiblingsOrTreeRebuilds() {
    let tree = TreeBuilder.build(Group {
        PolicyTestNode(name: "configured").retryPolicy(.constant)
        PolicyTestNode(name: "unconfigured")
    })
    #expect(tree.leaves().map(declaredPolicy) == [.constant, nil])
    #expect(declaredPolicy(TreeBuilder.build(PolicyTestNode(name: "configured"))) == nil)
}

@Test func retryPolicyNearestModifierWins() {
    let tree = TreeBuilder.build(
        PolicyTestNode(name: "chained")
            .retryPolicy(.constant)
            .retryPolicy(.exponential(maxDelay: .seconds(300)))
    )
    #expect(declaredPolicy(tree) == .constant)
}
