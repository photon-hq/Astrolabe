import Testing
@testable import Astrolabe

// MARK: - Setup Protocol

@Test func emptySetupProducesEmptyTree() {
    let tree = TreeBuilder.build(EmptySetup())
    #expect(tree.kind == .empty)
}

@Test func neverIsLeafTerminator() {
    let _: Never.Type = Never.Body.self
}

// MARK: - Brew Construction

@Test func brewFormula() {
    let brew = Brew("wget")
    #expect(brew.name == "wget")
    #expect(brew.type == .formula)
}

@Test func brewCask() {
    let brew = Brew("firefox", type: .cask)
    #expect(brew.name == "firefox")
    #expect(brew.type == .cask)
}

@Test func brewDefaultTypeIsFormula() {
    let brew = Brew("jq")
    #expect(brew.type == .formula)
}

// MARK: - Pkg Construction

@Test func pkgCatalogHomebrew() {
    let pkg = Pkg(.catalog(.homebrew))
    #expect(pkg.provider.item == .homebrew)
}

@Test func pkgCatalogCommandLineTools() {
    let pkg = Pkg(.catalog(.commandLineTools))
    #expect(pkg.provider.item == .commandLineTools)
}

@Test func pkgGitHub() {
    let pkg = Pkg(.gitHub("org/tool"))
    #expect(pkg.provider.repo == "org/tool")
    #expect(pkg.provider.version == .latest)
}

@Test func pkgGitHubWithTag() {
    let pkg = Pkg(.gitHub("org/tool", version: .tag("v2.0")))
    #expect(pkg.provider.repo == "org/tool")
    if case .tag(let tag) = pkg.provider.version {
        #expect(tag == "v2.0")
    } else {
        #expect(Bool(false), "Expected .tag version")
    }
}

@Test func pkgGitHubWithRegex() {
    let pkg = Pkg(.gitHub("org/tool", asset: .regex(".*arm64.*\\.pkg")))
    if case .regex(let pattern) = pkg.provider.asset {
        #expect(pattern == ".*arm64.*\\.pkg")
    } else {
        #expect(Bool(false), "Expected .regex asset")
    }
}

@Test func pkgCustomProvider() {
    struct MyProvider: PackageProvider {
        func install() async throws {}
    }
    let pkg = Pkg(MyProvider())
    _ = pkg.provider
}

// MARK: - Tree Building: Brew

@Test func brewTreeBuildingFormula() {
    let tree = TreeBuilder.build(Brew("wget"))
    if case .brew(let info) = tree.kind {
        #expect(info.name == "wget")
        #expect(info.type == .formula)
    } else {
        #expect(Bool(false), "Expected .brew kind")
    }
}

@Test func brewTreeBuildingCask() {
    let tree = TreeBuilder.build(Brew("firefox", type: .cask))
    if case .brew(let info) = tree.kind {
        #expect(info.name == "firefox")
        #expect(info.type == .cask)
    } else {
        #expect(Bool(false), "Expected .brew kind")
    }
}

// MARK: - Tree Building: Pkg

@Test func pkgCatalogTreeBuilding() {
    let tree = TreeBuilder.build(Pkg(.catalog(.homebrew)))
    if case .pkg(let info) = tree.kind, case .catalog(.homebrew) = info.source {
        // correct
    } else {
        #expect(Bool(false), "Expected .pkg(.catalog(.homebrew))")
    }
}

@Test func pkgGitHubTreeBuilding() {
    let tree = TreeBuilder.build(Pkg(.gitHub("org/tool")))
    if case .pkg(let info) = tree.kind, case .gitHub(let repo, _, _) = info.source {
        #expect(repo == "org/tool")
    } else {
        #expect(Bool(false), "Expected .pkg(.gitHub(...))")
    }
}

@Test func pkgCustomProviderTreeBuilding() {
    struct MyProvider: PackageProvider {
        func install() async throws {}
    }
    let tree = TreeBuilder.build(Pkg(MyProvider()))
    if case .pkg(let info) = tree.kind, case .custom = info.source {
        // correct — custom provider stored by type name
    } else {
        #expect(Bool(false), "Expected .pkg(.custom(...))")
    }
}

