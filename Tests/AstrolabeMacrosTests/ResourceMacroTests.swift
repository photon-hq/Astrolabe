import SwiftSyntaxMacrosGenericTestSupport
import Testing

struct ResourceMacroTests {
    // MARK: - Expansions

    @Test func aStructGetsARecordAndAConformance() {
        assertExpansion(
            """
            @Resource
            struct StagingFile {
                static let kind = "staging.file"
            }
            """,
            expandedSource: """
            struct StagingFile {
                static let kind = "staging.file"

                @section("__DATA_CONST,__astrolabe_res") @used
                public nonisolated static let __resourceRecord: __ResourceRecord = (
                    0x6173_7472,
                    { out in
                        out.initializeMemory(as: (any Resource.Type).self, to: StagingFile.self)
                    }
                )
            }

            extension StagingFile: Resource {
            }
            """
        )
    }

    @Test func aNestedTypeNamesItselfUnqualifiedFromInside() {
        assertExpansion(
            """
            enum Brew {
                @Resource
                struct Formula {
                    static let kind = "brew.formula"
                }
            }
            """,
            expandedSource: """
            enum Brew {
                struct Formula {
                    static let kind = "brew.formula"

                    @section("__DATA_CONST,__astrolabe_res") @used
                    public nonisolated static let __resourceRecord: __ResourceRecord = (
                        0x6173_7472,
                        { out in
                            out.initializeMemory(as: (any Resource.Type).self, to: Formula.self)
                        }
                    )
                }
            }

            extension Brew.Formula: Resource {
            }
            """
        )
    }

    // MARK: - Diagnostics

    @Test func aProtocolIsRejected() {
        assertExpansion(
            """
            @Resource
            protocol Installable {}
            """,
            expandedSource: """
            protocol Installable {}
            """,
            diagnostics: [
                DiagnosticSpec(message: "`@Resource` applies to a struct, enum, class, or actor", line: 2, column: 1)
            ]
        )
    }

    @Test func aGenericTypeIsRejected() {
        assertExpansion(
            """
            @Resource
            struct Default<Value: Codable & Sendable> {}
            """,
            expandedSource: """
            struct Default<Value: Codable & Sendable> {}
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "a `@Resource` type can't be generic: its record names one concrete type",
                    line: 2,
                    column: 15
                )
            ]
        )
    }

    @Test func aTypeInAGenericContextIsRejected() {
        for outer in ["struct Outer<T>", "func make<T>()"] {
            assertExpansion(
                """
                \(outer) {
                    @Resource
                    struct Inner {}
                }
                """,
                expandedSource: """
                \(outer) {
                    struct Inner {}
                }
                """,
                diagnostics: [
                    DiagnosticSpec(
                        message: "a `@Resource` type can't be nested in a generic type or function",
                        line: 3,
                        column: 12
                    )
                ]
            )
        }
    }
}
