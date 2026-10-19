import Foundation

/// A semantic version (`1.2.3`, `1.2.3-beta.1`, `1.2.3+build`). A leading `v` is accepted, and a
/// missing minor or patch component counts as 0, so `1.2` equals `1.2.0`. Build metadata is
/// ignored when comparing, per the SemVer spec.
public struct SemVer: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated pre-release identifiers; empty for a stable release.
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Returns nil for anything that is not a well-formed version.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }

        var core = text
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            core = String(text[..<dash])
            let rest = String(text[text.index(after: dash)...])
            pre = rest.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy(Self.isValidIdentifier) else { return nil }
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Self.parseNumber(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A pre-release sorts below the release it precedes.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (a?, b?): return a < b
            case (.some, nil): return true // numeric identifiers sort below alphanumeric
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func parseNumber(_ part: Substring) -> Int? {
        guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(part)
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
