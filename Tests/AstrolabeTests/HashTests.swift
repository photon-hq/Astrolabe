import CryptoKit
import Foundation
import Testing
@testable import Astrolabe

@Test func hashIsDeterministicLowercaseHex() {
    let hash = Hash.of("staging.file", "/tmp/a.txt", 3, true)
    #expect(hash == Hash.of("staging.file", "/tmp/a.txt", 3, true))
    #expect(hash.count == 64)
    #expect(hash.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })
}

@Test func hashMatchesTheDocumentedEncoding() {
    // tag 1 (string), UInt64 big-endian length 1, then "a".
    let bytes: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 1, 0x61]
    let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(Hash.of("a") == expected)
}

@Test func lengthPrefixesKeepBoundariesDistinct() {
    #expect(Hash.of("ab", "c") != Hash.of("a", "bc"))
    #expect(Hash.of(["a", "b"]) != Hash.of(["ab"]))
    #expect(Hash.of(["a", "b"]) != Hash.of("a", "b"))
    #expect(Hash.of([["a"], ["b"]]) != Hash.of([["a", "b"]]))
}

@Test func typeTagsKeepTypesDistinct() {
    #expect(Hash.of("1") != Hash.of(1))
    #expect(Hash.of(true) != Hash.of(1))
    #expect(Hash.of(false) != Hash.of(0))
}

@Test func optionalsAreDistinctFromEmptyValues() {
    let none: String? = nil
    let empty: String? = ""
    #expect(Hash.of(none) != Hash.of(empty))
    #expect(Hash.of(none) != Hash.of(""))
    #expect(Hash.of(empty) == Hash.of(Optional("")))
}

@Test func emptyHashesAreStable() {
    #expect(Hash.of() == Hash.of())
    #expect(Hash.of([String]()) != Hash.of())
}

// MARK: - Backoff

@Test func backoffDoublesFromInitialUpToMax() {
    let backoff = Backoff.standard
    #expect(backoff.delay(attempt: 1) == .seconds(15))
    #expect(backoff.delay(attempt: 2) == .seconds(30))
    #expect(backoff.delay(attempt: 3) == .seconds(60))
    #expect(backoff.delay(attempt: 7) == .seconds(960))
    #expect(backoff.delay(attempt: 8) == .seconds(1800))
    #expect(backoff.delay(attempt: 1000) == .seconds(1800))
    #expect(backoff.delay(attempt: 0) == .seconds(15))
}

@Test func retryPolicyDefaultsToStandardBackoff() {
    #expect(RetryPolicy.retry() == .retry(.standard))
    #expect(RetryPolicy.rollback().backoff == .standard)
    #expect(RetryPolicy.wait.backoff == nil)
    #expect(Backoff(initial: .seconds(1), max: .seconds(4)).delay(attempt: 5) == .seconds(4))
}
