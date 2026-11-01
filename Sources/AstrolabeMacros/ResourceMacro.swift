import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Resource`: conforms a type to `Resource` and records it in the binary, where the engine
/// finds it at launch:
///
/// ```swift
/// @Resource
/// struct StagingFile { … }
///
/// // becomes
///
/// struct StagingFile {
///     …
///     @section("__DATA_CONST,__astrolabe_res") @used
///     public nonisolated static let __resourceRecord: __ResourceRecord = (
///         0x6173_7472,
///         { out in out.initializeMemory(as: (any Resource.Type).self, to: StagingFile.self) }
///     )
/// }
///
/// extension StagingFile: Resource {}
/// ```
///
/// The section, segment, and magic must match `ResourceRecords` in the library; `@section` takes
/// only literals. The record is `public` because it witnesses a requirement of a public protocol,
/// and `nonisolated` so it stays a plain constant in an actor-isolated type.
///
/// Names are unqualified: in user code `Astrolabe.` is the `Astrolabe` protocol, not the module.
public struct ResourceMacro: MemberMacro, ExtensionMacro {
    /// The record. A type that can't have one gets none; this role reports why, once.
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let name = try recordedName(declaration, context)
        return [
            """
            @section("__DATA_CONST,__astrolabe_res") @used
            public nonisolated static let __resourceRecord: __ResourceRecord = (
                0x6173_7472,
                { out in out.initializeMemory(as: (any Resource.Type).self, to: \(name).self) }
            )
            """
        ]
    }

    /// The conformance, unless the type already declares it.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty, (try? recordedName(declaration, context)) != nil else { return [] }
        return [try ExtensionDeclSyntax("extension \(type.trimmed): Resource {}")]
    }

    /// The type's name, or `DiagnosticsError` when the declaration can't have a record.
    private static func recordedName(
        _ declaration: some DeclGroupSyntax,
        _ context: some MacroExpansionContext
    ) throws -> TokenSyntax {
        guard let type = declaration.asProtocol(NamedDeclSyntax.self),
              declaration.is(StructDeclSyntax.self) || declaration.is(EnumDeclSyntax.self)
                || declaration.is(ClassDeclSyntax.self) || declaration.is(ActorDeclSyntax.self)
        else {
            throw ResourceDiagnostic.notAType.error(at: declaration.introducer)
        }
        if let generics = declaration.asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause {
            throw ResourceDiagnostic.generic.error(at: generics)
        }
        if context.lexicalContext.contains(where: \.hasGenericParameters) {
            throw ResourceDiagnostic.inGenericContext.error(at: type.name)
        }
        return type.name.trimmed
    }
}

/// What `@Resource` reports when the declaration can't have a record.
enum ResourceDiagnostic: String, DiagnosticMessage {
    case notAType
    case generic
    case inGenericContext

    var message: String {
        switch self {
        case .notAType: "`@Resource` applies to a struct, enum, class, or actor"
        case .generic: "a `@Resource` type can't be generic: its record names one concrete type"
        case .inGenericContext: "a `@Resource` type can't be nested in a generic type or function"
        }
    }

    var diagnosticID: MessageID { MessageID(domain: "AstrolabeMacros", id: "Resource.\(rawValue)") }
    var severity: DiagnosticSeverity { .error }

    func error(at node: some SyntaxProtocol) -> DiagnosticsError {
        DiagnosticsError(diagnostics: [Diagnostic(node: node, message: self)])
    }
}

extension Syntax {
    /// A type, function, initializer, or subscript that declares generic parameters.
    fileprivate var hasGenericParameters: Bool {
        asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause != nil
    }
}
