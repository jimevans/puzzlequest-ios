import Foundation
import Testing

@testable import PuzzleQuestKit

@Suite(
    "Choosing a server, against a real server",
    .enabled(if: TestServer.url != nil, "set PQ_TEST_SERVER_URL (see scripts/start-test-server.sh)"))
struct ServerContractTests {
    @Test("The check before switching accepts a real PuzzleQuest server")
    func checkAccepts() async throws {
        let server = try ServerAddressPolicy.anyAddress.check(TestServer.url!.absoluteString)
        try await ServerCheck().check(server)
    }

    @Test("The check finds nothing where nothing listens")
    func checkUnreachable() async throws {
        // The test server's host, on a port nothing listens on.
        var components = URLComponents(url: TestServer.url!, resolvingAgainstBaseURL: false)!
        components.port = 9
        let server = try ServerOrigin(parsing: components.url!.absoluteString)
        await #expect(throws: ServerCheckFailure.unreachable) {
            try await ServerCheck().check(server)
        }
    }
}
