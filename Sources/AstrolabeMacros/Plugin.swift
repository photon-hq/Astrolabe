import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct AstrolabeMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [FactEntryMacro.self]
}
