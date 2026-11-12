import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Checks that a server someone has typed is there, and is a PuzzleQuest
/// server this app can use, before the app switches to it: it fetches the
/// API's description, `/api/v1/openapi.json`, and reads its title and version.
public struct ServerCheck: Sendable {
    /// The title PuzzleQuest's API gives itself.
    static let apiTitle = "PuzzleQuest API"
    /// The description is a few hundred kilobytes; anything much larger isn't
    /// one.
    private static let largestDescription = 8 * 1024 * 1024

    private let transport: any ClientTransport

    public init() {
        // Not as long as a request's usual minute: someone is waiting, and a
        // mistyped address should be explained soon.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.init(
            transport: URLSessionTransport(
                configuration: .init(session: URLSession(configuration: configuration))))
    }

    package init(transport: any ClientTransport) {
        self.transport = transport
    }

    /// Fetches the server's API description and checks it's PuzzleQuest's,
    /// version 1.
    public func check(_ server: ServerOrigin) async throws(ServerCheckFailure) {
        let request = HTTPRequest(
            method: .get, scheme: nil, authority: nil, path: "/api/v1/openapi.json",
            headerFields: [.accept: "application/json"])
        let data: Data
        do {
            let (response, body) = try await transport.send(
                request, body: nil, baseURL: server.url, operationID: "getAPIDescription")
            guard response.status == .ok, let body else { throw ServerCheckFailure.notPuzzleQuest }
            data = try await Data(collecting: body, upTo: Self.largestDescription)
        } catch let failure as ServerCheckFailure {
            throw failure
        } catch is URLError {
            throw .unreachable
        } catch {
            // Too large, or cut off: whatever answered isn't the API.
            throw .notPuzzleQuest
        }
        guard let description = try? JSONDecoder().decode(Description.self, from: data),
            description.info.title == Self.apiTitle
        else { throw .notPuzzleQuest }
        // Version 1 only grows, so any 1.x will do; a later version would be
        // served under /api/v2, so this shouldn't change.
        guard description.info.version.split(separator: ".").first == "1" else {
            throw .unsupportedVersion
        }
    }

    /// As much of an OpenAPI description as the check reads.
    private struct Description: Decodable {
        struct Info: Decodable {
            var title: String
            var version: String
        }
        var info: Info
    }
}

/// Why the app won't switch to a server.
public enum ServerCheckFailure: Error, Equatable, Sendable {
    /// Nothing answered: the address is wrong, or the server or the network
    /// is down.
    case unreachable
    /// Something answered, but it isn't a PuzzleQuest server.
    case notPuzzleQuest
    /// It's a PuzzleQuest server, but its API isn't version 1.
    case unsupportedVersion
}
