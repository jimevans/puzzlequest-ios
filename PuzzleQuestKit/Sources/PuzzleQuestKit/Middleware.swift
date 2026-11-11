import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sends the session's token, when there is one, as `Authorization: Bearer`.
struct BearerTokenMiddleware: ClientMiddleware {
    let tokens: any TokenStore

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = tokens.read() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }
}

/// Turns every error response into `APIError.problem`, read from its problem
/// details, so callers handle refusals in one way whatever the operation.
/// A response without readable details becomes an `about:blank` problem with
/// its status, as RFC 9457 says a plain HTTP error is.
struct ProblemMiddleware: ClientMiddleware {
    /// Problem details are small; anything larger isn't one.
    private static let largestProblem = 64 * 1024

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard response.status.code >= 400 else {
            return (response, responseBody)
        }
        throw APIError.problem(
            await Self.problem(status: response.status, body: responseBody))
    }

    static func problem(status: HTTPResponse.Status, body: HTTPBody?) async -> Problem {
        let plain = Problem(
            type: "about:blank", status: status.code, title: status.reasonPhrase)
        guard let body,
            let data = try? await Data(collecting: body, upTo: largestProblem),
            let details = try? JSONDecoder().decode(Details.self, from: data)
        else { return plain }
        return Problem(
            type: details.type ?? plain.type,
            status: details.status ?? plain.status,
            title: details.title ?? plain.title,
            detail: details.detail)
    }

    /// Problem details, read leniently: any member may be missing, since
    /// this also reads the errors of servers in front of the API.
    private struct Details: Decodable {
        var type: String?
        var status: Int?
        var title: String?
        var detail: String?
    }
}
