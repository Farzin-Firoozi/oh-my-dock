import Foundation
import Testing
@testable import OhMyDockCore

private final class FakeFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(url: URL, headers: [String: String], timeout: TimeInterval)] = []
    let result: Result<HTTPFetchResponse, any Error>

    init(_ result: Result<HTTPFetchResponse, any Error>) { self.result = result }
    convenience init(json: String, status: Int = 200) {
        self.init(.success(HTTPFetchResponse(statusCode: status, body: Data(json.utf8))))
    }

    var requests: [(url: URL, headers: [String: String], timeout: TimeInterval)] {
        lock.withLock { _requests }
    }

    func get(url: URL, headers: [String: String], timeout: TimeInterval, maxBytes: Int) async throws -> HTTPFetchResponse {
        lock.withLock { _requests.append((url, headers, timeout)) }
        return try result.get()
    }
}

private func release(
    tag: String = "v0.2.0",
    url: String = "https://github.com/Farzin-Firoozi/oh-my-dock/releases/tag/v0.2.0",
    body: String = "Notes",
    draft: Bool = false,
    prerelease: Bool = false
) -> String {
    let escaped = body.replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"tag_name":"\#(tag)","html_url":"\#(url)","body":"\#(escaped)","draft":\#(draft),"prerelease":\#(prerelease)}"#
}

@Suite struct SemVerTests {
    @Test func parsesVariants() {
        #expect(SemVer("1.2.3") == SemVer(major: 1, minor: 2, patch: 3))
        #expect(SemVer("v1.2.3") == SemVer(major: 1, minor: 2, patch: 3))
        #expect(SemVer("1.2") == SemVer(major: 1, minor: 2, patch: 0))
        #expect(SemVer("1.2.3+build5") == SemVer("1.2.3"))
        #expect(SemVer("1.2.3-beta.1")?.prerelease == ["beta", "1"])
    }

    @Test(arguments: ["", "v", "1.2.3.4", "a.b.c", "1..2", "1.2.-3", "1.2.3-", "1.2.3-be ta", "99999999999.0.0", "1.2.3-é"])
    func rejectsMalformed(_ text: String) {
        #expect(SemVer(text) == nil)
    }

