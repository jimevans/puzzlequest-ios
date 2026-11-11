import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization

@testable import PuzzleQuestKit

/// Stands in for the network: answers each operation as a test says, and
/// remembers what was sent.
final class FakeTransport: ClientTransport {
    struct Sent: Sendable {
        var operationID: String
        var baseURL: URL
        var request: HTTPRequest
        var body: String?
    }

    typealias Answer = @Sendable (_ operationID: String) throws -> (HTTPResponse, HTTPBody?)

    private let answer: Answer
    private let sent = Mutex<[Sent]>([])

    init(_ answer: @escaping Answer) {
        self.answer = answer
    }

    var requests: [Sent] { sent.withLock { $0 } }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let text: String? =
            if let body { try await String(collecting: body, upTo: 1024 * 1024) } else { nil }
        sent.withLock { $0.append(Sent(operationID: operationID, baseURL: baseURL, request: request, body: text)) }
        return try answer(operationID)
    }
}

/// A response with a JSON body.
func json(_ status: Int, _ body: String, contentType: String = "application/json") -> (
    HTTPResponse, HTTPBody?
) {
    (
        HTTPResponse(status: .init(code: status), headerFields: [.contentType: contentType]),
        HTTPBody(body)
    )
}

/// A problem details response, as the API sends one.
func problem(_ status: Int, _ type: String) -> (HTTPResponse, HTTPBody?) {
    json(
        status,
        #"{"type":"\#(type)","title":"Refused","status":\#(status),"detail":"Refused."}"#,
        contentType: "application/problem+json")
}

let aliceJSON = #"""
    {"id":"u1","userName":"alice","displayName":"Alice A.","email":"alice@example.com",
     "emailVerified":true,"phone":"","sms":false,"role":"player"}
    """#
let alice = SignedInUser(
    userName: "alice", displayName: "Alice A.", role: .player, emailVerified: true)

func api(_ transport: FakeTransport, tokens: any TokenStore = InMemoryTokenStore()) -> APIClient {
    APIClient(
        server: URL(string: "https://example.com")!, tokens: tokens, transport: transport)
}
