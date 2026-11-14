import Foundation
import HTTPTypes
import Testing

@testable import PuzzleQuestKit

/// A refusal naming the fields it's about, as the API sends one.
func fieldProblem(_ status: Int, _ type: String, _ errors: [(String, String)]) -> HTTPAnswer {
    let list = errors.map { #"{"path":"\#($0.0)","message":"\#($0.1)"}"# }.joined(separator: ",")
    return json(
        status,
        #"{"type":"\#(type)","title":"Refused","status":\#(status),"errors":[\#(list)]}"#,
        contentType: "application/problem+json")
}

@MainActor
@Suite("Signing up")
struct SignUpTests {
    /// A sign-up form filled in rightly.
    func filled(_ model: SignUpModel) {
        model.userName = " newbie "
        model.password = "a long enough password"
        model.confirmPassword = "a long enough password"
        model.displayName = "New Player"
        model.email = "newbie@example.com"
    }

    func model(_ transport: FakeTransport) -> (SignUpModel, SessionStore, InMemoryTokenStore) {
        let tokens = InMemoryTokenStore()
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        return (SignUpModel(session: session), session, tokens)
    }

    @Test("It signs up with what's typed, then signs in as the new player")
    func signsUpAndIn() async throws {
        let transport = FakeTransport { operation in
            operation == "createUser"
                ? json(201, aliceJSON) : json(201, #"{"user":\#(aliceJSON),"token":"new-token"}"#)
        }
        let (model, session, tokens) = model(transport)
        filled(model)
        model.phone = " (312) 555-0142 "
        model.sms = true
        await model.signUp()

        #expect(transport.requests.map(\.operationID) == ["createUser", "signIn"])
        let body = try #require(transport.requests.first?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(sent["userName"] as? String == "newbie")
        #expect(sent["password"] as? String == "a long enough password")
        #expect(sent["displayName"] as? String == "New Player")
        #expect(sent["email"] as? String == "newbie@example.com")
        #expect(sent["phone"] as? String == "(312) 555-0142")
        #expect(sent["sms"] as? Bool == true)
        // An app may not choose its role; nothing else is sent.
        #expect(sent["role"] == nil)
        #expect(sent["confirmPassword"] == nil)
        #expect(session.state == .signedIn(alice))
        #expect(tokens.read() == "new-token")
        #expect(model.failure == nil)
    }

    @Test("Without a phone number, none is sent")
    func noPhone() async throws {
        let transport = FakeTransport { operation in
            operation == "createUser"
                ? json(201, aliceJSON) : json(201, #"{"user":\#(aliceJSON),"token":"t"}"#)
        }
        let (model, _, _) = model(transport)
        filled(model)
        model.phone = "  "
        await model.signUp()
        let body = try #require(transport.requests.first?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(sent["phone"] == nil)
        #expect(sent["sms"] as? Bool == false)
    }

    @Test("What's missing or wrong is found before anything is sent")
    func checksFirst() async {
        let transport = FakeTransport { _ in
            Issue.record("nothing should be sent")
            return json(500, "{}")
        }
        let (model, session, _) = model(transport)
        model.password = "short"
        model.confirmPassword = "shorter"
        model.email = "   "
        await model.signUp()
        #expect(
            model.fieldProblems == [
                .userName: .required, .password: .passwordTooShort,
                .confirmPassword: .passwordsDiffer, .displayName: .required, .email: .required,
            ])
        #expect(session.state == .restoring)

        model.edited(.email)
        #expect(model.fieldProblems[.email] == nil)
    }

    @Test("A user name or email address already in use is explained in the server's words")
    func alreadyExists() async {
        let transport = FakeTransport { _ in
            json(
                409,
                #"{"type":"/problems/already-exists","title":"Already exists","status":409,"detail":"That user name is already in use"}"#,
                contentType: "application/problem+json")
        }
        let (model, session, _) = model(transport)
        filled(model)
        await model.signUp()
        #expect(model.failure == .alreadyInUse("That user name is already in use"))
        #expect(model.fieldProblems.isEmpty)
        #expect(session.state == .restoring)
    }

    @Test("A refusal that names its field is shown at the field")
    func fieldNamed() async {
        let transport = FakeTransport { _ in
            fieldProblem(
                409, "/problems/already-exists", [("body.userName", "That user name is already in use")])
        }
        let (model, session, _) = model(transport)
        filled(model)
        await model.signUp()
        #expect(model.fieldProblems == [.userName: .server("That user name is already in use")])
        #expect(model.failure == nil)
        #expect(session.state == .restoring)
        #expect(!model.isSigningUp)
    }

    @Test("A password the server won't take is shown at the password")
    func passwordNotAllowed() async {
        let transport = FakeTransport { _ in problem(422, "/problems/password-not-allowed") }
        let (model, _, _) = model(transport)
        filled(model)
        await model.signUp()
        #expect(model.fieldProblems == [.password: .server("Refused.")])
    }

    @Test("Other refusals are explained above the form")
    func otherFailures() async {
        for (answer, expected): (HTTPAnswer?, SignUpFailure) in [
            (problem(429, "/problems/too-many-requests"), .tooManyAttempts),
            (problem(500, "/problems/unexpected"), .unexpected),
            (nil, .unreachable),
        ] {
            let transport = FakeTransport { _ in
                guard let answer else { throw URLError(.notConnectedToInternet) }
                return answer
            }
            let (model, _, _) = model(transport)
            filled(model)
            await model.signUp()
            #expect(model.failure == expected)
            #expect(model.fieldProblems.isEmpty)
        }
    }

    @Test("If signing in fails once the account is made, the player is told to sign in")
    func signedUpButNotIn() async {
        let transport = FakeTransport { operation in
            operation == "createUser" ? json(201, aliceJSON) : problem(500, "/problems/unexpected")
        }
        let (model, session, _) = model(transport)
        filled(model)
        await model.signUp()
        #expect(model.failure == .signedUpButNotSignedIn)
        #expect(session.state == .restoring)
    }
}

@MainActor
@Suite("Deleting an account")
struct DeleteAccountTests {
    /// A session signed in as alice, and its model for deleting.
    func signedIn(_ transport: FakeTransport) async throws -> (
        DeleteAccountModel, SessionStore, InMemoryTokenStore
    ) {
        let tokens = InMemoryTokenStore(token: "kept")
        let session = SessionStore(api: api(transport, tokens: tokens), tokens: tokens)
        await session.restore()
        try #require(session.state == .signedIn(alice))
        return (DeleteAccountModel(session: session), session, tokens)
    }

    @Test("It deletes the player's own account with their password, and signs out")
    func deletes() async throws {
        let transport = FakeTransport { operation in
            operation == "deleteUser"
                ? (HTTPResponse(status: .noContent), nil) : json(200, #"{"user":\#(aliceJSON)}"#)
        }
        let (model, session, tokens) = try await signedIn(transport)
        #expect(!model.canDelete)
        model.password = "secret"
        await model.delete()

        let sent = try #require(transport.requests.last)
        #expect(sent.operationID == "deleteUser")
        #expect(sent.request.method == .delete)
        #expect(sent.request.path == "/users/alice")
        let body = try #require(sent.body)
        let fields = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(fields?["password"] as? String == "secret")
        #expect(session.state == .signedOut)
        #expect(tokens.read() == nil)
        #expect(model.failure == nil)
    }

    @Test("Refusals are explained, and the player stays signed in")
    func refusals() async throws {
        for (answer, expected): (HTTPAnswer?, DeleteAccountFailure) in [
            (problem(422, "/problems/incorrect-password"), .incorrectPassword),
            (problem(429, "/problems/too-many-requests"), .tooManyAttempts),
            (problem(409, "/problems/wrong-state"), .notPossible),
            (problem(500, "/problems/unexpected"), .unexpected),
            (nil, .unreachable),
        ] {
            let transport = FakeTransport { operation in
                guard operation == "deleteUser" else { return json(200, #"{"user":\#(aliceJSON)}"#) }
                guard let answer else { throw URLError(.notConnectedToInternet) }
                return answer
            }
            let (model, session, tokens) = try await signedIn(transport)
            model.password = "wrong"
            await model.delete()
            #expect(model.failure == expected)
            #expect(session.state == .signedIn(alice))
            #expect(tokens.read() == "kept")
            #expect(!model.isDeleting)
        }
    }
}

@Suite("Reading problem details")
struct FieldErrorTests {
    @Test("A problem's errors are read, by where they are")
    func errors() async {
        let (response, body) = fieldProblem(
            400, "/problems/invalid-request",
            [("body.email", "Not an email address"), ("body.phone", "Not a phone number")])
        let problem = await ProblemMiddleware.problem(status: response.status, body: body)
        #expect(
            problem.errors == [
                FieldError(path: "body.email", message: "Not an email address"),
                FieldError(path: "body.phone", message: "Not a phone number"),
            ])
    }
}
