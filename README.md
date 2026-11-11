# PuzzleQuest for iOS

The native iOS app for [PuzzleQuest](https://thepuzzlequest.com), the city
puzzle experiences: players travel to stops around a city, activate each stop,
and solve its puzzle, alone or in teams racing each other. This app is written
in SwiftUI against the PuzzleQuest API (version 1), whose server and web app
live in [therapypub-puzzlequest](https://github.com/jimevans/therapypub-puzzlequest).
Why there is a native app, and how it relates to that repository, is in its
decision record `docs/decisions/0021-native-apps.md`.

So far it signs in and out, and keeps its session between launches.

## Requirements

- **Xcode 27** (27.2 is what CI uses), which brings Swift 6 and the iOS
  simulator. The app runs on iOS 18 and later.
- **Node.js 24, through [fnm](https://github.com/Schniz/fnm)**, only for the
  contract and UI tests, which run the real API server. Install it as the
  server repository's README says; the scripts here use
  `fnm exec --using=24`, or the `node` on your `PATH` if fnm isn't installed.
- **jq** and the **GitHub CLI** (`gh`), only for moving to a new API release.
  macOS includes jq.

The app's only dependencies are Apple's OpenAPI packages
([swift-openapi-generator](https://github.com/apple/swift-openapi-generator),
[-runtime](https://github.com/apple/swift-openapi-runtime),
[-urlsession](https://github.com/apple/swift-openapi-urlsession), and
[swift-http-types](https://github.com/apple/swift-http-types), which comes
with them), pinned to exact versions in `PuzzleQuestKit/Package.swift`. Every
version, including those they bring in, is recorded in `Package.resolved`
(`PuzzleQuestKit/` for `swift`, and in the Xcode project's workspace for
Xcode); keep the two the same.

## Running the app

Open `PuzzleQuest.xcodeproj` in Xcode and run the **PuzzleQuest** scheme on a
simulator. The first time, Xcode asks you to trust the OpenAPI generator's
build plugin, which writes the API client as the app builds.

A debug build uses the server at <http://localhost:3000>; a release build uses
<https://thepuzzlequest.com>. To run a server locally, follow the server
repository's README ("Local setup"): `npm run dev`, then `npm run seed` for
sample users (such as `alex`, password `puzzlequest sample`) and quests. To
point a debug build at another server, set the `PQ_SERVER_URL` environment
variable in the scheme's Run options.

From the command line:

```sh
xcodebuild build -project PuzzleQuest.xcodeproj -scheme PuzzleQuest \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile
```

`-skipPackagePluginValidation` stands in for trusting the plugin in Xcode, and
`-onlyUsePackageVersionsFromResolvedFile` stops Xcode from moving to newer
versions than those pinned.

## Layout

- `PuzzleQuest/`: the app itself, kept thin: its entry point, its screens
  (SwiftUI), and its words in `Localizable.xcstrings` (English only for now).
  The Xcode project uses folder-synchronized groups, so adding a file to a
  folder adds it to the app without changing the project file.
- `PuzzleQuestKit/`: a Swift package holding everything that can be tested
  without the simulator.
  - `Sources/PuzzleQuestAPI`: the API client, generated at build time from
    `openapi.json` there. Nothing in it is written by hand.
  - `Sources/PuzzleQuestKit`: what the screens use: `APIClient` (the calls,
    returning the app's own types and throwing `APIError`), `SessionStore`
    (who is signed in, kept in the Keychain), and view models such as
    `SignInModel`.
  - `Tests/PuzzleQuestKitTests`: unit tests. `Tests/ContractTests`: tests
    against a real server.
- `PuzzleQuestUITests/`: UI tests (XCUITest) of whole journeys in the app.
- `Config/`: the app's Info.plist for each build configuration. The debug one
  allows plain HTTP to local servers.
- `api/`: the pinned API release: its description (`openapi.json`), its
  live-update messages (`live-updates.json`), and its tag (`VERSION`).
- `scripts/`: moving to a new API release, and running the test server.

## The API and moving to a new release

The app is written against the API description published with a release of
the server repository (decision 0023 there describes its conventions). The
copy in `api/` is exactly the release's; `scripts/update-api.sh` downloads a
release and writes the copy the client is generated from:

```sh
scripts/update-api.sh v1.1.0   # move to that release
scripts/update-api.sh          # re-apply the changes to the pinned one
```

Version 1 of the API only grows: it may add fields, enumerated values,
problem types and live-update messages at any time. The generator would turn
parts of the description into a client that breaks on those, so the script
changes them first (`scripts/tolerant-openapi.jq` explains each). New
response fields need nothing: since 1.0.1 the description leaves responses open
to them.

- Enumerations in shared schemas become "open": an unknown value (a new
  status, say) decodes as a plain string, which the app treats as unknown.
- A property that may be `null` becomes an optional one, which the generator
  would otherwise leave out entirely.

CI checks that the generated-from copy matches what the script writes, and
the unit tests in `ToleranceTests.swift` check the client reads such
responses. Moving to a new release is a deliberate change: run the script,
build, run every test, and commit `api/` with the regenerated copy.

## Tests

### Unit tests

```sh
cd PuzzleQuestKit && swift test --skip ContractTests
```

These run on the Mac, with [Swift Testing](https://developer.apple.com/documentation/testing):
reading newer responses, explaining errors, restoring and ending sessions
against a fake network, and the Keychain. They also run in the simulator as
part of `xcodebuild test` (below), except the Keychain test, which needs an
app there.

### The test server

The contract and UI tests run against a real server: the server repository
at the release in `api/VERSION`, on an in-memory database, with a test user.

```sh
scripts/start-test-server.sh    # clones, builds and starts it in the background
set -a; source .test-server/env; set +a
# … run the tests …
scripts/stop-test-server.sh
```

The first start clones the server into `.test-server/` (from
`../therapypub-puzzlequest` if you have it, otherwise from GitHub; set
`PQ_SERVER_REPOSITORY` to choose), installs its packages and builds it;
later starts reuse that. It listens on port 3970 (`PQ_TEST_SERVER_PORT`).
`.test-server/env` names the server and test user, and holds each again
prefixed with `TEST_RUNNER_`, which `xcodebuild` passes on to the UI tests.
The server's log is `.test-server/server.log`.

### Contract tests

With the test server's variables loaded:

```sh
cd PuzzleQuestKit && swift test --filter ContractTests
```

They sign in, check the session, sign out, and check the problems the server
sends for a wrong password, an invalid request, and too many attempts, all
through the generated client. Without `PQ_TEST_SERVER_URL` they're skipped.

### UI tests, and everything in the simulator

With the test server's variables loaded:

```sh
xcodebuild test -project PuzzleQuest.xcodeproj -scheme PuzzleQuest \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile
```

This runs the unit tests and the UI tests (XCUITest), which launch the app
pointed at the test server, sign in, relaunch to check the session is kept,
sign out, and check a wrong password is explained. Without the variables, the
UI tests are skipped. The UI tests find controls by their accessibility
identifiers (such as `sign-in.user-name`), so those stay put when wording
changes.

In Xcode, run the tests with ⌘U; for the UI tests, add the `TEST_RUNNER_`
variables' values, without the prefix, to the scheme's Test environment.

## Continuous integration

`.github/workflows/ci.yml` runs on GitHub's macOS runners with Xcode 27.2:
the check of the generated-from description, the unit tests, a build, the
test server, the contract tests, and the unit and UI tests in the simulator.
When a run fails, its test results (`Tests.xcresult`) and the server's logs
are kept as an artifact.

## Copyright

Copyright © 2026 jimevans. All rights reserved. The source is public so it can
be read and reviewed, but no licence to use, copy, modify, or distribute it is
granted for now.
