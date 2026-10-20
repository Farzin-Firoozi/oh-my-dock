import Foundation

enum URLQueryParsing {
    /// Parses query pairs from `percentEncodedQuery` without treating `+` as space.
    static func parsePairs(percentEncodedQuery: String?) -> [String: String] {
        guard let percentEncodedQuery, !percentEncodedQuery.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in percentEncodedQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { continue }
            let name = decode(String(rawName)) ?? String(rawName)
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let value = decode(rawValue) ?? rawValue
            result[name] = value
        }
        return result
    }

    private static func decode(_ raw: String) -> String? {
        raw.removingPercentEncoding
    }
}
