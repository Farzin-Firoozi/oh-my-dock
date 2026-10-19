import Foundation

/// Parses and validates URL strings for new Dock link tiles (https only).
enum EditorURLInput: Sendable {
    enum Failure: Equatable, Sendable, Error {
        case empty
        case invalid
    }

    /// Trims whitespace, prepends `https://` when no scheme is present, and accepts only
    /// `https` URLs with a host and no embedded credentials.
    static func normalizedURL(from raw: String) -> Result<URL, Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        var work = trimmed
        if !work.contains("://") {
            work = "https://" + work
        }
        guard let url = URL(string: work),
              url.scheme?.lowercased() == "https",
              !(url.host() ?? "").isEmpty,
              url.user() == nil,
              url.password() == nil
        else {
            return .failure(.invalid)
        }
        return .success(url)
    }
}
