import AstrolabeMacros
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

struct FactEntryMacroTests {
    // MARK: - Expansions

    @Test func theStagingFactExpandsToTheHandWrittenKey() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(schedule: .every(.seconds(1)), read: {
                    try StateFile.read(StateFile.path)                     // a throw means "couldn't read", never "nothing"
                })
                var stagingFiles: [String: String] = [:]
            }
            """,
            expandedSource: """
            extension Facts {
                var stagingFiles: [String: String] {
                    get {
                        self[__Key_stagingFiles.self]
                    }
                }

                private struct __Key_stagingFiles: FactKey {
                    static let defaultValue: [String: String] = [:]
                    static let schedule: FactSchedule = .every(.seconds(1))
                    @concurrent static func read() async throws -> [String: String] {
                        try StateFile.read(StateFile.path)
                    }
                }
            }
            """
        )
    }

    @Test func anOptionalWithoutAnInitializerKeepsFactKeysNilDefault() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: { ProcessInfo.processInfo.operatingSystemVersionString })
                var osVersion: String?

                @FactEntry(read: { try Inventory.read() })
                var inventory: Optional<Inventory>
            }
            """,
            expandedSource: """
            extension Facts {
                var osVersion: String? {
                    get {
                        self[__Key_osVersion.self]
                    }
                }

                private struct __Key_osVersion: FactKey {
                    @concurrent static func read() async throws -> String? {
                        ProcessInfo.processInfo.operatingSystemVersionString
                    }
                }
                var inventory: Optional<Inventory> {
                    get {
                        self[__Key_inventory.self]
                    }
                }

                private struct __Key_inventory: FactKey {
                    @concurrent static func read() async throws -> Optional<Inventory> {
                        try Inventory.read()
                    }
                }
            }
            """
        )
    }

    @Test func onlyTheArgumentsWrittenAreEmitted() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(timeout: .seconds(10), read: { try await FileVault.status() == .on })
                var fileVaultOn: Bool = false
            }
            """,
            expandedSource: """
            extension Facts {
                var fileVaultOn: Bool {
                    get {
                        self[__Key_fileVaultOn.self]
                    }
                }

                private struct __Key_fileVaultOn: FactKey {
                    static let defaultValue: Bool = false
                    static let timeout: Duration = .seconds(10)
                    @concurrent static func read() async throws -> Bool {
                        try await FileVault.status() == .on
                    }
                }
            }
            """
        )
    }

    @Test func aClosuresSignatureIsDroppedAndItsStatementsReindented() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(schedule: .every(.seconds(300)), timeout: .seconds(10), read: { () async throws -> Bool in
                    let status = try await FileVault.status()
                    if status == .unknown {
                        throw FileVault.Unknown()  // retried with backoff
                    }
                    return status == .on
                })
                var fileVaultOn: Bool = false
            }
            """,
            expandedSource: """
            extension Facts {
                var fileVaultOn: Bool {
                    get {
                        self[__Key_fileVaultOn.self]
                    }
                }

                private struct __Key_fileVaultOn: FactKey {
                    static let defaultValue: Bool = false
                    static let schedule: FactSchedule = .every(.seconds(300))
                    static let timeout: Duration = .seconds(10)
                    @concurrent static func read() async throws -> Bool {
                        let status = try await FileVault.status()
                        if status == .unknown {
                            throw FileVault.Unknown()  // retried with backoff
                        }
                        return status == .on
                    }
                }
            }
            """
        )
    }

    @Test func aMultilineStringKeepsItsLines() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: {
                    try Shell.run(\"\"\"
                        /usr/bin/fdesetup status
                        \"\"\")
                })
                var fileVaultStatus: String = ""
            }
            """,
            expandedSource: """
            extension Facts {
                var fileVaultStatus: String {
                    get {
                        self[__Key_fileVaultStatus.self]
                    }
                }

                private struct __Key_fileVaultStatus: FactKey {
                    static let defaultValue: String = ""
                    @concurrent static func read() async throws -> String {
                        try Shell.run(\"\"\"
                                    /usr/bin/fdesetup status
                                    \"\"\")
                    }
                }
            }
            """
        )
    }

    @Test func modifiersAndDocCommentsStayOnThePropertyAndTheKeyIsPrivate() {
        assertExpansion(
            """
            extension Facts {
                /// The macOS version.
                @FactEntry(read: { ProcessInfo.processInfo.operatingSystemVersionString })
                public var osVersion: String?

                /// Whether FileVault is on.
                @FactEntry(read: { try await FileVault.isOn() })
                fileprivate var fileVaultOn: Bool = false
            }
            """,
            expandedSource: """
            extension Facts {
                /// The macOS version.
                public var osVersion: String? {
                    get {
                        self[__Key_osVersion.self]
                    }
                }

                private struct __Key_osVersion: FactKey {
                    @concurrent static func read() async throws -> String? {
                        ProcessInfo.processInfo.operatingSystemVersionString
                    }
                }

                /// Whether FileVault is on.
                fileprivate var fileVaultOn: Bool {
                    get {
                        self[__Key_fileVaultOn.self]
                    }
                }

                private struct __Key_fileVaultOn: FactKey {
                    static let defaultValue: Bool = false
                    @concurrent static func read() async throws -> Bool {
                        try await FileVault.isOn()
                    }
                }
            }
            """
        )
    }

    @Test func aNamespaceExpandsTheSameWay() {
        assertExpansion(
            """
            struct SystemFacts: FactNamespace {
                let facts: Facts

                @FactEntry(read: { try await CSR.sipDisabled() })
                var sipDisabled: Bool = false

                var readyForPackages: Bool { sipDisabled }
            }
            """,
            expandedSource: """
            struct SystemFacts: FactNamespace {
                let facts: Facts
                var sipDisabled: Bool {
                    get {
                        self[__Key_sipDisabled.self]
                    }
                }

                private struct __Key_sipDisabled: FactKey {
                    static let defaultValue: Bool = false
                    @concurrent static func read() async throws -> Bool {
                        try await CSR.sipDisabled()
                    }
                }

                var readyForPackages: Bool { sipDisabled }
            }
            """
        )
    }

    @Test func aBacktickedNameMakesAPlainKeyName() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: { try Defaults.read() })
                var `default`: Int = 0
            }
            """,
            expandedSource: """
            extension Facts {
                var `default`: Int {
                    get {
                        self[__Key_default.self]
                    }
                }

                private struct __Key_default: FactKey {
                    static let defaultValue: Int = 0
                    @concurrent static func read() async throws -> Int {
                        try Defaults.read()
                    }
                }
            }
            """
        )
    }

    // MARK: - Diagnostics

    @Test func aLetIsRejected() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: { true })
                let ready: Bool = false
            }
            """,
            expandedSource: """
            extension Facts {
                let ready: Bool = false
            }
            """,
            diagnostics: [DiagnosticSpec(message: "`@FactEntry` needs an instance `var`", line: 3, column: 5)]
        )
    }

    @Test func aStaticOrClassVarIsRejected() {
        for modifier in ["static", "class"] {
            assertExpansion(
                """
                extension Facts {
                    @FactEntry(read: { true })
                    \(modifier) var ready: Bool = false
                }
                """,
                expandedSource: """
                extension Facts {
                    \(modifier) var ready: Bool = false
                }
                """,
                diagnostics: [DiagnosticSpec(message: "`@FactEntry` needs an instance `var`", line: 3, column: 5)]
            )
        }
    }

    /// swift-syntax's expansion skips a declaration of two variables, so this calls the peer role
    /// directly. The compiler still runs it: next to its own "can only apply to a single variable",
    /// this says why.
    @Test func twoPropertiesAreRejected() throws {
        let file = Parser.parse(source: """
            @FactEntry(read: { true })
            var a, b: Bool
            """)
        let variable = try #require(file.statements.first?.item.as(VariableDeclSyntax.self))
        let attribute = try #require(variable.attributes.first?.as(AttributeSyntax.self))
        let error = #expect(throws: DiagnosticsError.self) {
            try FactEntryMacro.expansion(of: attribute, providingPeersOf: variable, in: BasicMacroExpansionContext())
        }
        let converter = SourceLocationConverter(fileName: "test.swift", tree: file)
        let diagnostics = error?.diagnostics.map { diagnostic in
            let location = diagnostic.location(converter: converter)
            return "\(location.line):\(location.column): \(diagnostic.message)"
        }
        #expect(diagnostics == ["2:8: one property per `@FactEntry`"])
        #expect(try FactEntryMacro.expansion(of: attribute, providingAccessorsOf: variable, in: BasicMacroExpansionContext()).isEmpty)
    }

    @Test func aMissingTypeIsRejected() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: { true })
                var ready = false
            }
            """,
            expandedSource: """
            extension Facts {
                var ready = false
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "`@FactEntry` needs an explicit type: `var x: T = …`", line: 3, column: 9)
            ]
        )
    }

    @Test func aMissingDefaultForANonOptionalIsRejected() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: { true })
                var ready: Bool
            }
            """,
            expandedSource: """
            extension Facts {
                var ready: Bool
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "`@FactEntry` needs a default value, or an optional type (default `nil`)", line: 3, column: 16
                )
            ]
        )
    }

    @Test func anAccessorIsRejected() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: { true })
                var ready: Bool { true }
            }
            """,
            expandedSource: """
            extension Facts {
                var ready: Bool { true }
            }
            """,
            diagnostics: [DiagnosticSpec(message: "`@FactEntry` declares the accessor; remove it", line: 3, column: 21)]
        )
    }

    @Test func aReadThatIsNotAClosureLiteralIsRejectedWithAFixIt() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: Inventory.read)
                var inventory: Inventory?
            }
            """,
            expandedSource: """
            extension Facts {
                var inventory: Inventory?
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "pass a closure: `read: { try … }`",
                    line: 2,
                    column: 22,
                    fixIts: [FixItSpec(message: "call it in a closure")]
                )
            ],
            fixedSource: """
            extension Facts {
                @FactEntry(read: { try await Inventory.read() })
                var inventory: Inventory?
            }
            """
        )
    }

    @Test func aClosureWithParametersOrACaptureListIsRejected() {
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: { path in try StateFile.read(path) })
                var files: [String: String] = [:]
            }
            """,
            expandedSource: """
            extension Facts {
                var files: [String: String] = [:]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "`read` takes no parameters and captures nothing", line: 2, column: 24)
            ]
        )
        assertExpansion(
            """
            extension Facts {
                @FactEntry(read: { [path] in try StateFile.read(path) })
                var files: [String: String] = [:]
            }
            """,
            expandedSource: """
            extension Facts {
                var files: [String: String] = [:]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "`read` takes no parameters and captures nothing", line: 2, column: 24)
            ]
        )
    }
}
