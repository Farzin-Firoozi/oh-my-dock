import Foundation

enum OhMyDockURLParser {
    static let forbiddenAuthorizationKeys: Set<String> = ["allowQuit", "yes", "force", "quit"]

    enum Route: Equatable {
        case apply(profile: String)
        case save(name: String?)
        case undo
        case open(window: OpenWindow)
        case importRemote(url: String)
    }

    enum OpenWindow: String, Equatable {
        case editor, history, settings
    }

    enum ParseFailure: Error, Equatable {
        case invalidURL
        case wrongScheme
        case forbiddenAuthorization
        case illegalCallback
        case unknownHost
        case usage(String, errorCallback: URL? = nil)

        var errorCallback: URL? {
            switch self {
            case let .usage(_, callback): callback
            case .invalidURL, .wrongScheme, .forbiddenAuthorization, .illegalCallback, .unknownHost: nil
            }
        }
    }

    struct Parsed: Equatable {
        var route: Route
        var query: [String: String]
        var successCallback: URL?
        var errorCallback: URL?
    }

    static func parse(_ url: URL) -> Result<Parsed, ParseFailure> {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.invalidURL)
        }
        guard components.scheme?.lowercased() == "ohmydock" else {
            return .failure(.wrongScheme)
        }
        if !components.path.isEmpty, components.path != "/" {
            return .failure(.invalidURL)
        }

        let query = URLQueryParsing.parsePairs(percentEncodedQuery: components.percentEncodedQuery)
        if query.keys.contains(where: forbiddenAuthorizationKeys.contains) {
            return .failure(.forbiddenAuthorization)
        }

        var successCallback: URL?
        var errorCallback: URL?
        if let raw = query["x-success"] {
            guard let legal = CallbackURLValidator.legalCallbackURL(from: raw) else {
                return .failure(.illegalCallback)
            }
            successCallback = legal
        }
        if let raw = query["x-error"] {
            guard let legal = CallbackURLValidator.legalCallbackURL(from: raw) else {
                return .failure(.illegalCallback)
            }
            errorCallback = legal
        }

        guard let host = components.host, !host.isEmpty else {
            return .failure(.usage("Missing command.", errorCallback: errorCallback))
        }

        let route: Route
        switch host.lowercased() {
        case "apply":
            guard let profile = query["profile"], !profile.isEmpty else {
                return .failure(.usage("apply requires profile.", errorCallback: errorCallback))
            }
            route = .apply(profile: profile)
        case "save":
            let name = query["name"].flatMap { $0.isEmpty ? nil : $0 }
            route = .save(name: name)
        case "undo":
            route = .undo
        case "open":
            guard let raw = query["window"], let window = OpenWindow(rawValue: raw.lowercased()) else {
                return .failure(.usage("open requires window=editor|history|settings.", errorCallback: errorCallback))
            }
            route = .open(window: window)
        case "import":
            let allowedKeys: Set<String> = ["url", "x-success", "x-error"]
            if query.keys.contains(where: { !allowedKeys.contains($0) }) {
                return .failure(.usage("import allows only url, x-success, and x-error.", errorCallback: errorCallback))
            }
            guard let remote = query["url"], !remote.isEmpty else {
                return .failure(.usage("import requires url.", errorCallback: errorCallback))
            }
            route = .importRemote(url: remote)
        default:
            return .failure(.unknownHost)
        }

        return .success(Parsed(route: route, query: query, successCallback: successCallback, errorCallback: errorCallback))
    }
}
