import Foundation

/// In-memory dedupe and mutating-command rate limit for one app launch (design §5).
struct URLCommandDeduper {
    private var lastKeys: [String: Date] = [:]
    private var inFlightKeys: Set<String> = []
    private var lastMutatingStarted: Date?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    enum Decision: Equatable {
        case proceed
        case duplicate
        case rateLimited
    }

    mutating func begin(host: String, query: [String: String], isMutating: Bool) -> Decision {
        let key = dedupeKey(host: host, query: query)
        let instant = now()

        if let previous = lastKeys[key], instant.timeIntervalSince(previous) < 1.0 {
            return .duplicate
        }
        if inFlightKeys.contains(key) {
            return .duplicate
        }

        if isMutating {
            if let last = lastMutatingStarted, instant.timeIntervalSince(last) < 2.0 {
                return .rateLimited
            }
            lastMutatingStarted = instant
        }

        lastKeys[key] = instant
        inFlightKeys.insert(key)
        return .proceed
    }

    mutating func finish(host: String, query: [String: String]) {
        inFlightKeys.remove(dedupeKey(host: host, query: query))
    }

    private func dedupeKey(host: String, query: [String: String]) -> String {
        let filtered = query.filter { $0.key != "x-success" && $0.key != "x-error" }
        let pairs = filtered.keys.sorted().map { "\($0)=\(filtered[$0] ?? "")" }
        return host + "?" + pairs.joined(separator: "&")
    }
}
