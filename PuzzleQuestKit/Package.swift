// swift-tools-version: 6.2
// Everything in the app that can be tested without the simulator: the API
// client generated from the pinned description, and the session and screens'
// logic built on it. The app target holds only views and the app's entry.
import PackageDescription

let package = Package(
    name: "PuzzleQuestKit",
    defaultLocalization: "en",
    // macOS too, so that `swift test` runs the unit and contract tests on the
    // Mac itself, without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PuzzleQuestKit", targets: ["PuzzleQuestKit"])
    ],
    dependencies: [
        // Apple's packages, the only dependencies, each pinned to an exact
        // release at least two weeks old when chosen. The OpenAPI tools make
        // the client; swift-http-types comes with the runtime anyway, and is
        // named here because the middleware in PuzzleQuestKit uses its request
        // and response types. swift-markdown reads text puzzles' Markdown.
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.9.0"),
    ],
    targets: [
        // The client generated at build time from openapi.json, which
        // scripts/update-api.sh writes from the pinned release.
        .target(
            name: "PuzzleQuestAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .target(
            name: "PuzzleQuestKit",
            dependencies: [
                "PuzzleQuestAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "PuzzleQuestKitTests",
            dependencies: ["PuzzleQuestKit", "PuzzleQuestAPI"]
        ),
        // Against a real server: see scripts/start-test-server.sh. Skipped
        // unless PQ_TEST_SERVER_URL is set.
        .testTarget(
            name: "ContractTests",
            dependencies: ["PuzzleQuestKit", "PuzzleQuestAPI"]
        ),
    ]
)
