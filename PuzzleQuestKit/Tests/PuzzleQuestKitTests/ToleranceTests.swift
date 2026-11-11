import Foundation
import PuzzleQuestAPI
import Testing

@testable import PuzzleQuestKit

/// Version 1 of the API may add response fields and enumerated values
/// (decision 0023 in the server repository); the generated client must read
/// such responses. These depend on scripts/tolerant-openapi.jq.
@Suite("Reading responses from a newer version 1")
struct ToleranceTests {
    @Test("A field the app doesn't know is ignored, and an unknown role is kept")
    func unknownFieldAndRole() async throws {
        let transport = FakeTransport { _ in
            json(
                200,
                #"""
                {"user":{"id":"u1","userName":"alice","displayName":"Alice A.",
                  "email":"alice@example.com","emailVerified":true,"phone":"","sms":false,
                  "role":"superuser","favouriteColour":"teal"},
                 "expiresAt":"2027-01-01T00:00:00.000Z"}
                """#)
        }
        let user = try await api(transport, tokens: InMemoryTokenStore(token: "t")).currentUser()
        #expect(
            user
                == SignedInUser(
                    userName: "alice", displayName: "Alice A.", role: .other("superuser"),
                    emailVerified: true))
    }

    @Test("Each known role is read as itself")
    func knownRoles() throws {
        for (value, role) in [("player", Role.player), ("staff", .staff), ("admin", .admin)] {
            let decoded = try JSONDecoder().decode(
                Components.Schemas.Role.self, from: Data(#""\#(value)""#.utf8))
            #expect(Role(decoded) == role)
        }
    }

    @Test("An unknown status decodes as a plain string")
    func unknownStatus() throws {
        let status = try JSONDecoder().decode(
            Components.Schemas.QuestStatus.self, from: Data(#""abandoned""#.utf8))
        #expect(status.value1 == nil)
        #expect(status.value2 == "abandoned")
        let known = try JSONDecoder().decode(
            Components.Schemas.QuestStatus.self, from: Data(#""inProgress""#.utf8))
        #expect(known.value1 == .inProgress)
    }

    @Test("A value that isn't set (null) is nil, and times may have milliseconds")
    func nullsAndTimes() throws {
        let decoder = JSONDecoder()
        let transcoder = APIDateTranscoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try transcoder.decode(decoder.singleValueContainer().decode(String.self))
        }
        let clock = try decoder.decode(
            Components.Schemas.Clock.self,
            from: Data(
                #"""
                {"startTime":"2026-11-11T16:05:34.120Z","endTime":null,"running":true,
                 "clockStart":"2026-11-11T16:00:00Z","elapsedMs":5,"penaltyMs":0,"totalMs":5,
                 "lapCount":3}
                """#.utf8))
        let startTime = try #require(clock.startTime)
        #expect(abs(startTime.timeIntervalSince1970 - 1_794_413_134.12) < 0.0001)
        #expect(clock.endTime == nil)
        #expect(clock.clockStart == Date(timeIntervalSince1970: 1_794_412_800))
    }
}
