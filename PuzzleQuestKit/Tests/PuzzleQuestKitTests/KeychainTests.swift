import Foundation
import Testing

@testable import PuzzleQuestKit

/// On the Mac (`swift test`) only: in the simulator, a package's tests run
/// without an app, and the Keychain refuses a program without one
/// (errSecMissingEntitlement). The UI tests cover the app's own Keychain, by
/// relaunching it signed in.
#if os(macOS)
    private let keychainAvailable = true
#else
    private let keychainAvailable = false
#endif

@Suite(
    "Keeping the token in the Keychain",
    .enabled(if: keychainAvailable, "needs an app in the simulator; see the UI tests"))
struct KeychainTests {
    /// Each test uses its own items, never the app's.
    private let vault = KeychainTokenVault(service: "com.thepuzzlequest.PuzzleQuest.tests.\(UUID())")
    private let staging = try! ServerOrigin(parsing: "https://staging.thepuzzlequest.com")

    @Test("A saved token is read back, replaced, and deleted")
    func roundTrip() throws {
        defer { vault.forgetAll() }
        let store = vault.tokens(for: .production)
        #expect(store.read() == nil)
        try store.save("first")
        #expect(store.read() == "first")
        try store.save("second")
        #expect(store.read() == "second")
        store.delete()
        #expect(store.read() == nil)
    }

    @Test("Each server's token is kept apart, and all can be forgotten")
    func perServer() throws {
        defer { vault.forgetAll() }
        try vault.tokens(for: .production).save("production's")
        try vault.tokens(for: staging).save("staging's")
        #expect(vault.tokens(for: .production).read() == "production's")
        #expect(vault.tokens(for: staging).read() == "staging's")

        vault.tokens(for: staging).delete()
        #expect(vault.tokens(for: staging).read() == nil)
        #expect(vault.tokens(for: .production).read() == "production's")

        try vault.tokens(for: staging).save("staging's")
        vault.forgetAll()
        #expect(vault.tokens(for: .production).read() == nil)
        #expect(vault.tokens(for: staging).read() == nil)
    }
}

@Suite("Reading the API's times")
struct DateTranscoderTests {
    @Test("With or without milliseconds", arguments: [
        ("2026-11-11T16:05:34.000Z", 1_794_413_134.0),
        ("2026-11-11T16:05:34Z", 1_794_413_134.0),
        ("2026-11-11T16:05:34.250Z", 1_794_413_134.25),
    ])
    func decode(text: String, seconds: Double) throws {
        #expect(try APIDateTranscoder().decode(text) == Date(timeIntervalSince1970: seconds))
    }

    @Test("Something that isn't a time is refused")
    func refuses() {
        #expect(throws: (any Error).self) { try APIDateTranscoder().decode("yesterday") }
    }
}
