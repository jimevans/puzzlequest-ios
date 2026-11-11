import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import PuzzleQuestKit

@Suite("Explaining why signing in failed")
struct ErrorMappingTests {
    @Test(
        "A problem's type says what to tell the person",
        arguments: [
            (401, "/problems/sign-in-failed", SignInFailure.wrongUserNameOrPassword),
            (429, "/problems/too-many-requests", .tooManyAttempts),
            (400, "/problems/invalid-request", .invalidRequest),
            (500, "/problems/unexpected", .unexpected),
            (409, "/problems/something-new", .unexpected),
        ])
    func problemTypes(status: Int, type: String, failure: SignInFailure) async {
        let transport = FakeTransport { _ in problem(status, type) }
        do {
            _ = try await api(transport).signIn(userName: "alice", password: "wrong")
            Issue.record("signing in should have failed")
        } catch {
            #expect(error == .problem(Problem(type: type, status: status, title: "Refused", detail: "Refused.")))
            #expect(SignInFailure(error) == failure)
        }
    }

    @Test("No connection means the server can't be reached")
    func unreachable() async {
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: APIError.unreachable) {
            _ = try await api(transport).signIn(userName: "alice", password: "secret")
        }
        #expect(SignInFailure(.unreachable) == .unreachable)
    }

    @Test("An error without problem details is a plain HTTP problem")
    func plainHTTPError() async {
        let transport = FakeTransport { _ in
            (HTTPResponse(status: .badGateway, headerFields: [.contentType: "text/html"]),
             HTTPBody("<h1>Bad gateway</h1>"))
        }
        await #expect(
            throws: APIError.problem(Problem(type: "about:blank", status: 502, title: "Bad Gateway"))
        ) {
            _ = try await api(transport).currentUser()
        }
    }

    @Test("A success the app can't read is an unexpected response")
    func unreadableSuccess() async {
        let transport = FakeTransport { _ in json(201, #"{"user":{"userName":"alice"}}"#) }
        do {
            _ = try await api(transport).signIn(userName: "alice", password: "secret")
            Issue.record("signing in should have failed")
        } catch {
            guard case .unexpectedResponse = error else {
                Issue.record("expected an unexpected response, got \(error)")
                return
            }
            #expect(SignInFailure(error) == .unexpected)
        }
    }
}
