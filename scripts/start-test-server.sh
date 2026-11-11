#!/bin/bash
# Starts a real PuzzleQuest API server for the contract and UI tests: the
# server repository at the release the app is pinned to (api/VERSION),
# checked out into .test-server/, built with Node 24, and run on an
# in-memory MongoDB with a test player and administrator. It runs in the
# background until scripts/stop-test-server.sh.
#
# When it's ready, .test-server/env holds what the tests need:
# PQ_TEST_SERVER_URL; PQ_TEST_USER_NAME, PQ_TEST_PASSWORD and
# PQ_TEST_DISPLAY_NAME, a player's; and PQ_TEST_ADMIN_USER_NAME and
# PQ_TEST_ADMIN_PASSWORD, an administrator's, through whom tests make and
# start quests. Each is there again prefixed with TEST_RUNNER_ for
# xcodebuild to pass on to the UI tests. Load them into the shell with
# `set -a; source .test-server/env; set +a`.
#
# Settings (environment):
#   PQ_SERVER_REPOSITORY  where to clone the server from; by default the
#                         local checkout ../therapypub-puzzlequest if there is
#                         one, otherwise GitHub. Only read, never changed.
#   PQ_TEST_SERVER_PORT   the port to listen on (default 3970)
#
# Node 24: with fnm installed, it runs `fnm exec --using=24`; otherwise
# (as in CI) the `node` and `npm` on PATH must be Node 24.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/.test-server"
TAG=$(cat "$ROOT/api/VERSION")
PORT=${PQ_TEST_SERVER_PORT:-3970}
CHECKOUT="$WORK/$TAG"

if [[ -z ${PQ_SERVER_REPOSITORY:-} ]]; then
  if [[ -d "$ROOT/../therapypub-puzzlequest/.git" ]]; then
    PQ_SERVER_REPOSITORY=$(cd "$ROOT/../therapypub-puzzlequest" && pwd)
  else
    PQ_SERVER_REPOSITORY=https://github.com/jimevans/therapypub-puzzlequest.git
  fi
fi

if command -v fnm > /dev/null; then
  run24() { fnm exec --using=24 "$@"; }
else
  run24() { "$@"; }
fi

if [[ -f "$WORK/server.pid" ]] && kill -0 "$(cat "$WORK/server.pid")" 2> /dev/null; then
  echo "A test server is already running; stop it with scripts/stop-test-server.sh" >&2
  exit 1
fi

mkdir -p "$WORK"
if [[ ! -d "$CHECKOUT" ]]; then
  echo "Cloning $TAG of the server from $PQ_SERVER_REPOSITORY"
  rm -rf "$CHECKOUT.partial"
  # A shallow clone from GitHub; a local clone shares the objects instead.
  depth=()
  [[ $PQ_SERVER_REPOSITORY == *://* ]] && depth=(--depth 1)
  git -c advice.detachedHead=false clone --quiet "${depth[@]+"${depth[@]}"}" \
    --branch "$TAG" "$PQ_SERVER_REPOSITORY" "$CHECKOUT.partial"
  mv "$CHECKOUT.partial" "$CHECKOUT"
fi

node_version=$(run24 node --version)
if [[ $node_version != v24.* ]]; then
  echo "The server needs Node 24, but found $node_version" >&2
  exit 1
fi

if [[ ! -f "$CHECKOUT/apps/api/dist/app.js" ]]; then
  echo "Installing and building the server with Node $node_version"
  # The registry, or the network to it, fails now and then (as it has in
  # CI): npm retries each download, and the whole install is tried three
  # times before giving up.
  for attempt in 1 2 3; do
    if (cd "$CHECKOUT" && run24 npm ci --no-audit --no-fund --loglevel=error \
      --fetch-retries=5 --fetch-retry-mintimeout=10000 \
      --fetch-retry-maxtimeout=60000); then
      break
    elif [[ $attempt -eq 3 ]]; then
      echo "Couldn't install the server's packages" >&2
      exit 1
    fi
    echo "Installing failed (attempt $attempt of 3); trying again" >&2
    sleep $((attempt * 15))
  done
  (cd "$CHECKOUT" && run24 npm run build --workspace=@puzzlequest/api)
fi

# Node itself, not a wrapper such as fnm's, so that stopping it stops the
# server and the database too.
node=$(run24 node -p process.execPath)
rm -f "$WORK/env"
nohup "$node" "$ROOT/scripts/test-server.mjs" \
  "$CHECKOUT" "$PORT" "$WORK/env" > "$WORK/test-server.log" 2>&1 &
echo $! > "$WORK/server.pid"

# The first run downloads MongoDB, so allow a few minutes.
for _ in $(seq 1 600); do
  if [[ -f "$WORK/env" ]]; then
    cat "$WORK/test-server.log"
    exit 0
  fi
  if ! kill -0 "$(cat "$WORK/server.pid")" 2> /dev/null; then
    echo "The test server didn't start:" >&2
    cat "$WORK/test-server.log" "$WORK/server.log" >&2 2> /dev/null || true
    rm -f "$WORK/server.pid"
    exit 1
  fi
  sleep 0.5
done
echo "The test server didn't start in time; see $WORK/test-server.log" >&2
exit 1