    @Test func orders() throws {
        let ordered = ["0.0.1", "0.1.0", "0.9.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "2.0.0", "10.0.0"]
        let versions = try ordered.map { try #require(SemVer($0)) }
        for (lower, higher) in zip(versions, versions.dropFirst()) {
            #expect(lower < higher)
            #expect(!(higher < lower))
        }
    }

    @Test func numericNotLexicographic() throws {
        #expect(try #require(SemVer("0.10.0")) > #require(SemVer("0.9.0")))
    }
}

@Suite struct UpdateCheckerTests {
    private func check(_ fetcher: FakeFetcher, current: String = "0.1.0") async throws -> UpdateCheckResult {
        try await UpdateChecker(fetcher: fetcher).check(currentVersion: current)
    }

    @Test func newerReleaseIsAvailable() async throws {
        let result = try await check(FakeFetcher(json: release(tag: "v0.2.0")))
        guard case let .available(info) = result else { Issue.record("expected available"); return }
        #expect(info.version == SemVer("0.2.0"))
        #expect(info.pageURL.absoluteString == "https://github.com/Farzin-Firoozi/oh-my-dock/releases/tag/v0.2.0")
        #expect(info.notes == "Notes")
    }

    @Test func tagWithoutVPrefixWorks() async throws {
        let result = try await check(FakeFetcher(json: release(tag: "1.0.0")))
        #expect(result != .upToDate)
    }

    @Test func equalVersionIsUpToDate() async throws {
        #expect(try await check(FakeFetcher(json: release(tag: "v0.1.0"))) == .upToDate)
    }

    @Test func olderVersionIsUpToDate() async throws {
        #expect(try await check(FakeFetcher(json: release(tag: "v0.0.9"))) == .upToDate)
    }

    @Test func draftIsIgnored() async throws {
        #expect(try await check(FakeFetcher(json: release(tag: "v9.0.0", draft: true))) == .upToDate)
    }

    @Test func prereleaseFlagIsIgnored() async throws {
        #expect(try await check(FakeFetcher(json: release(tag: "v9.0.0", prerelease: true))) == .upToDate)
    }

    @Test func prereleaseTagIsIgnored() async throws {
        #expect(try await check(FakeFetcher(json: release(tag: "v9.0.0-rc.1"))) == .upToDate)
    }

    @Test func noReleasesYetIsUpToDate() async throws {
        #expect(try await check(FakeFetcher(json: "{}", status: 404)) == .upToDate)
    }

    @Test(arguments: ["not json", "[]", "{}", #"{"tag_name":"v1.0.0"}"#, #"{"tag_name":"nonsense","html_url":"https://github.com/x"}"#])
    func malformedJSONThrows(_ json: String) async {
        await #expect(throws: UpdateCheckError.malformedResponse) {
            try await check(FakeFetcher(json: json))
        }
    }

    @Test(arguments: [
        "http://github.com/Farzin-Firoozi/oh-my-dock/releases/tag/v0.2.0",
        "https://evil.example.com/releases/tag/v0.2.0",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "",
    ])
    func unsafeReleaseURLThrows(_ url: String) async {
        await #expect(throws: UpdateCheckError.invalidReleaseURL) {
            try await check(FakeFetcher(json: release(url: url)))
        }
    }

    @Test func hugeBodyThrows() async {
        let huge = Data(repeating: UInt8(ascii: "a"), count: UpdateChecker.maxResponseBytes + 1)
        let fetcher = FakeFetcher(.success(HTTPFetchResponse(statusCode: 200, body: huge)))
        await #expect(throws: UpdateCheckError.responseTooLarge) { try await check(fetcher) }
    }

    @Test func largeNotesAreTruncated() async throws {
        let notes = String(repeating: "x", count: 100_000)
        let result = try await check(FakeFetcher(json: release(body: notes)))
        guard case let .available(info) = result else { Issue.record("expected available"); return }
        #expect(info.notes.count == UpdateChecker.maxNotesLength)
    }

    @Test func serverErrorThrowsStatus() async {
        await #expect(throws: UpdateCheckError.httpStatus(500)) {
            try await check(FakeFetcher(json: "", status: 500))
        }
    }

    @Test func rateLimitThrowsStatus() async {
        await #expect(throws: UpdateCheckError.httpStatus(403)) {
            try await check(FakeFetcher(json: "{}", status: 403))
        }
    }

    @Test func transportFailureIsWrapped() async {
        struct Boom: Error {}
        let fetcher = FakeFetcher(.failure(Boom()))
        do {
            _ = try await check(fetcher)
            Issue.record("expected throw")
        } catch let error as UpdateCheckError {
            guard case .network = error else { Issue.record("expected network, got \(error)"); return }
        } catch {
            Issue.record("wrong error type \(error)")
        }
    }

    @Test func fetcherSizeErrorPassesThrough() async {
        let fetcher = FakeFetcher(.failure(UpdateCheckError.responseTooLarge))
        await #expect(throws: UpdateCheckError.responseTooLarge) { try await check(fetcher) }
    }

    @Test func invalidCurrentVersionThrowsWithoutNetwork() async {
        let fetcher = FakeFetcher(json: release())
        await #expect(throws: UpdateCheckError.invalidCurrentVersion("banana")) {
            try await check(fetcher, current: "banana")
        }
        #expect(fetcher.requests.isEmpty)
    }

    @Test func requestIsSingleHttpsGetWithUserAgentAndShortTimeout() async throws {
        let fetcher = FakeFetcher(json: release())
        _ = try await check(fetcher)
        #expect(fetcher.requests.count == 1)
        let request = try #require(fetcher.requests.first)
        #expect(request.url == UpdateChecker.defaultEndpoint)
        #expect(request.url.scheme == "https")
        #expect(request.headers["User-Agent"]?.isEmpty == false)
        #expect(Set(request.headers.keys) == ["Accept", "User-Agent"])
        #expect(request.timeout <= 15)
    }

    @Test func nonHttpsEndpointRefusedWithoutNetwork() async throws {
        let fetcher = FakeFetcher(json: release())
        let checker = UpdateChecker(fetcher: fetcher, endpoint: try #require(URL(string: "http://api.github.com/x")))
        await #expect(throws: UpdateCheckError.invalidReleaseURL) { try await checker.check(currentVersion: "0.1.0") }
        #expect(fetcher.requests.isEmpty)
    }
}
