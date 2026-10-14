import CryptoKit
import Foundation

/// Stable hashing for `Resource.compute`.
///
/// Each part is written as a type tag, a big-endian length, and its bytes, and the whole stream
/// is SHA-256'd. The length prefixes keep `("ab", "c")` distinct from `("a", "bc")`. It avoids
/// `JSONEncoder` (whose output isn't guaranteed stable across Foundation versions) and
/// `hashValue` (which is seeded per process).
public enum Hash {
    /// The lowercase hex SHA-256 of `parts`.
    ///
    /// ```swift
    /// Hash.of("staging.file", f.path, f.contents)
    /// ```
    public static func of(_ parts: any HashPart...) -> String {
        of(parts: parts)
    }

    /// `of(_:)` over an array. Labelled: unlabelled, `[String]` would pick it over the variadic
    /// form, and hash as its elements rather than as one array.
    static func of(parts: [any HashPart]) -> String {
        var encoder = HashEncoder()
        for part in parts { part.encode(into: &encoder) }
        return SHA256.hash(data: encoder.bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// A value `Hash.of` accepts: `String`, `Int`, `Bool`, optionals, and arrays of those.
public protocol HashPart {
    func encode(into encoder: inout HashEncoder)
}

/// The byte stream `Hash.of` digests.
public struct HashEncoder {
    fileprivate(set) var bytes: [UInt8] = []

    fileprivate init() {}

    /// Appends `tag`, the length of `payload`, then `payload`.
    fileprivate mutating func append(tag: Tag, _ payload: some Collection<UInt8>) {
        bytes.append(tag.rawValue)
        bytes.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init))
        bytes.append(contentsOf: payload)
    }

    /// Appends `tag`, then the length and bytes of whatever `body` encodes.
    fileprivate mutating func appendNested(tag: Tag, _ body: (inout HashEncoder) -> Void) {
        var nested = HashEncoder()
        body(&nested)
        append(tag: tag, nested.bytes)
    }

    fileprivate enum Tag: UInt8 {
        case string = 1, int, bool, none, some, array
    }
}

extension String: HashPart {
    public func encode(into encoder: inout HashEncoder) {
        encoder.append(tag: .string, Array(utf8))
    }
}

extension Int: HashPart {
    public func encode(into encoder: inout HashEncoder) {
        encoder.append(tag: .int, withUnsafeBytes(of: Int64(self).bigEndian, Array.init))
    }
}

extension Bool: HashPart {
    public func encode(into encoder: inout HashEncoder) {
        encoder.append(tag: .bool, [self ? 1 : 0])
    }
}

extension Optional: HashPart where Wrapped: HashPart {
    public func encode(into encoder: inout HashEncoder) {
        switch self {
        case .none: encoder.append(tag: .none, [])
        case .some(let value): encoder.appendNested(tag: .some) { value.encode(into: &$0) }
        }
    }
}

extension Array: HashPart where Element: HashPart {
    public func encode(into encoder: inout HashEncoder) {
        encoder.appendNested(tag: .array) { nested in
            for element in self { element.encode(into: &nested) }
        }
    }
}
