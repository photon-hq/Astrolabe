import AstrolabeMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

/// Every macro in the plugin, by attribute name. `@Resource`'s extension role adds `Resource`.
private let macros = [
    "FactEntry": MacroSpec(type: FactEntryMacro.self),
    "Resource": MacroSpec(type: ResourceMacro.self, conformances: ["Resource"]),
]

/// `assertMacroExpansion`, reporting through swift-testing.
func assertExpansion(
    _ source: String,
    expandedSource: String,
    diagnostics: [DiagnosticSpec] = [],
    fixedSource: String? = nil,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    assertMacroExpansion(
        source,
        expandedSource: expandedSource,
        diagnostics: diagnostics,
        macroSpecs: macros,
        fixedSource: fixedSource,
        failureHandler: { Issue.record(Comment(rawValue: $0.message), sourceLocation: sourceLocation) }
    )
}
