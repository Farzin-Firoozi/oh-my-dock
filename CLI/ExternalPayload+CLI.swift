import Foundation
import OhMyDockCore

extension ExternalPayload {
    static func empty() -> ExternalPayload {
        try! JSONDecoder().decode(ExternalPayload.self, from: Data("{}".utf8))
    }
}
