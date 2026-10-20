import Foundation

enum CallbackURLValidator {
    private static let forbiddenSchemes: Set<String> = [
        "http", "https", "file", "javascript", "data", "ohmydock", "about", "blob", "ftp",
    ]

    /// Returns the callback URL when legal; rejects `http`/`https` and other blocked schemes.
    static func legalCallbackURL(from raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil else { return nil }
        guard !forbiddenSchemes.contains(scheme) else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        return url
    }
}
