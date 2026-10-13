import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@FactEntry`: a fact in one declaration. Expands to the hand-written form, a
/// `private struct __Key_<name>: FactKey` beside the property and a getter that subscripts with
/// it:
///
/// ```swift
/// @FactEntry(schedule: .every(.seconds(1)), read: { try StateFile.read(StateFile.path) })
/// var stagingFiles: [String: String] = [:]
///
/// // becomes
///
/// var stagingFiles: [String: String] {
///     get { self[__Key_stagingFiles.self] }
/// }
///
/// private struct __Key_stagingFiles: FactKey {
///     static let defaultValue: [String: String] = [:]
///     static let schedule: FactSchedule = .every(.seconds(1))
///     @concurrent static func read() async throws -> [String: String] {
///         try StateFile.read(StateFile.path)
///     }
/// }
/// ```
///
/// Names are unqualified: in user code `Astrolabe.` is the `Astrolabe` protocol, not the module.
/// The `__Key_` prefix is also in `FactKey.factName`, which strips it for logs.
public struct FactEntryMacro: AccessorMacro, PeerMacro {
    /// The getter. A property that can't make a fact gets none; the peer role reports why, once.
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let entry = try? Entry(node, declaration) else { return [] }
        return ["get { self[\(entry.key).self] }"]
    }

    /// The key. Only the arguments written are emitted, so `FactKey`'s defaults still apply.
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let entry = try Entry(node, declaration)
        let key = try StructDeclSyntax("private struct \(entry.key): FactKey") {
            if let defaultValue = entry.defaultValue {
                DeclSyntax("static let defaultValue: \(entry.type) = \(defaultValue)")
            }
            if let schedule = entry.schedule {
                DeclSyntax("static let schedule: FactSchedule = \(schedule)")
            }
            if let timeout = entry.timeout {
                DeclSyntax("static let timeout: Duration = \(timeout)")
            }
            try FunctionDeclSyntax("@concurrent static func read() async throws -> \(entry.type)") {
                for statement in entry.read { statement }
            }
        }
        return [DeclSyntax(key)]
    }
}

/// A property and its `@FactEntry` arguments, read into the parts of a key.
struct Entry {
    /// `__Key_<name>`.
    let key: TokenSyntax
    let type: TypeSyntax
    /// The initializer, or `nil` for an optional type without one: `FactKey` defaults it to `nil`.
    let defaultValue: ExprSyntax?
    let schedule: ExprSyntax?
    let timeout: ExprSyntax?
    /// The closure's statements, without its signature, to become `read()`'s body.
    let read: CodeBlockItemListSyntax

    /// Throws `DiagnosticsError` when the declaration or the arguments can't make a fact.
    init(_ node: AttributeSyntax, _ declaration: some DeclSyntaxProtocol) throws {
        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            throw FactEntryDiagnostic.instanceVar.error(at: declaration)
        }
        let staticModifier = variable.modifiers.first {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }
        if let staticModifier {
            throw FactEntryDiagnostic.instanceVar.error(at: staticModifier)
        }
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw FactEntryDiagnostic.instanceVar.error(at: variable.bindingSpecifier)
        }
        if let second = variable.bindings.dropFirst().first {
            throw FactEntryDiagnostic.oneProperty.error(at: second)
        }
        guard let binding = variable.bindings.first else {
            throw FactEntryDiagnostic.instanceVar.error(at: variable)
        }
        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
            throw FactEntryDiagnostic.oneProperty.error(at: binding.pattern)
        }
        if let accessorBlock = binding.accessorBlock {
            throw FactEntryDiagnostic.accessor.error(at: accessorBlock)
        }
        guard let type = binding.typeAnnotation?.type else {
            throw FactEntryDiagnostic.explicitType.error(at: binding.pattern)
        }
        guard binding.initializer != nil || type.isOptional else {
            throw FactEntryDiagnostic.defaultValue.error(at: type)
        }

        let arguments = node.arguments?.as(LabeledExprListSyntax.self) ?? []
        func argument(_ label: String) -> ExprSyntax? {
            arguments.first { $0.label?.text == label }?.expression
        }
        guard let read = argument("read") else {
            throw FactEntryDiagnostic.closure.error(at: node)
        }
        guard let closure = read.as(ClosureExprSyntax.self) else {
            let wrapped: ExprSyntax = "{ try await \(read.trimmed)() }"
            let fixIt = FixIt(
                message: FactEntryFixIt.wrapInClosure,
                changes: [.replace(oldNode: Syntax(read), newNode: Syntax(wrapped.with(\.trailingTrivia, read.trailingTrivia)))]
            )
            throw FactEntryDiagnostic.closure.error(at: read, fixIts: [fixIt])
        }
        if let capture = closure.signature?.capture {
            throw FactEntryDiagnostic.closureSignature.error(at: capture)
        }
        if let parameters = closure.signature?.parameterClause, parameters.hasParameters {
            throw FactEntryDiagnostic.closureSignature.error(at: parameters)
        }

        key = "__Key_\(raw: name.identifier?.name ?? name.text)"
        self.type = type.trimmed
        defaultValue = binding.initializer?.value.unindented().trimmed
        schedule = argument("schedule")?.unindented().trimmed
        timeout = argument("timeout")?.unindented().trimmed
        self.read = closure.statements.unindented().trimmed
    }
}

