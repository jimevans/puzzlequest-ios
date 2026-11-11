import Foundation
import OpenAPIRuntime

/// Reads the API's times, which are ISO 8601 in UTC with or without
/// milliseconds (the server sends them with). The runtime's own transcoders
/// each accept only one of the two.
struct APIDateTranscoder: DateTranscoder {
    private static let withFractionalSeconds = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true)
    private static let withoutFractionalSeconds = Date.ISO8601FormatStyle()

    func encode(_ date: Date) throws -> String {
        Self.withFractionalSeconds.format(date)
    }

    func decode(_ string: String) throws -> Date {
        if let date = try? Self.withFractionalSeconds.parse(string) {
            return date
        }
        return try Self.withoutFractionalSeconds.parse(string)
    }
}