// MARK: - SetupBuilder & Tree Building

@Test func sequenceTreeBuilding() {
    @SetupBuilder var setup: some Setup {
        Brew("wget")
        Brew("git-lfs")
        Brew("firefox", type: .cask)
    }

    let tree = TreeBuilder.build(setup)
    #expect(tree.children.count == 3)
}

@Test func conditionalTreeBuildingTrueBranch() {
    let flag = true

    @SetupBuilder var setup: some Setup {
        if flag {
            Brew("wget")
        } else {
            Brew("curl")
        }
    }

    let tree = TreeBuilder.build(setup)
    let leaves = tree.leaves()
    #expect(leaves.count == 1)
    if case .brew(let info) = leaves[0].kind {
        #expect(info.name == "wget")
    } else {
        #expect(Bool(false), "Expected brew wget")
    }
}

@Test func conditionalTreeBuildingFalseBranch() {
    let flag = false

    @SetupBuilder var setup: some Setup {
        if flag {
            Brew("wget")
        } else {
            Brew("curl")
        }
    }

    let tree = TreeBuilder.build(setup)
    let leaves = tree.leaves()
    #expect(leaves.count == 1)
    if case .brew(let info) = leaves[0].kind {
        #expect(info.name == "curl")
    } else {
        #expect(Bool(false), "Expected brew curl")
    }
}

@Test func optionalTreeBuildingPresent() {
    let include = true

    @SetupBuilder var setup: some Setup {
        if include {
            Brew("wget")
        }
    }

    let tree = TreeBuilder.build(setup)
    let leaves = tree.leaves()
    #expect(leaves.count == 1)
}

@Test func optionalTreeBuildingAbsent() {
    let include = false

    @SetupBuilder var setup: some Setup {
        if include {
            Brew("wget")
        }
    }

    let tree = TreeBuilder.build(setup)
    let leaves = tree.leaves()
    #expect(leaves.count == 1)
    if case .optional = leaves[0].kind {
        // correct — empty optional
    } else {
        #expect(Bool(false), "Expected empty optional node")
    }
}

@Test func groupTreeBuilding() {
    let tree = TreeBuilder.build(
        Group {
            Brew("wget")
            Brew("git-lfs")
        }
    )

    let leaves = tree.leaves()
    #expect(leaves.count == 2)
}

@Test func compositeSetupTreeBuilding() {
    struct DevTools: Setup {
        var body: some Setup {
            Brew("wget")
            Brew("git-lfs")
            Brew("swiftformat")
        }
    }

    let tree = TreeBuilder.build(DevTools())
    let leaves = tree.leaves()
    #expect(leaves.count == 3)
}

