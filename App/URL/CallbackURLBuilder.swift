import Foundation
import OhMyDockCore

enum CallbackURLBuilder {
    static func successURL(base: URL, result: ExternalResult) -> URL? {
        successURL(
            base: base,
            status: result.envelope.result?.status,
            profileName: result.envelope.result?.profile?.name,
            profileID: result.envelope.result?.profile?.id
        )
    }

    static func successURL(
        base: URL,
        status: String?,
        profileName: String? = nil,
        profileID: String? = nil
    ) -> URL? {
        var params: [String: String] = [:]
        if let status { params["status"] = status }
        if let profileName { params["profile"] = profileName }
        if let profileID { params["profileID"] = profileID }
        return append(params, to: base)
    }

    static func errorURL(base: URL, errorCode: String, message: String) -> URL? {
        append(["errorCode": errorCode, "errorMessage": String(message.prefix(200))], to: base)
    }

    static func errorURL(base: URL, result: ExternalResult) -> URL? {
        let code = result.envelope.error?.code ?? "error"
        return errorURL(base: base, errorCode: code, message: result.message)
    }

    private static func append(_ params: [String: String], to base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        for key in params.keys.sorted() {
            items.append(URLQueryItem(name: key, value: params[key]))
        }
        components.queryItems = items
        return components.url
    }
}
