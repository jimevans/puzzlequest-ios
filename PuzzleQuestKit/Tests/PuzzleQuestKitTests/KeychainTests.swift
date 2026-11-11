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
    /// Each test uses its own item, never the app's.
    private let store = KeychainTokenStore(service: "com.thepuzzlequest.PuzzleQuest.tests.\(UUID())")

    @Test("A saved token is read back, replaced, and deleted")
    func roundTrip() throws {
        defer { store.delete() }
        #expect(store.read() == nil)
        try store.save("first")
        #expect(store.read() == "first")
        try store.save("second")
        #expect(store.read() == "second")
        store.delete()
        #expect(store.read() == nil)
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
