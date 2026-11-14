import Foundation
import Testing

@testable import PuzzleQuestKit

@MainActor
@Suite(
    "Signing up and deleting an account, against a real server",
    .enabled(if: TestServer.url != nil, "set PQ_TEST_SERVER_URL (see scripts/start-test-server.sh)"),
    .serialized)
struct AccountContractTests {
    /// A session with the test server, signed out, and its model for signing up.
    func signUpModel() -> (SignUpModel, SessionStore) {
        let tokens = InMemoryTokenStore()
        let session = SessionStore(api: TestServer.api(tokens: tokens), tokens: tokens)
        return (SignUpModel(session: session), session)
    }

    func fill(_ model: SignUpModel, userName: String, email: String) {
        model.userName = userName
        model.password = TestServer.password
        model.confirmPassword = TestServer.password
        model.displayName = "Player \(userName)"
        model.email = email
    }

    @Test("Signing up makes the account and signs in as the new player, whose email isn't verified yet")
    func signsUp() async throws {
        let (model, session) = signUpModel()
        let userName = TestSite.unique("newbie")
        fill(model, userName: userName, email: "\(userName)@example.com")
        await model.signUp()
        #expect(model.failure == nil)
        #expect(model.fieldProblems.isEmpty)
        guard case .signedIn(let user) = session.state else {
            Issue.record("not signed in: \(session.state)")
            return
        }
        #expect(user.userName == userName)
        #expect(user.displayName == "Player \(userName)")
        #expect(user.role == .player)
        #expect(!user.emailVerified)
    }

    @Test("A user name or email address already in use is said to be, in the server's words")
    func alreadyInUse() async throws {
        let (first, _) = signUpModel()
        let userName = TestSite.unique("taken")
        fill(first, userName: userName, email: "\(userName)@example.com")
        await first.signUp()
        try #require(first.failure == nil)

        let (sameName, _) = signUpModel()
        fill(sameName, userName: userName, email: "other-\(userName)@example.com")
        await sameName.signUp()
        guard case .alreadyInUse(let nameTaken) = sameName.failure else {
            Issue.record("the user name wasn't refused: \(String(describing: sameName.failure))")
            return
        }
        #expect(nameTaken.localizedCaseInsensitiveContains("user name"))

        let (sameEmail, _) = signUpModel()
        fill(sameEmail, userName: TestSite.unique("other"), email: "\(userName)@example.com")
        await sameEmail.signUp()
        guard case .alreadyInUse(let emailTaken) = sameEmail.failure else {
            Issue.record("the email address wasn't refused: \(String(describing: sameEmail.failure))")
            return
        }
        #expect(emailTaken.localizedCaseInsensitiveContains("email"))
    }

    @Test("Deleting needs the right password, then signs out for good")
    func deletes() async throws {
        let (signUp, session) = signUpModel()
        let userName = TestSite.unique("leaving")
        fill(signUp, userName: userName, email: "\(userName)@example.com")
        await signUp.signUp()
        try #require(signUp.failure == nil)

        let delete = DeleteAccountModel(session: session)
        delete.password = "not the password"
        await delete.delete()
        #expect(delete.failure == .incorrectPassword)
        #expect(session.state != .signedOut)

        delete.password = TestServer.password
        await delete.delete()
        #expect(delete.failure == nil)
        #expect(session.state == .signedOut)

        // Gone: its name and password no longer sign in.
        await #expect(throws: APIError.self) {
            try await session.signIn(userName: userName, password: TestServer.password)
        }
    }
}
