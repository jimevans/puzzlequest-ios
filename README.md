# PuzzleQuest for iOS

The native iOS app for [PuzzleQuest](https://thepuzzlequest.com), the city
puzzle experiences: players travel to stops around a city, activate each stop,
and solve its puzzle, alone or in teams racing each other. This app is written
in SwiftUI against the PuzzleQuest API (version 1), whose server and web app
live in [therapypub-puzzlequest](https://github.com/jimevans/therapypub-puzzlequest).
Why there is a native app, and how it relates to that repository, is in its
decision record `docs/decisions/0021-native-apps.md`.

So far it signs in and out, keeping its session between launches, and shows
a player their quests, kept up to date live as they start and change, with a
reminder to verify their email address. A quest opens to the stop being
played, the stops solved, and the finish and a race's standings; the stop
being played opens to its puzzle, where the player activates it (scanning its
QR code, or typing its code), reads it, reveals hints, and answers, then goes
on to the next stop. Staff and administrators, whose tools
are on the website, are told so. Signing up and the rest of an account's
pages are on the website for now; the sign-in screen links there. Options,
from the sign-in screen or the account menu, chooses which PuzzleQuest server
the app uses (below).

## Requirements

- **Xcode 27** (27.2 is what CI uses), which brings Swift 6 and the iOS
  simulator. The app runs on iOS 18 and later.
- **Node.js 24, through [fnm](https://github.com/Schniz/fnm)**, only for the
  contract and UI tests, which run the real API server. Install it as the
  server repository's README says; the scripts here use
  `fnm exec --using=24`, or the `node` on your `PATH` if fnm isn't installed.
- **jq** and the **GitHub CLI** (`gh`), only for moving to a new API release.
  macOS includes jq.

The app's only dependencies are Apple's: its OpenAPI packages
([swift-openapi-generator](https://github.com/apple/swift-openapi-generator),
[-runtime](https://github.com/apple/swift-openapi-runtime),
[-urlsession](https://github.com/apple/swift-openapi-urlsession), and
[swift-http-types](https://github.com/apple/swift-http-types), which comes
with them), and [swift-markdown](https://github.com/swiftlang/swift-markdown)
(with the [swift-cmark](https://github.com/swiftlang/swift-cmark) it brings
in), which reads text puzzles' Markdown for the app's own views to draw;
SwiftUI on its own draws only Markdown within a line. They're pinned to exact versions in `PuzzleQuestKit/Package.swift`. Every
version, including those they bring in, is recorded in `Package.resolved`
(`PuzzleQuestKit/` for `swift`, and in the Xcode project's workspace for
Xcode); keep the two the same.

## Running the app

Open `PuzzleQuest.xcodeproj` in Xcode and run the **PuzzleQuest** scheme on a
simulator. The first time, Xcode asks you to trust the OpenAPI generator's
build plugin, which writes the API client as the app builds.

Every build starts out using <https://thepuzzlequest.com>. To use a server on
your Mac, tap **Options** on the sign-in screen and choose **This Mac**
(<http://localhost:3000>; debug builds only). To run a server locally, follow
the server repository's README ("Local setup"): `npm run dev`, then
`npm run seed` for sample users (such as `alex`, password
`puzzlequest sample`) and quests. **Custom** takes any other address; a debug
build allows any http or https address, a release build only
thepuzzlequest.com and its subdomains, over HTTPS. To point a debug build at a
server for a run without changing Options, set the `PQ_SERVER_URL`
environment variable in the scheme's Run options, as the UI tests do.

From the command line:

```sh
xcodebuild build -project PuzzleQuest.xcodeproj -scheme PuzzleQuest \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile
```

`-skipPackagePluginValidation` stands in for trusting the plugin in Xcode, and
`-onlyUsePackageVersionsFromResolvedFile` stops Xcode from moving to newer
versions than those pinned.

## Choosing the server

The server is a setting, kept in `UserDefaults`; a debug build's
`PQ_SERVER_URL` overrides it for that run without changing it.
`ServerAddressPolicy` decides which addresses a build may use: release builds
an allowlist (https, thepuzzlequest.com or a subdomain, no other port; no user
name, path, query or fragment), debug builds any http or https address. A
custom address is reduced to its origin, then checked to be a PuzzleQuest
server (`ServerCheck` fetches `/api/v1/openapi.json` and reads its title and
version) before the app switches to it. Each server's session token is a
Keychain item of its own, keyed by the server's origin, so one server's token
is never sent to another. Switching servers (`ServerConnection.switchTo`)
asks first when someone is signed in, then forgets the old server's token,
tells that server the session has ended, and makes a new session and API
client for the new one; the app rebuilds its screens for it. If servers
outside PuzzleQuest's domain are wanted later, a signed statement of the
server's origin could be accepted alongside the allowlist (see
`ServerAddressPolicy.admit`).

## Layout

- `PuzzleQuest/`: the app itself, kept thin: its entry point, its screens
  (SwiftUI), and its words in `Localizable.xcstrings` (English only for now).
  Building in Xcode adds new words to the catalog; after building with
  `xcodebuild`, add them with `xcrun xcstringstool sync
  PuzzleQuest/Localizable.xcstrings --stringsdata <file>` for each of the
  app's `.stringsdata` files under `build/DerivedData` (not the UI tests'),
  then give each new one a comment saying where it appears, for translators.
  The Xcode project uses folder-synchronized groups, so adding a file to a
  folder adds it to the app without changing the project file.
- `PuzzleQuestKit/`: a Swift package holding everything that can be tested
  without the simulator.
  - `Sources/PuzzleQuestAPI`: the API client, generated at build time from
    `openapi.json` there. Nothing in it is written by hand.
  - `Sources/PuzzleQuestKit`: what the screens use: `APIClient` (the calls,
    returning the app's own types and throwing `APIError`), `SessionStore`
    (who is signed in, kept in the Keychain), `ServerConnection` (the chosen
    server and its session), `LiveUpdateFollower` (live
    updates over the API's websocket, below), `MarkdownBlock` (a text
    puzzle's Markdown, read into blocks for `MarkdownView` to draw; HTML in
    it shows as plain text, as on the web), and view models such as
    `SignInModel`, `HomeModel`, `QuestModel` and `PuzzleModel`.
  - `Tests/PuzzleQuestKitTests`: unit tests. `Tests/ContractTests`: tests
    against a real server.
- `PuzzleQuestUITests/`: UI tests (XCUITest) of whole journeys in the app.
- `Config/`: the debug build's Info.plist additions: it allows plain HTTP, to
  any server.
- `api/`: the pinned API release: its description (`openapi.json`), its
  live-update messages (`live-updates.json`), what its push notifications
  carry (`push-notifications.json`, from 1.1), and its tag (`VERSION`).
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

## Live updates

A screen that shows something that changes while it's open follows it over
the API's websocket, `/api/v1/updates`, with `LiveUpdateFollower`: it gets a
new ticket for each connection (tickets can be used once), subscribes, and
reports the connection and each update, ignoring messages this version
doesn't know. When the connection drops, or a ping now and then goes
unanswered, it connects again after a wait that doubles each time, up to 15
seconds. Updates sent while disconnected are lost, so the screen fetches what
it shows again each time the connection is made, as well as on each update
and on coming back to the foreground. The follower runs for as long as the
`.task` that runs it, so it stops when the screen goes away or the user signs
out. The home screen follows the player's list of quests
(`LiveChannel.userQuests`); the quest screen follows its quest
(`LiveChannel.quest`) and fetches it again on any update about it, as the web
app does, and so does the puzzle screen. The puzzle screen sends its
connection's id with the player's own actions, so the server doesn't send it
their updates: it fetches the puzzle again after each action itself. Starting
and resetting a quest reach its followers too (since API 1.0.2), so a quest
reset while its quest or puzzle screen is open shows as no longer available at
once. So do the puzzle master's messages and a challenge being answered (since
API 1.1), so a challenge appears on the quest screen as it's sent, and its
confirmation on every teammate's screen as soon as one of them answers it.
New messages pop up in a sheet once on each phone (which ones it has shown are
kept in `UserDefaults`), including those that came while the app was closed; a
challenge is answered there, and a row at the top of the quest screen reopens
it, or its confirmation, until the next one.

## Tests

### Unit tests

```sh
cd PuzzleQuestKit && swift test --skip ContractTests
```

These run on the Mac, with [Swift Testing](https://developer.apple.com/documentation/testing):
reading newer responses, explaining errors, restoring and ending sessions
against a fake network, the Keychain, following live updates over a fake
websocket, fetching every page of a list, a quest's clock, the home screen's
model and email reminder, reading a player's quest and a race's standings,
what's announced as a quest changes (the puzzle master's messages and an
answered challenge included), the quest screen's model (answering the
challenge, rightly, wrongly, and after a teammate; new messages shown once,
and the challenge reopened), remembering which messages were shown, reading a
puzzle (its media on the site) and what's announced as it changes, telling
refusals apart by their problem types, the puzzle screen's model (activating,
a code left in front of the camera sent only once, guessing, hints, the
live-update connection named with actions, and going on to the next stop),
reading Markdown (and HTML in it as plain text), who sees
which home screen, which server addresses
each build allows, checking a server is PuzzleQuest's, keeping each server's
token apart, and switching servers. They also run in the simulator as
part of `xcodebuild test` (below), except the Keychain test, which needs an
app there.

### The test server

The contract and UI tests run against a real server: the server repository
at the release in `api/VERSION`, on an in-memory database, with a test player
and an administrator. The administrator is made as a new site's first one
is: signed up, then promoted with the server's own `promote` command. Tests
sign up players of their own as they need them, and make and start quests for
them as the administrator, through the API.

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
`.test-server/env` names the server, the test player, and the
administrator, and holds each again prefixed with `TEST_RUNNER_`, which
`xcodebuild` passes on to the UI tests.
The server's log is `.test-server/server.log`.

### Contract tests

With the test server's variables loaded:

```sh
cd PuzzleQuestKit && swift test --filter ContractTests
```

They sign in, check the session, sign out, and check the problems the server
sends for a wrong password, an invalid request, and too many attempts; fetch
a new player's quests before and after a quest is made and started for them;
get live tickets; follow the player's quests over the real websocket and hear
of a quest starting; fetch a quest as its player before and after it starts,
solve its stop (finding the activation code as the administrator) and see it
finished with its solution, see a two-player race's standings provisional and
then final, receive a challenge from the puzzle master (with a phone
registered for the player, so it can reach them) and have a wrong answer
refused, a right one in other words accepted with its confirmation, and a
second answer refused, find a reset quest no longer available, and hear of the player's
own progress over the quest's websocket; see a puzzle waiting to be found
show nothing of itself, have a wrong code refused and the right one accepted
in any letter case, reveal a hint and see its penalty and the next one's
warning, have a wrong guess refused and the right one solve it, with the next
stop reached, have actions refused while the quest is paused, and find a stop
not reached or reset not available; send the verification email again
until it's refused, all through the generated client; and check that the check before
switching servers accepts a real server. Without `PQ_TEST_SERVER_URL`
they're skipped.

### UI tests, and everything in the simulator

With the test server's variables loaded:

```sh
xcodebuild test -project PuzzleQuest.xcodeproj -scheme PuzzleQuest \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile
```

This runs the unit tests and the UI tests (XCUITest), which launch the app
pointed at the test server, sign in, relaunch to check the session is kept,
sign out through the account menu, and check a wrong password is explained,
the link to sign up, and that an administrator is sent to the website. As a
new player, they see an empty list, then a quest that the test starts through
the API appear by itself (a live update), open it, and send the verification
email again. On the quest screen they see the current stop, and the quest
paused and resumed as the administrator does it; finish a race (both players
solving through the API while the screen is open) and see the finish, the
final standings with the player's own entry marked, and the solved stop's
solution; see a challenge from the puzzle master pop up as it's sent, answer
it wrongly and then rightly (in other words around its keyword), see the
confirmation to show the staff, put it away and bring it back from the row at
the top, and find the message in the history; and see a reset make the quest no longer
available as it happens. On the puzzle screen they type a wrong code and then the right one
(a simulator has no camera VisionKit can scan with, so the screen offers
typing, as on a phone whose camera can't be used), reveal a hint, are asked
before the hint that gives the solution away, answer wrongly and then rightly,
and go on to the next stop; and see the quest paused and resumed, and the
puzzle solved elsewhere, as by a teammate, through to the finish and back to
the quest; and see a reset make the puzzle, and the quest beneath it, no
longer available as it happens. Without `PQ_SERVER_URL`, they check Options starts with
Production, choose the test server as a custom one and sign in to it (the
sign-in screen naming it), and switch back to Production from the account
menu, which asks first and signs out. Without the variables, the
UI tests are skipped. The UI tests find controls by their accessibility
identifiers (such as `sign-in.user-name`), so those stay put when wording
changes. Two things to know when adding identifiers: one on a container
(a stack, say) is given to everything inside it, replacing theirs; and a
menu's items don't keep theirs, so tests find those by label. After a new
user signs in, iOS offers to save the password, covering the screen; the
tests dismiss it (`dismissSavePassword()`). Each launch starts signed out of
every server (`PQ_SIGNED_OUT=1`) with Options as a new install has it
(`PQ_RESET_SERVER=1`), both read only by debug builds. To prove a quest appears through a
live update, a debug build launched with `PQ_UI_TESTING=1` (as the UI tests
launch it) shows an invisible element, `home.live-updates` (and
`quest.live-updates` and `puzzle.live-updates` on the quest and puzzle
screens), whose value is `connected` once
live updates are connected and the screen has fetched since; the tests wait
for it before changing anything, so nothing but the live update can show the
change.

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
