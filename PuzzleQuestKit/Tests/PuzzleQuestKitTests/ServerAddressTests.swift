import Foundation
import Testing

@testable import PuzzleQuestKit

@Suite("Reading a server's address")
struct ServerOriginTests {
    @Test(
        "Addresses are reduced to their origin",
        arguments: [
            ("https://thepuzzlequest.com", "https://thepuzzlequest.com"),
            ("https://thepuzzlequest.com/", "https://thepuzzlequest.com"),
            ("  HTTPS://ThePuzzleQuest.COM  ", "https://thepuzzlequest.com"),
            ("thepuzzlequest.com", "https://thepuzzlequest.com"),
            ("staging.thepuzzlequest.com", "https://staging.thepuzzlequest.com"),
            ("https://thepuzzlequest.com:443", "https://thepuzzlequest.com"),
            ("http://localhost:80/", "http://localhost"),
            ("http://localhost:3000", "http://localhost:3000"),
            ("http://192.168.1.20:3000", "http://192.168.1.20:3000"),
            ("http://[::1]:3000", "http://[::1]:3000"),
        ])
    func normalises(typed: String, origin: String) throws {
        #expect(try ServerOrigin(parsing: typed).url.absoluteString == origin)
    }

    @Test("Production, typed, is Production")
    func production() throws {
        #expect(try ServerOrigin(parsing: "https://thepuzzlequest.com/") == .production)
        #expect(try ServerOrigin(parsing: "http://localhost:3000") == .thisMac)
    }

    @Test(
        "Anything but an origin is refused",
        arguments: [
            ("", ServerAddressRefusal.notAnAddress),
            ("   ", .notAnAddress),
            ("https://", .notAnAddress),
            ("not an address", .notAnAddress),
            ("https://evil%2ethepuzzlequest.com", .notAnAddress),
            ("https://.thepuzzlequest.com", .notAnAddress),
            ("https://thepuzzlequest..com", .notAnAddress),
            ("https://-x.thepuzzlequest.com", .notAnAddress),
            ("https://thepuzzlequest.com:99999", .notAnAddress),
            ("ftp://thepuzzlequest.com", .notAWebAddress),
            ("javascript://thepuzzlequest.com", .notAWebAddress),
            ("https://user@thepuzzlequest.com", .hasUserInfo),
            ("https://user:secret@thepuzzlequest.com", .hasUserInfo),
            ("https://thepuzzlequest.com@evil.example", .hasUserInfo),
            ("https://thepuzzlequest.com/api/v1", .notJustTheServer),
            ("https://thepuzzlequest.com?x=1", .notJustTheServer),
            ("https://thepuzzlequest.com/#top", .notJustTheServer),
        ])
    func refuses(typed: String, refusal: ServerAddressRefusal) {
        #expect(throws: refusal) { try ServerOrigin(parsing: typed) }
    }

    @Test(
        "It's named by its host, and its port if it has one",
        arguments: [
            ("https://thepuzzlequest.com", "thepuzzlequest.com"),
            ("https://staging.thepuzzlequest.com/", "staging.thepuzzlequest.com"),
            ("http://localhost:3000", "localhost:3000"),
        ])
    func displayName(typed: String, name: String) throws {
        #expect(try ServerOrigin(parsing: typed).displayName == name)
    }

    @Test("Its privacy policy is on its website")
    func privacyPolicy() throws {
        #expect(
            ServerOrigin.production.privacyPolicy.absoluteString
                == "https://thepuzzlequest.com/policies/privacy.html")
        #expect(
            try ServerOrigin(parsing: "http://localhost:3000").privacyPolicy.absoluteString
                == "http://localhost:3000/policies/privacy.html")
    }
}

@Suite("Which servers a build may use")
struct ServerAddressPolicyTests {
    @Test(
        "Release builds allow PuzzleQuest's own servers over HTTPS",
        arguments: [
            "https://thepuzzlequest.com",
            "thepuzzlequest.com",
            "https://staging.thepuzzlequest.com",
            "https://a.b.thepuzzlequest.com",
            "https://THEPUZZLEQUEST.COM:443/",
        ])
    func releaseAllows(typed: String) throws {
        let server = try ServerAddressPolicy.puzzleQuestDomain.check(typed)
        #expect(server.url.scheme == "https")
    }

    @Test(
        "Release builds refuse anything else",
        arguments: [
            ("http://thepuzzlequest.com", ServerAddressRefusal.notSecure),
            ("http://staging.thepuzzlequest.com", .notSecure),
            ("https://thepuzzlequest.com:8443", .hasPort),
            ("https://staging.thepuzzlequest.com:3000", .hasPort),
            ("https://thepuzzlequest.com.evil.example", .notPuzzleQuestServer),
            ("https://evilthepuzzlequest.com", .notPuzzleQuestServer),
            ("https://thepuzzlequest.co", .notPuzzleQuestServer),
            ("https://thepuzzlequest.com.", .notAnAddress),
            ("https://example.com", .notPuzzleQuestServer),
            ("https://localhost", .notPuzzleQuestServer),
            ("http://localhost:3000", .notSecure),
            ("https://203.0.113.7", .notPuzzleQuestServer),
            ("https://[2001:db8::1]", .notPuzzleQuestServer),
            ("https://user@thepuzzlequest.com", .hasUserInfo),
            ("https://thepuzzlequest.com?next=evil.example", .notJustTheServer),
            ("https://thepuzzlequest.com#evil.example", .notJustTheServer),
        ])
    func releaseRefuses(typed: String, refusal: ServerAddressRefusal) {
        #expect(throws: refusal) { try ServerAddressPolicy.puzzleQuestDomain.check(typed) }
    }

    @Test(
        "Debug builds allow any http or https server",
        arguments: [
            "http://localhost:3000",
            "http://192.168.1.20:3000",
            "https://example.com",
            "http://thepuzzlequest.com",
            "https://thepuzzlequest.com:8443",
            "http://[::1]:3000",
        ])
    func debugAllows(typed: String) throws {
        _ = try ServerAddressPolicy.anyAddress.check(typed)
    }

    @Test(
        "Debug builds still refuse what isn't a server's address",
        arguments: [
            ("ftp://example.com", ServerAddressRefusal.notAWebAddress),
            ("http://user:pw@localhost:3000", .hasUserInfo),
            ("http://localhost:3000/api", .notJustTheServer),
            ("", .notAnAddress),
        ])
    func debugRefuses(typed: String, refusal: ServerAddressRefusal) {
        #expect(throws: refusal) { try ServerAddressPolicy.anyAddress.check(typed) }
    }

    @Test("Both builds allow Production")
    func production() throws {
        try ServerAddressPolicy.puzzleQuestDomain.admit(.production)
        try ServerAddressPolicy.anyAddress.admit(.production)
        #expect(throws: ServerAddressRefusal.notSecure) {
            try ServerAddressPolicy.puzzleQuestDomain.admit(.thisMac)
        }
    }
}
