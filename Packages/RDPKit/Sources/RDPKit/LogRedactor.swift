import Foundation
import os

/// Removes what identifies a person or a computer from log text: the hosts,
/// user names, and domains of sessions, every password a session was given,
/// and anything shaped like an IP address.
///
/// Values are matched without regard to case. Values shorter than three
/// characters are not matched, because they would erase ordinary words.
public final class LogRedactor: Sendable {
    public enum Kind: Sendable {
        case host
        case user
        case secret

        var placeholder: String {
            switch self {
            case .host: "<host>"
            case .user: "<user>"
            case .secret: "<redacted>"
            }
        }
    }

    private struct State {
        var values: [String: Kind] = [:]
        var redactions = 0
    }

    static let minimumLength = 3
    private let state = OSAllocatedUnfairLock(initialState: State())

    // Constant patterns, exercised by the tests: they cannot fail at run time.
    // swiftlint:disable:next force_try
    private static let ipv4 = try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
    // Two or more colons between hex groups; also catches some timestamps
    // and fingerprints, which is harmless.
    // swiftlint:disable:next force_try
    private static let ipv6 = try! NSRegularExpression(
        pattern: #"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:%\w+)?(?![\w:])"#
    )

    public init() {}

    /// Starts redacting `value`. Adding the same value again is harmless.
    public func add(_ value: String, as kind: Kind) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumLength else { return }
        state.withLock { $0.values[trimmed.lowercased()] = kind }
    }

    /// Stops redacting `value`, for a password once its session has ended.
    public func remove(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        state.withLock { _ = $0.values.removeValue(forKey: key) }
    }

    /// How many replacements have been made so far. For tests.
    public var redactionCount: Int {
        state.withLock { $0.redactions }
    }

    /// The text with every known value and every IP address replaced.
    public func redact(_ text: String) -> String {
        let values = state.withLock { $0.values }
        var result = text
        var count = 0
        // Longest first, so a host is not cut up by a user name inside it.
        for (value, kind) in values.sorted(by: { $0.key.count > $1.key.count }) {
            var searchRange = result.startIndex..<result.endIndex
            while let range = result.range(of: value, options: .caseInsensitive, range: searchRange) {
                result.replaceSubrange(range, with: kind.placeholder)
                count += 1
                let resume = result.index(range.lowerBound, offsetBy: kind.placeholder.count)
                searchRange = resume..<result.endIndex
            }
        }
        for pattern in [Self.ipv4, Self.ipv6] {
            let whole = NSRange(result.startIndex..., in: result)
            let matches = pattern.numberOfMatches(in: result, range: whole)
            guard matches > 0 else { continue }
            result = pattern.stringByReplacingMatches(in: result, range: whole, withTemplate: "<address>")
            count += matches
        }
        if count > 0 {
            state.withLock { $0.redactions += count }
        }
        return result
    }
}
