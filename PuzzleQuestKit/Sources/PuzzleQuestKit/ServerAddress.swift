import Foundation

/// A PuzzleQuest server, by its origin: a scheme, a host, and a port only when
/// it isn't the scheme's usual one, such as https://thepuzzlequest.com. The
/// API is under its `/api/v1`, and its website at the origin itself.
public struct ServerOrigin: Hashable, Sendable {
    /// The origin as an address, with nothing after the host and port (not
    /// even a `/`).
    public let url: URL

    /// PuzzleQuest's own site, the server every build starts with.
    public static let production = ServerOrigin(trusted: "https://thepuzzlequest.com")
    /// A server running on the Mac itself, as the server repository's
    /// `npm run dev` starts one; reachable from the simulator, for debug
    /// builds.
    public static let thisMac = ServerOrigin(trusted: "http://localhost:3000")

    private init(trusted address: String) {
        url = URL(string: address)!
    }

    private init(scheme: String, encodedHost: String, port: Int?) {
        var components = URLComponents()
        components.scheme = scheme
        components.percentEncodedHost = encodedHost
        components.port = port
        url = components.url!
    }

    /// How the server is named to people: its host, with its port when it has
    /// one, such as staging.thepuzzlequest.com or localhost:3000.
    public var displayName: String {
        let host = url.host(percentEncoded: true) ?? url.absoluteString
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// The server's privacy policy, on its website.
    public var privacyPolicy: URL {
        url.appending(path: "policies/privacy.html")
    }

    /// Reads a server's address as a person types it: a missing scheme is
    /// taken to be `https://`, a final `/` and the scheme's usual port are
    /// dropped, and the scheme and host are put in lower case. Anything but
    /// the origin (a path, a query, a fragment) or a user name and password
    /// is refused, as is anything that isn't an http or https address. This
    /// says nothing about whether the server may be used: that's a
    /// `ServerAddressPolicy`'s to decide.
    public init(parsing text: String) throws(ServerAddressRefusal) {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw .notAnAddress }
        if !address.contains("://") {
            address = "https://" + address
        }
        guard let components = URLComponents(string: address),
            let scheme = components.scheme?.lowercased(),
            let host = components.percentEncodedHost?.lowercased(), !host.isEmpty
        else { throw .notAnAddress }
        guard scheme == "https" || scheme == "http" else { throw .notAWebAddress }
        guard components.percentEncodedUser == nil, components.percentEncodedPassword == nil
        else { throw .hasUserInfo }
        guard components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
            components.percentEncodedQuery == nil, components.percentEncodedFragment == nil
        else { throw .notJustTheServer }
        guard Self.isPlainHost(host) else { throw .notAnAddress }
        let usualPort = scheme == "https" ? 443 : 80
        let port = components.port == usualPort ? nil : components.port
        if let port, !(1...65535).contains(port) { throw .notAnAddress }
        self.init(scheme: scheme, encodedHost: host, port: port)
    }

    /// Whether a host is a name of dot-separated labels (letters, digits, and
    /// hyphens), an IPv4 address (which is one of those), or a bracketed IPv6
    /// address. Percent-escapes and other characters, which could disguise
    /// one host as another, aren't allowed.
    private static func isPlainHost(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return host.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    var scheme: String { url.scheme ?? "" }
    var host: String { url.host(percentEncoded: true) ?? "" }
}

/// Which servers a build of the app may use.
public enum ServerAddressPolicy: Sendable {
    /// Release builds: only PuzzleQuest's own servers, over HTTPS on the usual
    /// port: thepuzzlequest.com and its subdomains.
    case puzzleQuestDomain
    /// Debug builds: any http or https address, such as a server on this Mac.
    case anyAddress

    /// PuzzleQuest's domain; its subdomains are its too.
    public static let domain = "thepuzzlequest.com"

    /// Reads an address as a person typed it, and checks the policy allows
    /// it.
    public func check(_ text: String) throws(ServerAddressRefusal) -> ServerOrigin {
        let origin = try ServerOrigin(parsing: text)
        try admit(origin)
        return origin
    }

    /// Checks the policy allows a server.
    ///
    /// Today the release policy is an allowlist. If servers outside
    /// PuzzleQuest's domain are wanted later, one could instead present a
    /// signed statement of its origin (see the iOS decisions): that would be a
    /// second, asynchronous way past `.notPuzzleQuestServer`, checked by the
    /// caller when this throws it, alongside the allowlist rather than in
    /// place of it. The other refusals (HTTPS, the port) would still apply.
    public func admit(_ origin: ServerOrigin) throws(ServerAddressRefusal) {
        switch self {
        case .anyAddress:
            return
        case .puzzleQuestDomain:
            guard origin.scheme == "https" else { throw .notSecure }
            guard origin.url.port == nil else { throw .hasPort }
            let host = origin.host
            guard host == Self.domain || host.hasSuffix("." + Self.domain) else {
                throw .notPuzzleQuestServer
            }
        }
    }
}

/// Why an address can't be used as the server.
public enum ServerAddressRefusal: Error, Equatable, Sendable {
    /// It isn't a web address at all.
    case notAnAddress
    /// It's an address, but not an http or https one.
    case notAWebAddress
    /// It has a user name or password in it.
    case hasUserInfo
    /// It has more than the server: a path, a query, or a fragment.
    case notJustTheServer
    /// Release builds: it isn't https.
    case notSecure
    /// Release builds: it names a port other than HTTPS's usual one.
    case hasPort
    /// Release builds: it isn't thepuzzlequest.com or one of its subdomains.
    case notPuzzleQuestServer
}
