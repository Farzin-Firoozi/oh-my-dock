import Foundation

/// A response from the update endpoint: status code and (size-capped) body.
public struct HTTPFetchResponse: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// The one network seam. Live code uses `URLSessionFetcher`; tests use a fake, so no test
/// ever touches the network.
public protocol HTTPFetching: Sendable {
    /// Performs a GET. Implementations must stop reading and throw
    /// `UpdateCheckError.responseTooLarge` once the body exceeds `maxBytes`.
    func get(url: URL, headers: [String: String], timeout: TimeInterval, maxBytes: Int) async throws -> HTTPFetchResponse
}

/// A newer, stable release published on GitHub.
public struct ReleaseInfo: Sendable, Equatable {
    public var version: SemVer
    /// The release page (always an https GitHub URL).
    public var pageURL: URL
    /// Release notes, truncated to `UpdateChecker.maxNotesLength` characters.
    public var notes: String

    public init(version: SemVer, pageURL: URL, notes: String) {
        self.version = version
        self.pageURL = pageURL
        self.notes = notes
    }
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case available(ReleaseInfo)
}

public enum UpdateCheckError: Error, Equatable, Sendable, LocalizedError {
    case invalidCurrentVersion(String)
    case network(String)
    case httpStatus(Int)
    case responseTooLarge
    case malformedResponse
    case invalidReleaseURL

    public var errorDescription: String? {
        switch self {
        case let .invalidCurrentVersion(version): "This app's version (\(version)) is not a valid version number."
        case .network: "Could not reach GitHub. Check your connection and try again."
        case let .httpStatus(code): "GitHub answered with an unexpected status (\(code)). Try again later."
        case .responseTooLarge: "GitHub's answer was unexpectedly large and was ignored."
        case .malformedResponse: "GitHub's answer could not be understood."
        case .invalidReleaseURL: "GitHub returned an unexpected release link and it was ignored."
        }
    }
}

/// Asks GitHub Releases whether a newer stable version exists. Sends one GET with standard
/// headers and a User-Agent; nothing else about the user or machine is sent. It never downloads
/// or installs anything.
public struct UpdateChecker: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.github.com/repos/Farzin-Firoozi/oh-my-dock/releases/latest")!
    public static let maxResponseBytes = 256 * 1024
    public static let maxNotesLength = 4000
    public static let timeout: TimeInterval = 10

    private let fetcher: any HTTPFetching
    private let endpoint: URL
    private let userAgent: String

    public init(fetcher: any HTTPFetching, endpoint: URL = UpdateChecker.defaultEndpoint, userAgent: String = "oh-my-dock-update-check") {
        self.fetcher = fetcher
        self.endpoint = endpoint
        self.userAgent = userAgent
    }

    public func check(currentVersion: String) async throws -> UpdateCheckResult {
        guard let current = SemVer(currentVersion) else { throw UpdateCheckError.invalidCurrentVersion(currentVersion) }
        guard endpoint.scheme?.lowercased() == "https" else { throw UpdateCheckError.invalidReleaseURL }

        let response: HTTPFetchResponse
        do {
            response = try await fetcher.get(
                url: endpoint,
                headers: ["Accept": "application/vnd.github+json", "User-Agent": userAgent],
                timeout: Self.timeout,
                maxBytes: Self.maxResponseBytes
            )
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.network(String(describing: error))
        }

        // 404 = the repo has no published release yet.
        if response.statusCode == 404 { return .upToDate }
        guard (200 ..< 300).contains(response.statusCode) else { throw UpdateCheckError.httpStatus(response.statusCode) }
        guard response.body.count <= Self.maxResponseBytes else { throw UpdateCheckError.responseTooLarge }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: response.body)
        } catch {
            throw UpdateCheckError.malformedResponse
        }

        if payload.draft == true || payload.prerelease == true { return .upToDate }
        guard let latest = SemVer(payload.tagName) else { throw UpdateCheckError.malformedResponse }
        if latest.isPrerelease || latest <= current { return .upToDate }

        guard let url = URL(string: payload.htmlURL),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com"
        else { throw UpdateCheckError.invalidReleaseURL }

        return .available(ReleaseInfo(version: latest, pageURL: url, notes: String((payload.body ?? "").prefix(Self.maxNotesLength))))
    }

    private struct Payload: Decodable {
        var tagName: String
        var htmlURL: String
        var body: String?
        var draft: Bool?
        var prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft, prerelease
        }
    }
}

/// Live fetcher. Ephemeral session (no cookies/cache/credentials), https only, streams the body
/// and aborts as soon as the size cap is exceeded.
public struct URLSessionFetcher: HTTPFetching {
    public init() {}

    public func get(url: URL, headers: [String: String], timeout: TimeInterval, maxBytes: Int) async throws -> HTTPFetchResponse {
        guard url.scheme?.lowercased() == "https" else { throw UpdateCheckError.invalidReleaseURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.malformedResponse }
        if http.expectedContentLength > Int64(maxBytes) { throw UpdateCheckError.responseTooLarge }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > maxBytes { throw UpdateCheckError.responseTooLarge }
        }
        return HTTPFetchResponse(statusCode: http.statusCode, body: body)
    }
}