/// What `@FactEntry` reports when the property or its arguments can't make a fact.
enum FactEntryDiagnostic: String, DiagnosticMessage {
    case instanceVar
    case oneProperty
    case explicitType
    case defaultValue
    case accessor
    case closure
    case closureSignature

    var message: String {
        switch self {
        case .instanceVar: "`@FactEntry` needs an instance `var`"
        case .oneProperty: "one property per `@FactEntry`"
        case .explicitType: "`@FactEntry` needs an explicit type: `var x: T = …`"
        case .defaultValue: "`@FactEntry` needs a default value, or an optional type (default `nil`)"
        case .accessor: "`@FactEntry` declares the accessor; remove it"
        case .closure: "pass a closure: `read: { try … }`"
        case .closureSignature: "`read` takes no parameters and captures nothing"
        }
    }

    var diagnosticID: MessageID { MessageID(domain: "AstrolabeMacros", id: "FactEntry.\(rawValue)") }
    var severity: DiagnosticSeverity { .error }

    func error(at node: some SyntaxProtocol, fixIts: [FixIt] = []) -> DiagnosticsError {
        DiagnosticsError(diagnostics: [Diagnostic(node: node, message: self, fixIts: fixIts)])
    }
}

enum FactEntryFixIt: String, FixItMessage {
    case wrapInClosure

    var message: String {
        switch self {
        case .wrapInClosure: "call it in a closure"
        }
    }

    var fixItID: MessageID { MessageID(domain: "AstrolabeMacros", id: "FactEntry.\(rawValue)") }
}

// MARK: - Syntax

extension TypeSyntax {
    /// `T?` or `Optional<T>`, whose fact defaults to `nil`.
    var isOptional: Bool {
        if self.is(OptionalTypeSyntax.self) { return true }
        if let identifier = self.as(IdentifierTypeSyntax.self) {
            return identifier.name.text == "Optional" && identifier.genericArgumentClause != nil
        }
        if let member = self.as(MemberTypeSyntax.self) {
            return member.baseType.trimmedDescription == "Swift" && member.name.text == "Optional"
                && member.genericArgumentClause != nil
        }
        return false
    }
}

extension ClosureSignatureSyntax.ParameterClause {
    var hasParameters: Bool {
        switch self {
        case .simpleInput(let parameters): !parameters.isEmpty
        case .parameterClause(let clause): !clause.parameters.isEmpty
        }
    }
}

extension SyntaxProtocol {
    /// Removes the indentation every line shares, so code moved into the key is indented as
    /// the key. A multi-line string literal is left whole: its lines' indentation is its content.
    func unindented() -> Self {
        var shared = Int.max
        for token in tokens(viewMode: .sourceAccurate) where !token.isInMultilineString {
            if let width = token.leadingTrivia.lineIndentation {
                shared = min(shared, width)
            }
        }
        guard shared != .max, shared > 0 else { return self }
        return Unindenter(width: shared).rewrite(self).cast(Self.self)
    }
}

private final class Unindenter: SyntaxRewriter {
    let width: Int

    init(width: Int) {
        self.width = width
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> ExprSyntax {
        guard node.openingQuote.tokenKind == .multilineStringQuote else { return super.visit(node) }
        return ExprSyntax(node.with(\.leadingTrivia, node.leadingTrivia.removingIndentation(width)))
    }

    override func visit(_ token: TokenSyntax) -> TokenSyntax {
        token.with(\.leadingTrivia, token.leadingTrivia.removingIndentation(width))
    }
}

extension TokenSyntax {
    /// Inside a multi-line string literal, past its opening quote.
    var isInMultilineString: Bool {
        guard let string = ancestorOrSelf(mapping: { $0.as(StringLiteralExprSyntax.self) }) else { return false }
        return string.openingQuote.tokenKind == .multilineStringQuote && id != string.openingQuote.id
    }
}

extension Trivia {
    /// The width of the whitespace after the last newline, or `nil` without one.
    var lineIndentation: Int? {
        guard let newline = pieces.lastIndex(where: \.isNewline) else { return nil }
        return pieces[(newline + 1)...].reduce(0) { width, piece in
            switch piece {
            case .spaces(let count), .tabs(let count): width + count
            default: width
            }
        }
    }

    /// Up to `width` of the whitespace after each newline removed.
    func removingIndentation(_ width: Int) -> Trivia {
        var result: [TriviaPiece] = []
        var afterNewline = false
        for piece in pieces {
            switch piece {
            case .spaces(let count) where afterNewline:
                if count > width { result.append(.spaces(count - width)) }
            case .tabs(let count) where afterNewline:
                if count > width { result.append(.tabs(count - width)) }
            default:
                result.append(piece)
            }
            afterNewline = piece.isNewline
        }
        return Trivia(pieces: result)
    }
}
