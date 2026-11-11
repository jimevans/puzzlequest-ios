// Runs the PuzzleQuest API server checked out by start-test-server.sh on an
// in-memory MongoDB, as the server repository's own browser tests do
// (e2e/wdio.conf.ts there), and signs up the user the contract and UI tests
// sign in as. Runs until stopped (SIGTERM or SIGINT), then stops both.
//
//   node scripts/test-server.mjs <checkout> <port> <ready-file>
//
// NODE_ENV=test keeps any .env file out of it, so it can't send real email.
import { spawn } from "node:child_process";
import { closeSync, openSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const [checkout, port, readyFile] = process.argv.slice(2);
if (!checkout || !port || !readyFile) {
  console.error("usage: node test-server.mjs <checkout> <port> <ready-file>");
  process.exit(2);
}

/** The user the tests sign in as; start-test-server.sh passes these on. */
const TEST_USER = {
  userName: "ios-tester",
  displayName: "iOS Tester",
  email: "ios-tester@example.com",
  password: "a long enough password",
};

const BASE_URL = `http://localhost:${port}`;
const LOG = path.join(path.dirname(readyFile), "server.log");

// mongodb-memory-server is one of the server's own development dependencies.
const require = createRequire(path.join(checkout, "package.json"));
const { MongoMemoryServer } = require("mongodb-memory-server");

const mongo = await MongoMemoryServer.create();
const log = openSync(LOG, "w");
const server = spawn(process.execPath, [path.join(checkout, "apps/api/dist/app.js")], {
  stdio: ["ignore", log, log],
  env: {
    PATH: process.env.PATH,
    NODE_ENV: "test",
    PQ_RUNTIME_ENVIRONMENT: "development",
    PQ_MONGODB_URI: mongo.getUri("puzzlequest"),
    PQ_PORT: port,
    PQ_BASE_URL: BASE_URL,
  },
});
closeSync(log);

let stopping = false;
async function stop(code) {
  if (stopping) return;
  stopping = true;
  server.kill();
  await mongo.stop();
  process.exit(code);
}
process.on("SIGTERM", () => stop(0));
process.on("SIGINT", () => stop(0));
server.on("exit", (code) => {
  if (!stopping) {
    console.error(`The server stopped (exit code ${code}); see ${LOG}`);
    stop(1);
  }
});

/** Waits for the server to answer. */
async function waitForServer() {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    try {
      if ((await fetch(`${BASE_URL}/api/v1/openapi.json`)).ok) return;
    } catch {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`The server didn't start; see ${LOG}`);
}

try {
  await waitForServer();
  const response = await fetch(`${BASE_URL}/api/v1/users`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(TEST_USER),
  });
  if (!response.ok) {
    throw new Error(`Signing up the test user: ${response.status} ${await response.text()}`);
  }
  // Shell assignments, quoted, for `source`. Each is also written with the
  // prefix TEST_RUNNER_, which xcodebuild strips when it passes variables on
  // to UI tests.
  const quoted = (value) => `'${value.replaceAll("'", "'\\''")}'`;
  const settings = Object.entries({
    PQ_TEST_SERVER_URL: BASE_URL,
    PQ_TEST_USER_NAME: TEST_USER.userName,
    PQ_TEST_PASSWORD: TEST_USER.password,
    PQ_TEST_DISPLAY_NAME: TEST_USER.displayName,
  });
  writeFileSync(
    readyFile,
    [...settings, ...settings.map(([name, value]) => [`TEST_RUNNER_${name}`, value])]
      .map(([name, value]) => `${name}=${quoted(value)}\n`)
      .join("")
  );
  console.log(`The test server is at ${BASE_URL}`);
} catch (error) {
  console.error(error.message);
  await stop(1);
}