@Test func mixedBrewAndPkgTreeBuilding() {
    @SetupBuilder var setup: some Setup {
        Pkg(.catalog(.homebrew))
        Brew("wget")
        Pkg(.gitHub("org/tool"))
    }

    let tree = TreeBuilder.build(setup)
    let leaves = tree.leaves()
    #expect(leaves.count == 3)

    if case .pkg = leaves[0].kind {} else { #expect(Bool(false), "Expected .pkg") }
    if case .brew = leaves[1].kind {} else { #expect(Bool(false), "Expected .brew") }
    if case .pkg = leaves[2].kind {} else { #expect(Bool(false), "Expected .pkg") }
}

// MARK: - Structural Identity

@Test func sequenceChildrenHaveIndexIdentity() {
    @SetupBuilder var setup: some Setup {
        Brew("wget")
        Brew("git-lfs")
    }

    let tree = TreeBuilder.build(setup)
    #expect(tree.children[0].identity.path == [.index(0)])
    #expect(tree.children[1].identity.path == [.index(1)])
}

@Test func conditionalBranchIdentity() {
    @SetupBuilder var setupTrue: some Setup {
        if true {
            Brew("wget")
        } else {
            Brew("curl")
        }
    }

    @SetupBuilder var setupFalse: some Setup {
        if false {
            Brew("wget")
        } else {
            Brew("curl")
        }
    }

    let treeTrue = TreeBuilder.build(setupTrue)
    let treeFalse = TreeBuilder.build(setupFalse)

    let leavesTrue = treeTrue.leaves()
    let leavesFalse = treeFalse.leaves()

    #expect(leavesTrue[0].identity != leavesFalse[0].identity)
}

// MARK: - Tree Diffing

@Test func diffNewNodeProducesInstall() {
    let node = TreeNode(identity: NodeIdentity([.index(0)]), kind: .brew(
        NodeKind.BrewInfo(name: "wget", type: .formula)
    ))
    let tree = TreeNode(identity: NodeIdentity(), kind: .sequence, children: [node])

    let actions = TreeDiff.diff(old: nil, new: tree)
    let installs = actions.compactMap { action -> NodeIdentity? in
        if case .install(let n) = action { return n.identity }
        return nil
    }
    #expect(installs.count == 1)
}

@Test func diffUnchangedNodeProducesNoOp() {
    let node = TreeNode(identity: NodeIdentity([.index(0)]), kind: .brew(
        NodeKind.BrewInfo(name: "wget", type: .formula)
    ), status: .applied)
    let tree = TreeNode(identity: NodeIdentity(), kind: .sequence, children: [node])

    let actions = TreeDiff.diff(old: tree, new: tree)
    let unchanged = actions.compactMap { action -> NodeIdentity? in
        if case .unchanged(let n) = action { return n.identity }
        return nil
    }
    #expect(unchanged.count == 1)
}

@Test func diffRemovedNodeProducesUninstall() {
    let node = TreeNode(identity: NodeIdentity([.index(0)]), kind: .brew(
        NodeKind.BrewInfo(name: "wget", type: .formula)
    ))
    let oldTree = TreeNode(identity: NodeIdentity(), kind: .sequence, children: [node])
    let newTree = TreeNode(identity: NodeIdentity(), kind: .sequence, children: [])

    let actions = TreeDiff.diff(old: oldTree, new: newTree)
    let uninstalls = actions.compactMap { action -> NodeIdentity? in
        if case .uninstall(let id) = action { return id }
        return nil
    }
    #expect(uninstalls.count == 1)
}

@Test func diffCarriesForwardAppliedStatus() {
    let oldNode = TreeNode(identity: NodeIdentity([.index(0)]), kind: .brew(
        NodeKind.BrewInfo(name: "wget", type: .formula)
    ), status: .applied)
    let oldTree = TreeNode(identity: NodeIdentity(), kind: .sequence, children: [oldNode])

    let newNode = TreeNode(identity: NodeIdentity([.index(0)]), kind: .brew(
        NodeKind.BrewInfo(name: "wget", type: .formula)
    ), status: .pending)
    let newTree = TreeNode(identity: NodeIdentity(), kind: .sequence, children: [newNode])

    let actions = TreeDiff.diff(old: oldTree, new: newTree)
    if case .unchanged(let n) = actions.first {
        #expect(n.status == .applied)
    } else {
        #expect(Bool(false), "Expected unchanged with carried-forward status")
    }
}

// MARK: - Modifiers

@Test func retryModifierAttaches() {
    let modified = Brew("wget").retry(3)
    #expect(modified.modifier.count == 3)
    #expect(modified.modifier.delay == nil)
}

@Test func retryModifierWithDelay() {
    let modified = Brew("wget").retry(3, delay: .seconds(10))
    #expect(modified.modifier.count == 3)
    #expect(modified.modifier.delay == .seconds(10))
}

@Test func onFailModifierAttaches() {
    let modified = Brew("wget").onFail { _ in }
    _ = modified.modifier
}

@Test func taskModifierAttaches() {
    let modified = Brew("wget").task { }
    #expect(modified.modifier.id == nil)
}

@Test func taskModifierWithId() {
    let modified = Brew("wget").task(id: "setup") { }
    #expect(modified.modifier.id == AnyHashable("setup"))
}

@Test func environmentModifierAttaches() {
    let modified = Brew("wget").environment(\.allowUntrusted, true)
    #expect(modified.modifier.value == true)
}

@Test func allowUntrustedModifier() {
    let modified = Pkg(.gitHub("org/tool")).allowUntrusted()
    #expect(modified.modifier.value == true)
}

@Test func dialogModifierAttaches() {
    let modified = Brew("iterm2", type: .cask)
        .dialog("Welcome!", isPresented: .constant(true)) {
            Button("OK")
        }
    #expect(modified.modifier.title == "Welcome!")
    #expect(modified.modifier.buttons.count == 1)
}

// MARK: - Environment

struct TestKey: EnvironmentKey {
    static let defaultValue: String = "default"
}

extension EnvironmentValues {
    var testValue: String {
        get { self[TestKey.self] }
        set { self[TestKey.self] = newValue }
    }
}

@Test func environmentDefaultValue() {
    #expect(EnvironmentValues().testValue == "default")
}

@Test func environmentSubscriptSet() {
    var env = EnvironmentValues()
    env.testValue = "custom"
    #expect(env.testValue == "custom")
}

@Test func environmentAllowUntrustedDefaultFalse() {
    #expect(EnvironmentValues().allowUntrusted == false)
}

@Test func environmentGitHubTokenDefaultNil() {
    #expect(EnvironmentValues().gitHubToken == nil)
}

@Test func environmentIsEnrolledDefaultFalse() {
    #expect(EnvironmentValues().isEnrolled == false)
}

@Test func environmentConsoleUserDefaultNil() {
    #expect(EnvironmentValues().consoleUser == nil)
}

// MARK: - Environment Propagation in Tree

@Test func environmentModifierPropagatesThroughTreeBuilding() {
    let setup = Group {
        Pkg(.gitHub("org/tool"))
    }
    .environment(\.allowUntrusted, true)

    let tree = TreeBuilder.build(setup)
    let leaves = tree.leaves()
    #expect(leaves.count == 1)
}

// MARK: - State

@Test func stateInitialValue() {
    @State var flag = true
    #expect(flag == true)
}

@Test func stateMutation() {
    @State var count = 0
    count = 42
    #expect(count == 42)
}

@Test func bindingFromState() {
    @State var flag = true
    let binding = $flag
    #expect(binding.wrappedValue == true)
    binding.wrappedValue = false
    #expect(flag == false)
}

@Test func constantBinding() {
    let binding = Binding.constant(true)
    #expect(binding.wrappedValue == true)
}

// MARK: - Button & Dialog Construction

@Test func buttonConstruction() {
    let button = Button("OK")
    #expect(button.label == "OK")
}

@Test func buttonWithAction() async throws {
    let log = Log()
    let button = Button("OK") { log.append("pressed") }
    try await button.action()
    #expect(log.values == ["pressed"])
}

final class Log: @unchecked Sendable {
    private var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    var values: [String] { entries }
}

@Test func dialogConstruction() {
    let dialog = Dialog("Title", message: "Hello") {
        Button("OK")
        Button("Cancel")
    }
    #expect(dialog.title == "Title")
    #expect(dialog.message == "Hello")
    #expect(dialog.buttons.count == 2)
    #expect(dialog.buttons[0].label == "OK")
    #expect(dialog.buttons[1].label == "Cancel")
}

// MARK: - Astrolabe Protocol

@Test func astrolabeProtocolCompilesWithBody() {
    struct TestConfig: Astrolabe {
        var body: some Setup {
            Pkg(.catalog(.homebrew))
            Brew("wget")
        }
    }

    let config = TestConfig()
    _ = config.body
}

@Test func astrolabeDefaultPollInterval() {
    struct TestConfig: Astrolabe {
        var body: some Setup {
            EmptySetup()
        }
    }

    #expect(TestConfig().pollInterval == .seconds(5))
}

@Test func astrolabeCustomPollInterval() {
    struct TestConfig: Astrolabe {
        var pollInterval: Duration { .seconds(10) }
        var body: some Setup {
            EmptySetup()
        }
    }

    #expect(TestConfig().pollInterval == .seconds(10))
}

@Test func mainRequiresRoot() async throws {
    struct TestConfig: Astrolabe {
        var body: some Setup {
            EmptySetup()
        }
    }

    await #expect(throws: AstrolabeError.self) {
        try await TestConfig.main()
    }
}

// MARK: - Composable Configurations

@Test func composableSetups() {
    struct DevTools: Setup {
        var body: some Setup {
            Brew("swiftformat")
            Brew("swiftlint")
            Brew("git-lfs")
        }
    }

    struct MyConfig: Astrolabe {
        var body: some Setup {
            Pkg(.catalog(.homebrew))
            DevTools()
        }
    }

    let tree = TreeBuilder.build(MyConfig())
    let leaves = tree.leaves()
    #expect(leaves.count == 4) // homebrew + 3 dev tools
}

@Test func conditionalComposition() {
    struct MyConfig: Astrolabe {
        var body: some Setup {
            Pkg(.catalog(.homebrew))

            if true {
                Brew("git-lfs")
            }
        }
    }

    let tree = TreeBuilder.build(MyConfig())
    let pkgLeaves = tree.leaves().filter {
        if case .brew = $0.kind { return true }
        if case .pkg = $0.kind { return true }
        return false
    }
    #expect(pkgLeaves.count == 2)
}

// MARK: - Mutual Exclusivity

@Test func mutualExclusivityDiff() {
    @SetupBuilder var setupChrome: some Setup {
        if true {
            Brew("google-chrome", type: .cask)
        } else {
            Brew("firefox", type: .cask)
        }
    }

    @SetupBuilder var setupFirefox: some Setup {
        if false {
            Brew("google-chrome", type: .cask)
        } else {
            Brew("firefox", type: .cask)
        }
    }

    let treeChrome = TreeBuilder.build(setupChrome)
    let treeFirefox = TreeBuilder.build(setupFirefox)

    let actions = TreeDiff.diff(old: treeChrome, new: treeFirefox)

    let installs = actions.compactMap { if case .install = $0 { return true }; return nil }
    let uninstalls = actions.compactMap { if case .uninstall = $0 { return true }; return nil }

    #expect(installs.count == 1) // firefox added
    #expect(uninstalls.count == 1) // chrome removed
}

// MARK: - Payload Store

@Test func payloadStoreSetAndGet() async {
    let store = PayloadStore()
    let id = NodeIdentity([.index(0)])
    await store.set(.formula(name: "wget"), for: id)
    let record = await store.record(for: id)
    if case .formula(let name) = record {
        #expect(name == "wget")
    } else {
        #expect(Bool(false), "Expected formula record")
    }
}

@Test func payloadStoreRemove() async {
    let store = PayloadStore()
    let id = NodeIdentity([.index(0)])
    await store.set(.formula(name: "wget"), for: id)
    await store.remove(for: id)
    let record = await store.record(for: id)
    #expect(record == nil)
}

// MARK: - Node Identity

@Test func nodeIdentityEquality() {
    let a = NodeIdentity([.index(0), .conditional(.first)])
    let b = NodeIdentity([.index(0), .conditional(.first)])
    let c = NodeIdentity([.index(0), .conditional(.second)])
    #expect(a == b)
    #expect(a != c)
}

@Test func nodeIdentityAppending() {
    let base = NodeIdentity([.index(0)])
    let extended = base.appending(.conditional(.first))
    #expect(extended.path == [.index(0), .conditional(.first)])
}

// MARK: - TreeNode

@Test func treeNodeFindByIdentity() {
    let child = TreeNode(identity: NodeIdentity([.index(0)]), kind: .brew(
        NodeKind.BrewInfo(name: "wget", type: .formula)
    ))
    let root = TreeNode(identity: NodeIdentity(), kind: .sequence, children: [child])

    let found = root.find(NodeIdentity([.index(0)]))
    #expect(found != nil)
    #expect(found?.identity == child.identity)
}

@Test func treeNodeLeaves() {
    let c1 = TreeNode(identity: NodeIdentity([.index(0)]), kind: .brew(
        NodeKind.BrewInfo(name: "wget", type: .formula)
    ))
    let c2 = TreeNode(identity: NodeIdentity([.index(1)]), kind: .brew(
        NodeKind.BrewInfo(name: "git-lfs", type: .formula)
    ))
    let root = TreeNode(identity: NodeIdentity(), kind: .sequence, children: [c1, c2])

    let leaves = root.leaves()
    #expect(leaves.count == 2)
}
