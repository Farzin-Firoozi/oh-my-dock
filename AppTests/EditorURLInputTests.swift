import Foundation
import Testing

@Suite struct EditorURLInputTests {
    @Test func acceptsHTTPSAndAddsScheme() throws {
        let url = try EditorURLInput.normalizedURL(from: "example.com").get()
        #expect(url.absoluteString == "https://example.com")
        #expect(try EditorURLInput.normalizedURL(from: "https://swift.org/docs").get().host() == "swift.org")
    }

    @Test func rejectsEmptyHTTPAndCredentials() {
        #expect(EditorURLInput.normalizedURL(from: "   ") == .failure(.empty))
        #expect(EditorURLInput.normalizedURL(from: "http://example.com") == .failure(.invalid))
        #expect(EditorURLInput.normalizedURL(from: "ftp://example.com") == .failure(.invalid))
        #expect(EditorURLInput.normalizedURL(from: "https://user:pass@example.com") == .failure(.invalid))
        #expect(EditorURLInput.normalizedURL(from: "https://") == .failure(.invalid))
    }
}
